# Ruolo `build-container`

Crea l'utente e la coppia di chiavi SSH, prepara il build context, genera i Dockerfile da un unico template, builda le immagini e **avvia i container su porte diverse**, iniettando la chiave pubblica a runtime.

## Struttura

```
build-container/
├── defaults/main.yml     # lista `dockerfile` (le immagini), `user`, `ssh_key_path`
├── templates/
│   └── Dockerfile.j2     # UN SOLO template per Rocky e Ubuntu
└── tasks/
    ├── main.yml          # utente + chiave + build context + template + engine detection
    ├── docker.yaml       # build & run con Docker
    └── podman.yaml       # build & run con Podman
```

## Variabili

**`defaults/main.yml`**

```yaml
dockerfile:
  - name: rocky
    image: rockylinux/rockylinux:9
    packages: [sudo, openssh-server]
    distribution: RedHat
    host_port: 2222
    port: 22
  - name: ubuntu
    image: ubuntu:24.04
    packages: [sudo, openssh-server]
    distribution: Debian
    host_port: 2223
    port: 22

user:
  name: andrea
  shell: /bin/bash
  uid: 1500

ssh_key_path: /home/{{ user.name }}/.ssh/id_key_{{ user.name }}
```

La lista `dockerfile` è **il punto di parametrizzazione principale del progetto**: ogni elemento descrive un'immagine da costruire. Per aggiungere un terzo container (es. Debian 12 o Fedora) basta appendere un elemento con una `host_port` libera — non si tocca una riga di task.

Significato dei campi:

| Campo | Uso |
|---|---|
| `name` | prefisso di immagine (`<name>-ssh`), container (`<name>-ssh-server`) e Dockerfile (`Dockerfile-<name>`) |
| `image` | immagine base della `FROM` |
| `packages` | pacchetti da installare, uniti con `join(' ')` nel template |
| `distribution` | `RedHat` o `Debian`: seleziona i blocchi condizionali del template (dnf vs apt, `wheel` vs `sudo`, ecc.) |
| `host_port` | porta **sull'host** → deve essere unica per evitare conflitti |
| `port` | porta **dentro** il container (22, sshd) |

`ssh_key_path` è il percorso della chiave **privata**; la pubblica è lo stesso path con `.pub`. Una sola variabile governa quindi tre cose: dove viene creata la directory `.ssh`, dove viene generata la coppia di chiavi e quale file viene montato nei container.

## Cosa fa (`tasks/main.yml`)

1. **Crea l'utente** con `ansible.builtin.user`, con `create_home: true` e l'UID fissato a `user.uid`.
2. **Crea la directory `.ssh`** dell'utente, con owner e gruppo dell'utente e permessi `0700`. Il path è ricavato da `ssh_key_path` con il filtro `dirname`:

   ```yaml
   path: "{{ ssh_key_path | dirname }}"
   ```

   `dirname` è il complementare di `basename`: da `/home/andrea/.ssh/id_key_andrea` restituisce `/home/andrea/.ssh`. Così il percorso è scritto una volta sola in `defaults`, e spostare la chiave non richiede di aggiornare altri task. Il task deve stare **dopo** la creazione dell'utente, altrimenti `owner` fallisce perché l'utente non esiste ancora.
3. **Genera la coppia di chiavi** ed25519 con `community.crypto.openssh_keypair`, intestata all'utente. Il modulo crea sia la privata (`0600`) sia la pubblica (`0644`) ed è idempotente: se la chiave esiste già e corrisponde ai parametri, non la rigenera.
4. **Crea la directory di build** `/home/<user>/build`, che sarà il *build context*.
5. **Genera i Dockerfile** con `ansible.builtin.template` in loop su `dockerfile`, producendo `build/Dockerfile-rocky` e `build/Dockerfile-ubuntu` **dallo stesso `Dockerfile.j2`**.
6. **Rileva l'engine** e include `docker.yaml` / `podman.yaml`.

### Perché l'UID è fissato

Il `.pub` viene montato nei container come `authorized_keys`, e sshd con `StrictModes` accetta quel file **solo** se appartiene a root o all'utente che sta facendo login. Il confronto però è **numerico**: i nomi non contano, conta l'UID. E `andrea` sull'host e `andrea` dentro l'immagine sono due utenti creati in posti indipendenti, ognuno con l'UID che il sistema gli assegna per primo:

| Dove | UID assegnato automaticamente |
|---|---|
| host (Vagrant, con `vagrant` a 1000) | 1001 |
| Rocky 9 (nessun utente normale nell'immagine base) | 1000 |
| Ubuntu 24.04 (ha già `ubuntu` a 1000) | 1001 |

Tre numeri diversi per lo stesso nome: un unico file `.pub` non potrebbe appartenere a tutti. Il risultato sarebbe un `Permission denied (publickey)` il cui motivo vero compare solo nei log del container.

Fissando `uid: 1500` in `defaults` e passandolo sia al modulo `user` sull'host sia alla `useradd` nel template, i tre UID coincidono e il controllo di sshd passa.

### Il task che genera i Dockerfile

```yaml
- name: Genera il Dockerfile
  ansible.builtin.template:
    src: Dockerfile.j2
    dest: "/home/{{ user.name }}/build/Dockerfile-{{ item.name }}"
    mode: '0644'
  loop: "{{ dockerfile }}"
```

Un **unico** `src` (`Dockerfile.j2`) e un `dest` che cambia a ogni giro del loop: da un solo file sorgente nascono `Dockerfile-rocky` e `Dockerfile-ubuntu`. Dentro il template la variabile magica è `item`, cioè l'elemento della lista `dockerfile` in corso di elaborazione — è così che lo stesso file produce due Dockerfile diversi.

## Il template unico `Dockerfile.j2`

Questo è il cuore della parte "*un solo template per Rocky e Ubuntu*". Sorgente completo (`templates/Dockerfile.j2`):

```jinja
FROM {{ item.image }}

{% if item.distribution == 'RedHat' %}
RUN dnf install -y {{ item.packages | join(' ') }} && \
    rm -rf /var/cache/dnf
{% endif %}

{% if item.distribution == 'Debian' %}
RUN apt-get update && \
    apt-get install -y {{ item.packages | join(' ') }} && \
    rm -rf /var/lib/apt/lists/*
{% endif %}

{% if item.distribution == 'RedHat' %}
RUN ssh-keygen -A
{% endif %}

{% if item.distribution == 'Debian' %}
RUN mkdir -p /var/run/sshd
{% endif %}

RUN sed -i -E 's/^#?#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i -E 's/^#?PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i -E 's/^#?PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    echo 'AllowUsers {{ user.name }}' >> /etc/ssh/sshd_config

RUN useradd --uid={{ user.uid }} --create-home --shell /bin/bash --groups "{{ 'wheel' if item.distribution == 'RedHat' else 'sudo' }}" "{{ user.name }}" && \
    echo "{{ user.name }} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/{{ user.name }} && \
    chmod 0440 /etc/sudoers.d/{{ user.name }} && \
    mkdir -p /home/{{ user.name }}/.ssh && \
    chmod 700 /home/{{ user.name }}/.ssh && \
    chown {{ user.name }}:{{ user.name }} /home/{{ user.name }}/.ssh

EXPOSE "{{ item.port }}"

CMD ["/usr/sbin/sshd", "-D", "-e"]
```

### Come fa un solo file a servire due distribuzioni

Il template usa due meccanismi Jinja diversi:

1. **Blocchi condizionali `{% if item.distribution == '...' %}`** per le istruzioni intere che esistono solo in una delle due famiglie. Quando Ansible processa l'elemento `rocky`, i blocchi `Debian` semplicemente **non vengono resi** e nel Dockerfile finale non compaiono affatto: il file generato non contiene condizioni, è un Dockerfile normale e pulito.
2. **Espressione ternaria inline** quando a cambiare è solo una parola dentro un comando altrimenti identico, per non duplicare l'intera `RUN`:

   ```jinja
   --groups "{{ 'wheel' if item.distribution == 'RedHat' else 'sudo' }}"
   ```

Il filtro `join(' ')` trasforma la lista `packages` in una stringa separata da spazi: `['sudo', 'openssh-server']` diventa `sudo openssh-server`, cioè la sintassi che vuole il package manager. Aggiungere pacchetti in `defaults` allunga il comando da solo, e resta una sola `RUN` — quindi un solo layer.

### Le differenze appianate dal template

| Differenza | RedHat (Rocky 9) | Debian (Ubuntu 24.04) | Perché serve |
|---|---|---|---|
| Package manager | `dnf install -y` + `rm -rf /var/cache/dnf` | `apt-get update && apt-get install -y` + `rm -rf /var/lib/apt/lists/*` | comandi e cache completamente diversi; su Debian l'`update` è obbligatorio perché le immagini base non hanno indici dei pacchetti |
| Preparazione di sshd | `ssh-keygen -A` | `mkdir -p /var/run/sshd` | su RedHat le **host key** non sono nell'immagine base e sshd non parte senza; su Debian il pacchetto non crea la directory di runtime (`Missing privilege separation directory`) |
| Gruppo di amministrazione | `wheel` | `sudo` | è il gruppo che le rispettive distro abilitano in `/etc/sudoers` |

## Build e run: varianti Docker e Podman

**Variante Docker (`tasks/docker.yaml`)**

- `docker_image_build`: immagine `<name>-ssh`, `path` = build context, `dockerfile: Dockerfile-<name>`.
- `docker_container`: nome `<name>-ssh-server`, `pull: never` (l'immagine è locale, non deve essere cercata su Docker Hub), `published_ports: "<host_port>:<port>"`, `state: started`, più il bind mount della chiave.

**Variante Podman (`tasks/podman.yaml`)**

- `podman_image` con `state: build`, `tag: latest` e `build.file` che punta al Dockerfile specifico.
- `podman_container` con immagine **`localhost/<name>-ssh`**: dopo una build locale Podman registra l'immagine nel namespace `localhost/`, quindi il riferimento va qualificato così.

In entrambi i casi il mount è lo stesso:

```yaml
    volumes:
      - "{{ ssh_key_path }}.pub:/home/{{ user.name }}/.ssh/authorized_keys:ro"
```

La chiave pubblica arriva nel container **a runtime**, in sola lettura, al posto di `authorized_keys`. Cambiare chiave significa ricreare il container, non ricostruire l'immagine.

## Verifica

Due container SSH raggiungibili con la chiave generata dall'host:

```bash
ssh -i /home/andrea/.ssh/id_key_andrea -p 2222 andrea@localhost   # Rocky 9
ssh -i /home/andrea/.ssh/id_key_andrea -p 2223 andrea@localhost   # Ubuntu 24.04
```