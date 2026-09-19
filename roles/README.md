# Ansible – Registry privato, build e push di container (Docker **e** Podman)

Collezione di ruoli Ansible che, eseguiti in sequenza, portano una macchina Linux "pulita" a:

1. avere un **registry Docker privato** in esecuzione e configurato come *insecure registry*;
2. **buildare due immagini** (Rocky Linux 9 e Ubuntu 24.04) a partire da un **unico template Jinja2** di Dockerfile;
3. **eseguire i container** delle due immagini **senza conflitti di porta**;
4. **taggare e pushare** le immagini sul registry creato al punto 1.

Tutto è **parametrizzato** tramite `defaults/main.yml` e tutti i ruoli funzionano **indifferentemente con Docker o con Podman**, grazie a un meccanismo di *engine detection* replicato in ogni ruolo.

## I ruoli

| Ruolo | Cosa fa | Documentazione |
|---|---|---|
| [`registry`](registry/) | crea e configura il registry privato | [registry/README.md](registry/README.md) |
| [`build-container`](build-container/) | genera la chiave, i Dockerfile, builda le immagini e avvia i container | [build-container/README.md](build-container/README.md) |
| [`push-images`](push-images/) | tagga le immagini e le pusha sul registry | [push-images/README.md](push-images/README.md) |
| [`docker`](docker/) | *(facoltativo)* installa Docker Engine | [docker/README.md](docker/README.md) |

## Struttura del progetto

```
roles/
├── README.md                 # questo file: panoramica e parti trasversali
├── playbook.yaml             # il playbook che esegue i ruoli in ordine
├── inventario                # inventory statico (host + credenziali)
│
├── registry/                 # 1. crea e configura il registry privato
│   ├── README.md
│   ├── defaults/main.yml     #    path dati, nome/porta/immagine del registry, registry_host
│   ├── handlers/main.yml     #    "Riavvia Docker" (dopo la modifica di daemon.json)
│   ├── templates/
│   │   └── daemon.json.j2    #    configurazione insecure-registries per Docker
│   └── tasks/
│       ├── main.yml          #    directory dati + engine detection
│       ├── docker.yaml       #    variante Docker
│       └── podman.yaml       #    variante Podman
│
├── build-container/          # 2+3. chiave SSH, Dockerfile, build e run dei container
│   ├── README.md
│   ├── defaults/main.yml     #    lista `dockerfile` (le immagini), `user`, `ssh_key_path`
│   ├── templates/
│   │   └── Dockerfile.j2     #    UN SOLO template per Rocky e Ubuntu
│   └── tasks/
│       ├── main.yml          #    utente + chiave + build context + template + engine detection
│       ├── docker.yaml       #    build & run con Docker
│       └── podman.yaml       #    build & run con Podman
│
├── push-images/              # 4. tag + push sul registry
│   ├── README.md
│   ├── defaults/main.yml     #    lista `images` (nome immagine + tag + repo di destinazione)
│   └── tasks/
│       ├── main.yml          #    engine detection
│       ├── docker.yaml       #    docker_image_tag + docker_image_push
│       └── podman.yaml       #    podman_image con push: true
│
└── docker/                   # (facoltativo) installazione di Docker Engine
    ├── README.md
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
| Insecure registry | `/etc/docker/daemon.json` generato da template + **restart del servizio** (handler) | blocco `[[registry]] … insecure = true` in `/etc/containers/registries.conf`, nessun restart necessario |
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
- **`build-container`** genera la chiave SSH, produce le immagini `rocky-ssh` e `ubuntu-ssh` e avvia i container.
- **`push-images`** tagga quelle immagini verso il registry e le pusha.

---

## Gestione dei conflitti di porta

Entrambi i container espongono internamente la **stessa** porta 22 (`port`) — cosa perfettamente lecita, perché ogni container ha il proprio network namespace — ma vengono pubblicati su **porte host diverse**:

| Container | Porta interna | Porta host | Comando |
|---|---|---|---|
| `rocky-ssh-server` | 22 | **2222** | `ssh -p 2222 andrea@<host>` |
| `ubuntu-ssh-server` | 22 | **2223** | `ssh -p 2223 andrea@<host>` |
| `registry` | 5000 | **5000** | `curl http://<host>:5000/v2/_catalog` |

---

## Playbook e inventory

**`playbook.yaml`**

```yaml
---
- name: Registry privato, build, run e push dei container
  hosts: deb
  become: true
  roles:
    - role: registry
    - role: build-container
    - role: push-images
```

`become: true` è necessario in tutti i ruoli: si scrive in `/opt`, in `/etc/docker`, si creano utenti e si parla col socket dell'engine.

Per installare anche Docker Engine, basta aggiungere `- role: docker` come **primo** elemento della lista.

**`inventario`** definisce l'host `deb` (una VM Vagrant), il suo IP e la chiave privata con cui Ansible ci si collega. Esecuzione:

```bash
ansible-playbook -i inventario playbook.yaml
```

---

## Parametrizzazione

Nessun task contiene valori hardcoded: tutto passa dai `defaults/`, quindi ogni valore è sovrascrivibile da `group_vars`, `host_vars`, `vars:` del playbook o `-e` da riga di comando (in ordine di precedenza crescente).

### Comune a tutti i ruoli

| Variabile | Default | Descrizione |
|---|---|---|
| `container_engine` | rilevato automaticamente | forza `docker` o `podman` bypassando la detection |

```bash
ansible-playbook -i inventario playbook.yaml -e container_engine=docker
```

---

## Verifica del risultato

Dalla macchina di destinazione, come root:

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
ssh -i /home/andrea/.ssh/id_key_andrea -p 2222 andrea@localhost   # Rocky
ssh -i /home/andrea/.ssh/id_key_andrea -p 2223 andrea@localhost   # Ubuntu

# controprova del pull dal registry privato
docker rmi localhost:5000/rocky-ssh && docker pull localhost:5000/rocky-ssh
```