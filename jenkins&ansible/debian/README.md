# VM Debian — il bersaglio del deploy e il registry (motore Docker)


## Che cos'è questa macchina

La VM **Debian** (`192.168.56.14`) è la macchina **passiva**: non lancia niente, riceve. Su di lei vivono due cose:

1. il **registry locale insicuro** sulla porta `5000`, dove l'agent Jenkins pusha le immagini;
2. il container **`docker-ssh`**, il bersaglio del deploy — un container che espone SSH e che, al proprio interno, esegue un **secondo** Docker daemon capace di avviare altri container.

Il motore qui è **Docker** (non Podman, che sta su Rocky).

```
  VM DEBIAN  192.168.56.14  (Docker)
  ┌────────────────────────────────────────────────────────────┐
  │  registry insicuro  :5000                                  │
  │                                                            │
  │  :2224 ──► container ESTERNO "docker-ssh" (privileged)     │
  │             ├── sshd :22        (PID 1, tiene vivo tutto)  │
  │             └── dockerd interno                            │
  │                   └── :2224 ──► container INTERNO          │
  │                                  "docker-ssh"  :22         │
  └────────────────────────────────────────────────────────────┘
```

---

## Cosa c'è in questa cartellla

| File | Cosa fa |
|---|---|
| `Dockerfile` | Definisce l'immagine `docker-ssh`: SSH + Docker + Python, utente `andrea` |
| `entrypoint.sh` | Avvia `dockerd` in background e `sshd` in foreground |

`mac/docker-ssh.yaml` li porta lui in **`/home/andrea/build`** sulla VM — leggendoli da `/etc/ansible/debian/` sul Mac — e quella directory è poi il `path` del contesto di build.

Gli stessi due file finiscono anche sulla VM Rocky, in `/home/jenkins/agent`, copiati da `mac/podman-agent.yaml`: è da lì che la pipeline ribuilda questa stessa immagine a ogni esecuzione, taggandola col numero di build. Quindi questo `Dockerfile` viene usato due volte — una per il container esterno, creato una tantum da Ansible, e una per l'immagine che la pipeline pusha nel registry e fa girare come container interno.

---

## `Dockerfile` — l'immagine del container bersaglio, riga per riga

```dockerfile
FROM ubuntu:24.04
```

Base Ubuntu LTS: serve un sistema con `apt` e un `sshd` completo, non un'immagine minimale.

```dockerfile
RUN apt-get update && \
    apt-get install -y sudo openssh-server docker.io python3 python3-docker && \
    rm -rf /var/lib/apt/lists/*
```

Perché ogni pacchetto:

- **`sudo`** — il requisito dell'esercizio è che l'utente possa fare `sudo`; serve anche perché il playbook di deploy usa `become: true`.
- **`openssh-server`** — il demone SSH, requisito *"servizio ssh attivo, in ascolto sulla 22"*. È il canale da cui entra Ansible.
- **`docker.io`** — il container deve avere **Docker attivo al proprio interno**: è questo che lo rende capace di ospitare il container interno del deploy.
- **`python3` e `python3-docker`** — sono la ragione tecnica per cui questo container può essere gestito da Ansible con i moduli `community.docker.*`. Quei moduli **non** usano la CLI `docker` via SSH: sono script Python che parlano con il socket Docker attraverso la libreria Python `docker`. Senza `python3-docker` il task di deploy fallisce con un errore del tipo *"Failed to import the required Python library (Docker SDK for Python)"*.
- **`rm -rf /var/lib/apt/lists/*`** — pulisce la cache di apt nello stesso layer, per non gonfiare l'immagine.

```dockerfile
RUN mkdir -p /var/run/sshd && \
    sed -i -E 's/^#?#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i -E 's/^#?PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i -E 's/^#?PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    echo 'AllowUsers andrea' >> /etc/ssh/sshd_config
```

Hardening dell'SSH, quattro decisioni:

- **`/var/run/sshd`** — directory di runtime che `sshd` pretende di trovare: senza, il demone si rifiuta di partire.
- **`PermitRootLogin no`** — niente login diretto come root.
- **`PasswordAuthentication no`** — si entra **solo con chiave pubblica**. È il motivo per cui la coppia di chiavi dell'agent non è un'opzione ma l'unico modo di entrare.
- **`PubkeyAuthentication yes`** — l'autenticazione a chiave resta esplicitamente attiva.
- **`AllowUsers andrea`** — whitelist: `sshd` accetta connessioni **solo** per l'utente `andrea`. È lo stesso nome che compare come `ansible_user` nell'inventario lato Rocky; se i due divergono, la connessione viene rifiutata a prescindere dalla chiave.

```dockerfile
RUN useradd --create-home --shell /bin/bash --groups sudo andrea && \
    echo "andrea ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    mkdir -p /home/andrea/.ssh && \
    chmod 700 /home/andrea/.ssh && \
    chown andrea:andrea /home/andrea/.ssh
```

- crea l'utente `andrea` con home e shell, nel gruppo `sudo`;
- **`NOPASSWD:ALL`** — indispensabile: il playbook di deploy usa `become: true`, e siccome l'accesso è a chiave l'utente **non ha una password** da digitare al prompt di sudo. Senza questa riga il `become` si bloccherebbe.
- prepara `/home/andrea/.ssh` con i permessi che `sshd` esige (`700`, di proprietà dell'utente): se sono più larghi, `sshd` ignora la chiave e l'accesso fallisce in modo silenzioso.

```dockerfile
RUN groupadd -f docker && usermod -aG docker andrea
```

Mette `andrea` nel gruppo `docker`, così può parlare con il socket `/var/run/docker.sock` del dockerd interno. `-f` evita l'errore se il gruppo esiste già (viene creato dal pacchetto `docker.io`).

```dockerfile
RUN mkdir -p /etc/docker && cat > /etc/docker/daemon.json <<'EOF'
{
  "insecure-registries": ["192.168.56.14:5000"]
}
EOF
```

Il registry non ha TLS. Per default Docker **rifiuta** di comunicare in chiaro con un registry e restituisce *"server gave HTTP response to HTTPS client"*. Dichiararlo in `insecure-registries` dice esplicitamente al dockerd *"per questo host va bene HTTP"*: è ciò che permette al **dockerd interno a questo container** di fare il `pull` dell'immagine pushata da Jenkins. Questa configurazione riguarda il Docker *dentro* il container, non quello della VM.

```dockerfile
EXPOSE 22

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
```

`EXPOSE 22` è documentazione dell'immagine (la pubblicazione vera avviene con `published_ports` al momento del run). Il comando di avvio non è direttamente `sshd` ma uno script wrapper.

---

## `entrypoint.sh` — due servizi in un container solo

```bash
#!/bin/bash

set -e

dockerd &> /var/log/dockerd.log &

sleep 10

exec /usr/sbin/sshd -D -e
```

Un container ha **un solo processo principale** (PID 1) e il suo ciclo di vita è legato a quel processo: quando muore, il container si ferma. Qui però servono **due servizi attivi contemporaneamente**: il demone Docker e `sshd`. La soluzione:

1. **`dockerd &> /var/log/dockerd.log &`** — avvia il demone Docker in background, redirigendo stdout e stderr su file. La redirezione serve perché, dopo l'`exec` finale, lo stdout del container apparterrà a `sshd`: senza file i log di dockerd andrebbero persi, ed è lì che si guarda quando il Docker interno non parte.
2. **`sleep 10`** — dockerd impiega qualche secondo a creare il socket e diventare operativo. La pausa evita che qualcosa tenti di parlargli prima che sia pronto. È una soluzione grezza: una versione più robusta attenderebbe attivamente la comparsa di `/var/run/docker.sock`.
3. **`exec /usr/sbin/sshd -D -e`** — `exec` **sostituisce** il processo corrente (lo script bash) con `sshd`, che diventa così il PID 1 effettivo. Da questo momento il container resta vivo finché resta vivo `sshd`. `-D` tiene il demone in foreground, `-e` manda i log su stderr, dove `docker logs` li può leggere.
4. **`set -e`** — se qualcosa fallisce prima dell'`exec`, lo script si ferma invece di proseguire in uno stato incoerente.

---

## Cosa "riceve" questa macchina

### 1. Dal Mac — la costruzione dell'ambiente (fase di preparazione)

Il playbook `mac/docker-ssh.yaml` fa qui quattro cose in sequenza:

1. **copia `Dockerfile` ed `entrypoint.sh` in `/home/andrea/build/`** — la directory viene creata al volo, perché `dest` finisce con lo slash;
2. **builda l'immagine `docker-ssh:latest`** da quel contesto;
3. **crea `/home/andrea/overlay`**, la directory che farà da stato del Docker interno;
4. **avvia il container esterno**.

Le opzioni dell'avvio sono:

- **`privileged: true`** — il container ottiene accesso quasi completo ai device dell'host e perde gran parte dell'isolamento. Serve **specificamente al Docker-in-Docker**: il dockerd interno deve poter creare namespace di rete, cgroup, device e mount overlay, operazioni vietate a un container normale.
- **`published_ports: "2224:22"`** — la porta 22 della VM è già occupata dall'SSH della VM stessa, quindi l'SSH del container viene pubblicato sulla **2224** della VM. Da qui in avanti, chiunque si colleghi a `192.168.56.14:2224` finisce **dentro il container**, non sulla VM.
- **`volumes: /home/andrea/overlay:/var/lib/docker`** — bind mount che risolve il problema *"overlay su overlay"*. Docker usa `overlay2` come storage driver e tiene il proprio stato in `/var/lib/docker`; se quella directory si trova dentro un container il cui filesystem radice è già montato in overlay, il kernel in molti casi non regge un overlay sopra un altro overlay e il dockerd interno fallisce all'avvio o durante il pull. Montare `/var/lib/docker` su una directory **reale della VM** gli dà una base pulita su cui costruire i propri layer.
- **`pull: never`** — l'immagine `docker-ssh` è stata appena buildata in locale e non esiste su nessun registry: senza questa opzione il modulo potrebbe cercarla su Docker Hub.

### 2. L'unico passaggio manuale — la chiave pubblica dell'agent

Il `Dockerfile` prepara `/home/andrea/.ssh` ma non ci mette dentro nessuna chiave, e nessun playbook lo fa. Dopo l'avvio del container va quindi installato a mano, in `/home/andrea/.ssh/authorized_keys` (proprietario `andrea`, permessi `600`), il contenuto di `/srv/ansible/ansible-agent-key.pub` generato sulla VM Rocky. Finché manca, l'agent Ansible non entra e lo stage di deploy fallisce con `Permission denied (publickey)`.

### 3. Dalla pipeline — il push e il deploy (a ogni build)

Durante ogni esecuzione della pipeline, questa macchina riceve due cose:

**a) Il push dell'immagine.** L'agent Podman su Rocky spinge `192.168.56.14:5000/docker-ssh:<BUILD_NUMBER>` nel registry locale. La VM qui è solo un deposito.

**b) La connessione SSH e il deploy.** L'agent Ansible si collega a `192.168.56.14:2224` come utente `andrea` con la propria chiave privata. Il traffico attraversa il port mapping e arriva all'`sshd` del container esterno. Da lì:

1. Ansible esegue i propri moduli Python **dentro il container esterno**, con `become: true` (possibile grazie a `NOPASSWD`).
2. Il modulo `community.docker.docker_container` parla, tramite la libreria `python3-docker`, con il **socket del dockerd interno** — quello avviato in background dall'entrypoint.
3. Con `recreate: true`, l'eventuale container interno `docker-ssh` precedente viene fermato e rimosso, e ne viene avviato uno nuovo dall'immagine `...:<BUILD_NUMBER>`.
4. Il dockerd interno scarica quell'immagine **dal registry sulla VM**, cosa possibile solo grazie a `insecure-registries` nel `daemon.json`.
5. Il nuovo container interno ripubblica la propria porta 22 sulla 2224, **questa volta all'interno del container esterno**.