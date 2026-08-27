# Ansible – Registry privato, build e push di container (Docker **e** Podman)

Collezione di ruoli Ansible che, eseguiti in sequenza, portano una macchina Linux "pulita" a:

1. avere un **registry Docker privato** in esecuzione e configurato come *insecure registry*;
2. **buildare due immagini** (Rocky Linux 9 e Ubuntu 24.04) a partire da un **unico template Jinja2** di Dockerfile;
3. **eseguire i container** delle due immagini **senza conflitti di porta**;
4. **taggare e pushare** le immagini sul registry creato al punto 1.

Tutto è **parametrizzato** tramite `defaults/main.yml` e tutti i ruoli funzionano **indifferentemente con Docker o con Podman**, grazie a un meccanismo di *engine detection* replicato in ogni ruolo.

## Struttura del progetto

```
roles/
├── registry/                 # 1. crea e configura il registry privato
│   ├── defaults/main.yml     #    path dati, nome/porta/immagine del registry, registry_host
│   ├── handlers/main.yml     #    "Riavvia Docker" (dopo la modifica di daemon.json)
│   └── tasks/
│       ├── main.yml          #    parte comune + engine detection
│       ├── docker.yaml       #    variante Docker
│       └── podman.yaml       #    variante Podman
│
├── build-container/          # 2+4. genera i Dockerfile, builda le immagini, avvia i container
│   ├── defaults/main.yml     #    lista `dockerfile` (le immagini) + `user`
│   ├── templates/
│   │   └── Dockerfile.j2     #    UN SOLO template per Rocky e Ubuntu
│   └── tasks/
│       ├── main.yml          #    utente + chiave SSH + build context + template + engine detection
│       ├── docker.yaml       #    build & run con Docker
│       └── podman.yaml       #    build & run con Podman
│
├── push-images/              # 3. tag + push sul registry
│   ├── defaults/main.yml     #    lista `images` (nome immagine + repo di destinazione)
│   └── tasks/
│       ├── main.yml          #    engine detection
│       ├── docker.yaml       #    docker_image_tag + docker_image_push
│       └── podman.yaml       #    podman_image con push: true
│
└── docker/                   # (facoltativo) installazione di Docker Engine
    ├── defaults/main.yml     #    docker_user, docker_packages
    └── tasks/
        ├── main.yml          #    include per OS family + install + service + gruppo docker
        ├── Debian.yaml       #    repo APT ufficiale Docker (chiave GPG + deb822)
        └── RedHat.yaml       #    repo YUM ufficiale Docker CE
```

---

## Il meccanismo dual-engine (Docker / Podman)

È il cuore del progetto ed è **identico nei tre ruoli principali**. In `tasks/main.yml`:

```yaml
- name: Rileva il container engine
  ansible.builtin.shell: command -v podman || command -v docker
  register: engine_check
  changed_when: false
  failed_when: engine_check.rc != 0

- name: Imposta container_engine
  ansible.builtin.set_fact:
    container_engine: "{{ container_engine | default(engine_check.stdout | basename) }}"

- name: <azione del ruolo>
  ansible.builtin.include_tasks: "{{ container_engine }}.yaml"
```

Come funziona, passo per passo:

1. **Rilevamento** — `command -v podman || command -v docker` restituisce il path del primo engine trovato (es. `/usr/bin/podman`). Grazie all'`||` della shell, **Podman ha la precedenza** se entrambi sono installati. Se non c'è nessuno dei due, `rc != 0` e il `failed_when` fa fallire il ruolo con un errore chiaro invece di proseguire a vuoto.
2. **Normalizzazione** — il filtro `basename` trasforma `/usr/bin/podman` in `podman`, cioè esattamente il nome del file di task da includere.
3. **Override manuale** — `container_engine | default(...)` significa: *se la variabile è già stata definita, tienila; altrimenti usa il valore rilevato*.

4. **Dispatch dinamico** — `include_tasks: "{{ container_engine }}.yaml"` carica `docker.yaml` **oppure** `podman.yaml`. L'include è *dinamico* (a differenza di `import_tasks`), quindi il nome del file viene risolto a runtime, dopo il `set_fact`: è proprio questo che rende possibile la scelta.

### Differenze gestite tra i due engine

| Aspetto | Docker | Podman |
|---|---|---|
| Insecure registry | `/etc/docker/daemon.json` → chiave `insecure-registries` + **restart del servizio** (handler) | blocco `[[registry]] … insecure = true` in `/etc/containers/registries.conf`, nessun restart necessario |
| Immagine del registry | `registry:2` (Docker Hub implicito) | `docker.io/library/registry:2` (Podman richiede il registry esplicito) |
| Riferimento a immagini locali | `rocky-ssh` | `localhost/rocky-ssh` (namespace locale di Podman) |
| Build | `community.docker.docker_image_build` | `containers.podman.podman_image` con `state: build` |
| Push | `docker_image_tag` + `docker_image_push` (due step) | `podman_image` con `push: true` e `push_args.dest` (uno step) |

---

## Ordine di esecuzione

I ruoli **vanno eseguiti tutti insieme e in quest'ordine**, perché ognuno consuma ciò che produce il precedente:

```
docker (facoltativo)  →  registry  →  build-container  →  push-images
```

- **`docker`** serve solo se sulla macchina non c'è già un engine: se usi Podman (o Docker è già installato) puoi ometterlo.
- **`registry`** deve girare **prima** di `push-images`, ovviamente, ma anche **prima di `build-container`**: è lui a scrivere la configurazione di *insecure registry*, e nel caso di Docker fa **restartare il demone**. 
- **`build-container`** produce le immagini `rocky-ssh` e `ubuntu-ssh` e le avvia.
- **`push-images`** tagga quelle immagini verso il registry e le pusha.

---

## Ruolo `registry`

Crea un registry privato basato sull'immagine ufficiale `registry:2`, con storage persistente su bind mount.

**`defaults/main.yml`**

```yaml
directory:
  path: /opt/registry/data      # dove vivono i layer, sopravvive al container
  owner: root
  group: root
  mode: '0755'

container:
  name: registry
  image_tag: 2
  restart_policy: always
  state: started
  host_port: 5000
  container_port: 5000

registry_host: 192.168.56.10    # IP/hostname con cui il registry viene raggiunto
```

**Cosa fa (`tasks/main.yml`)**

1. Crea `/opt/registry/data` con owner/group/permessi presi dalle variabili → i dati del registry sono **persistenti**, se ricrei il container le immagini restano.
2. Rileva l'engine.
3. Include `docker.yaml` o `podman.yaml`.

**Variante Docker (`tasks/docker.yaml`)**

- Avvia il container `registry` con `community.docker.docker_container`: porta `5000:5000`, `restart_policy: always` (riparte da solo dopo un reboot), volume `/opt/registry/data:/var/lib/registry`.
- Crea `/etc/docker` e vi scrive `daemon.json` con:

  ```json
  { "insecure-registries": ["192.168.56.10:5000"] }
  ```

  Serve perché il registry parla **HTTP in chiaro**, mentre Docker per default pretende HTTPS con certificato valido: senza questa riga il push fallirebbe con `http: server gave HTTP response to HTTPS client`.
- Il task notifica l'handler **`Riavvia Docker`**: `daemon.json` viene letto solo all'avvio del demone, quindi il restart è indispensabile.

**Variante Podman (`tasks/podman.yaml`)**

- Con `blockinfile` aggiunge a `/etc/containers/registries.conf` il blocco:

  ```toml
  [[registry]]
  location = "192.168.56.10:5000"
  insecure = true
  ```

- Avvia il container con `containers.podman.podman_container`, stessa porta e stesso volume.
- Qui **non serve alcun restart**: Podman è daemonless e rilegge `registries.conf` a ogni invocazione.

---

## Ruolo `build-container`

Prepara il build context, genera i Dockerfile dal template, builda le immagini e **avvia i container su porte diverse**.

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

**Cosa fa (`tasks/main.yml`)**

1. **Crea l'utente e genera la chiave SSH** con `ansible.builtin.user`: `create_home: true`, `generate_ssh_key: true`, tipo **ed25519**, file `~/.ssh/id_key_<user>`.
2. **Crea la directory di build** `/home/<user>/build`, che sarà il *build context*.
3. **Copia la chiave pubblica nel build context** con `remote_src: true` (la copia avviene *sul target*, non dal control node): il file deve stare dentro il context perché la `COPY` del Dockerfile possa vederlo.
4. **Genera i Dockerfile** con `ansible.builtin.template` in loop su `dockerfile`, producendo `build/Dockerfile-rocky` e `build/Dockerfile-ubuntu` **dallo stesso `Dockerfile.j2`**.
5. **Rileva l'engine** e include `docker.yaml` / `podman.yaml`.

Il task che genera i Dockerfile è questo:

```yaml
- name: Genera il Dockerfile
  ansible.builtin.template:
    src: Dockerfile.j2
    dest: "/home/{{ user.name }}/build/Dockerfile-{{ item.name }}"
    mode: '0644'
  loop: "{{ dockerfile }}"
```

Un **unico** `src` (`Dockerfile.j2`) e un `dest` che cambia a ogni giro del loop: da un solo file sorgente nascono `Dockerfile-rocky` e `Dockerfile-ubuntu`. Dentro il template la variabile magica è `item`, cioè l'elemento della lista `dockerfile` in corso di elaborazione — è così che lo stesso file produce due Dockerfile diversi.

### Il template unico `Dockerfile.j2`

Questo è il cuore della parte "*un solo template per Rocky e Ubuntu*". Sorgente completo (`build-container/templates/Dockerfile.j2`):

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

RUN useradd --create-home --shell /bin/bash --groups "{{ 'wheel' if item.distribution == 'RedHat' else 'sudo' }}" "{{ user.name }}" && \
    echo "{{ user.name }} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/{{ user.name }} && \
    chmod 0440 /etc/sudoers.d/{{ user.name }} && \
    mkdir -p /home/{{ user.name }}/.ssh && \
    chmod 700 /home/{{ user.name }}/.ssh && \
    chown {{ user.name }}:{{ user.name }} /home/{{ user.name }}/.ssh

COPY id_key_{{ user.name }}.pub /home/{{ user.name }}/.ssh/authorized_keys

RUN chmod 600 /home/{{ user.name }}/.ssh/authorized_keys && \
    chown {{ user.name }}:{{ user.name }} /home/{{ user.name }}/.ssh/authorized_keys

EXPOSE "{{ item.port }}"

CMD ["/usr/sbin/sshd", "-D", "-e"]
```

#### Come fa un solo file a servire due distribuzioni

Il template usa due meccanismi Jinja diversi, scelti in base a quanto è "grosso" il pezzo che cambia:

1. **Blocchi condizionali `{% if item.distribution == '...' %}`** per le istruzioni intere che esistono solo in una delle due famiglie. Quando Ansible processa l'elemento `rocky`, i blocchi `Debian` semplicemente **non vengono resi** e nel Dockerfile finale non compaiono affatto: il file generato non contiene condizioni, è un Dockerfile normale e pulito.
2. **Espressione ternaria inline** quando a cambiare è solo una parola dentro un comando altrimenti identico, per non duplicare l'intera `RUN`:

   ```jinja
   --groups "{{ 'wheel' if item.distribution == 'RedHat' else 'sudo' }}"
   ```

#### Le differenze appianate dal template

| Differenza | RedHat (Rocky 9) | Debian (Ubuntu 24.04) | Perché serve |
|---|---|---|---|
| Package manager | `dnf install -y` + `rm -rf /var/cache/dnf` | `apt-get update && apt-get install -y` + `rm -rf /var/lib/apt/lists/*` | comandi e cache completamente diversi; su Debian l'`update` è obbligatorio perché le immagini base non hanno indici dei pacchetti |
| Preparazione di sshd | `ssh-keygen -A` | `mkdir -p /var/run/sshd` | su RedHat le **host key** non sono nell'immagine base e sshd non parte senza; su Debian il pacchetto non crea la directory di runtime (`Missing privilege separation directory`) |
| Gruppo di amministrazione | `wheel` | `sudo` | è il gruppo che le rispettive distro abilitano in `/etc/sudoers` |

### Build e run: varianti Docker e Podman

**Variante Docker (`tasks/docker.yaml`)**

- `docker_image_build`: immagine `<name>-ssh`, `path` = build context, `dockerfile: Dockerfile-<name>`.
- `docker_container`: nome `<name>-ssh-server`, `pull: never` (l'immagine è locale, non deve essere cercata su Docker Hub), `published_ports: "<host_port>:<port>"`, `state: started`.

**Variante Podman (`tasks/podman.yaml`)**

- `podman_image` con `state: build`, `tag: latest` e `build.file` che punta al Dockerfile specifico.
- `podman_container` con immagine **`localhost/<name>-ssh`**: dopo una build locale Podman registra l'immagine nel namespace `localhost/`, quindi il riferimento va qualificato così.

Risultato finale: due container SSH raggiungibili con la chiave generata al punto 1.

```bash
ssh -i ~/.ssh/id_key_andrea -p 2222 andrea@localhost   # Rocky 9
ssh -i ~/.ssh/id_key_andrea -p 2223 andrea@localhost   # Ubuntu 24.04
```

---

## Gestione dei conflitti di porta

Il requisito "*run dei container in modo che non vadano in conflitto di porte tra loro*" è soddisfatto direttamente nel ruolo `build-container`, tramite il campo **`host_port`** di ogni elemento della lista.

Entrambi i container espongono internamente la **stessa** porta 22 (`port`) — cosa perfettamente lecita, perché ogni container ha il proprio network namespace — ma vengono pubblicati su **porte host diverse**:

| Container | Porta interna | Porta host | Comando |
|---|---|---|---|
| `rocky-ssh-server` | 22 | **2222** | `ssh -p 2222 andrea@<host>` |
| `ubuntu-ssh-server` | 22 | **2223** | `ssh -p 2223 andrea@<host>` |
| `registry` | 5000 | **5000** | `curl http://<host>:5000/v2/_catalog` |

---

## Ruolo `push-images`

Tagga le immagini appena costruite verso il registry privato e le carica.

**`defaults/main.yml`**

```yaml
images:
  - name: rocky-ssh
    tag: latest
    repo: localhost:5000
  - name: ubuntu-ssh
    tag: 1.0
    repo: localhost:5000
```

**Variante Docker (`tasks/docker.yaml`)** — due step, come richiede il flusso Docker:

1. **`docker_image_tag`** crea un secondo riferimento per la stessa immagine: da `rocky-ssh:1.0`
   (sorgente, indicata da `name` + `tag`) produce `localhost:5000/rocky-ssh:1.0` (destinazione,
   indicata in `repository`). Non è una copia — l'immagine su disco resta una sola, cambia solo
   il nome con cui la si chiama. Il passaggio è obbligatorio perché **Docker deduce il registry
   di destinazione dal nome dell'immagine**: la parte prima del primo `/` (`localhost:5000`) è
   l'host verso cui pushare. Senza quel prefisso, `docker push rocky-ssh:1.0` finirebbe su
   Docker Hub.
2. **`docker_image_push`** esegue il push verso quel repository.

**Variante Podman (`tasks/podman.yaml`)** — un solo step: `podman_image` con `push: true` e `push_args.dest: "{{ item.repo }}"` fa tag e push insieme.

---

## Ruolo `docker` (facoltativo)

Da usare **solo** se vuoi lavorare con Docker e la macchina non ce l'ha. Se usi Podman, saltalo.

**`defaults/main.yml`**

```yaml
docker_user: vagrant
docker_packages:
  - docker-ce
  - docker-ce-cli
  - containerd.io
  - docker-buildx-plugin
  - docker-compose-plugin
```

**`tasks/main.yml`**

1. `include_tasks: "{{ ansible_os_family }}.yaml"` — stesso pattern di dispatch dinamico visto per l'engine, ma basato sul fatto `ansible_os_family`, quindi carica `Debian.yaml` o `RedHat.yaml`.
2. Installa `docker_packages` con il modulo generico `ansible.builtin.package` (astrae apt/dnf).
3. Avvia e abilita il servizio `docker`.
4. Aggiunge `docker_user` al gruppo `docker` con `append: true` (non sovrascrive gli altri gruppi dell'utente) così può usare Docker senza `sudo`.

**`Debian.yaml`** — installa `ca-certificates` e `python3-debian` (richiesto dal modulo `deb822_repository`), crea `/etc/apt/keyrings`, scarica la chiave GPG ufficiale e registra il repository in formato **deb822**, ricavando dinamicamente distro (`ansible_distribution | lower`), suite (`ansible_distribution_release`) e architettura (`amd64`/`arm64` da `ansible_architecture`).

**`RedHat.yaml`** — aggiunge il repo `docker-ce-stable` con `yum_repository`, `gpgcheck: true` e chiave ufficiale, versione maggiore presa da `ansible_distribution_major_version`; installa `python3-pip` per l'SDK Python di Docker.

---

## Playbook di esempio

`site.yml` nella directory che contiene `roles/`:

```yaml
---
- name: Registry privato, build, run e push dei container
  hosts: all
  become: true
  roles:
    - role: docker          # facoltativo: solo se vuoi Docker e non è installato
    - role: registry
    - role: build-container
    - role: push-images
```

## Parametrizzazione: tutte le variabili

Nessun task contiene valori hardcoded: tutto passa dai `defaults/`, quindi ogni valore è sovrascrivibile da `group_vars`, `host_vars`, `vars:` del playbook o `-e` da riga di comando (in ordine di precedenza crescente).

### `registry`

| Variabile | Default | Descrizione |
|---|---|---|
| `directory.path` | `/opt/registry/data` | storage persistente del registry |
| `directory.owner` / `group` / `mode` | `root` / `root` / `0755` | permessi della directory dati |
| `container.name` | `registry` | nome del container |
| `container.image_tag` | `2` | tag dell'immagine `registry` |
| `container.restart_policy` | `always` | policy di riavvio |
| `container.state` | `started` | stato desiderato |
| `container.host_port` | `5000` | porta sull'host |
| `container.container_port` | `5000` | porta interna |
| `registry_host` | `192.168.56.10` | host da dichiarare come *insecure registry* |

### `build-container`

| Variabile | Default | Descrizione |
|---|---|---|
| `dockerfile[].name` | `rocky`, `ubuntu` | identificativo dell'immagine |
| `dockerfile[].image` | `rockylinux/rockylinux:9`, `ubuntu:24.04` | immagine base |
| `dockerfile[].packages` | `sudo`, `openssh-server` | pacchetti da installare |
| `dockerfile[].distribution` | `RedHat` / `Debian` | seleziona i rami del template |
| `dockerfile[].host_port` | `2222`, `2223` | porta host (unica!) |
| `dockerfile[].port` | `22` | porta interna |
| `user.name` | `andrea` | utente creato su host e nei container |
| `user.shell` | `/bin/bash` | shell dell'utente |

### `push-images`

| Variabile | Default | Descrizione |
|---|---|---|
| `images[].name` | `rocky-ssh`, `ubuntu-ssh` | immagine locale da pushare |
| `images[].repo` | `localhost:5000` | registry di destinazione |

### `docker`

| Variabile | Default | Descrizione |
|---|---|---|
| `docker_user` | `vagrant` | utente da aggiungere al gruppo `docker` |
| `docker_packages` | lista Docker CE | pacchetti da installare |

### Comune a tutti i ruoli

| Variabile | Default | Descrizione |
|---|---|---|
| `container_engine` | rilevato automaticamente | forza `docker` o `podman` bypassando la detection |

---

## Verifica del risultato

```bash
# container attivi (sostituisci docker con podman se necessario)
docker ps
# atteso: registry (5000), rocky-ssh-server (2222->22), ubuntu-ssh-server (2223->22)

# il registry risponde e contiene le immagini pushate
curl http://localhost:5000/v2/_catalog
# atteso: {"repositories":["rocky-ssh","ubuntu-ssh"]}

# i tag di una singola immagine
curl http://localhost:5000/v2/rocky-ssh/tags/list

# accesso SSH ai due container, su porte diverse
ssh -i ~/.ssh/id_key_andrea -p 2222 andrea@localhost   # Rocky
ssh -i ~/.ssh/id_key_andrea -p 2223 andrea@localhost   # Ubuntu

# controprova del pull dal registry privato
docker rmi localhost:5000/rocky-ssh && docker pull localhost:5000/rocky-ssh
```