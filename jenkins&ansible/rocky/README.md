# VM Rocky — Jenkins e i suoi agent (motore Podman)

## Che cos'è questa macchina

La VM **Rocky Linux** è il **cervello della CI**. Su di lei girano:

- il **controller Jenkins**, raggiungibile su `10.0.0.2:8080`;
- l'**agent di build** `jenkins-agent` (IP `10.0.0.3`, label `podman`), che esegue lo stage di build e push;
- l'**agent di deploy** `ansible` (IP `10.0.0.4`, label `ansible`), che esegue lo stage di deploy.

Il motore container qui è **Podman**, non Docker, e la rete è una rete Podman 

```
  VM ROCKY (Podman, rete network_1)
  ┌──────────────────────────────────────────────┐
  │  Jenkins controller   10.0.0.2:8080          │
  │        │                                     │
  │        ├─► agent build    10.0.0.3   ────────┼──► registry 192.168.56.14:5000
  │        │        /home/jenkins/agent          │
  │        │        socket podman dell'host      │
  │        │                                     │
  │        └─► agent deploy   10.0.0.4   ────────┼──► SSH 192.168.56.14:2224
  │                 /srv/ansible ─► /ansible     │
  └──────────────────────────────────────────────┘
```

---

## Cosa c'è in questa cartella

| File | Dove vive sulla VM | Cosa fa |
|---|---|---|
| `Dockerfile-ansible-agent` | copiato in `/home/andrea/build/` | Definisce l'immagine dell'agent di deploy (`ansible`) |
| `Dockerfile-podman-agent` | copiato in `/home/andrea/build/` | Definisce l'immagine dell'agent di build (`jenkins-agent2`) |
| `registry.conf.j2` | reso in `/etc/containers/registries.conf.d/insecure-registry.conf` | Autorizza Podman a usare il registry insicuro |
| `inventario` | `/srv/ansible/inventario` → `/ansible/inventario` | Dice ad Ansible chi è il bersaglio del deploy |
| `playbook-pipeline.yaml` | `/srv/ansible/playbook-pipeline.yaml` → `/ansible/playbook-pipeline.yaml` | Il playbook di deploy lanciato dalla pipeline |

Nessuno di questi file va copiato a mano: li portano qui i due playbook degli agent, leggendoli da `/etc/ansible/rocky/` sul Mac.

I due Dockerfile condividono la stessa directory di contesto, `/home/andrea/build`: è per questo che hanno nomi diversi e che entrambe le task di build indicano esplicitamente `build.file`.

La coppia di chiavi dell'agent ansible viene **generata sulla VM** dallo stesso playbook, in `/srv/ansible/ansible-agent-key` e `.pub`.

---

## I due agent, e perché sono due

| Agent | Label nel Jenkinsfile | Immagine | Strumenti | Stage che esegue |
|---|---|---|---|---|
| `jenkins-agent` (`10.0.0.3`) | `podman` | `jenkins-agent2`, da `Dockerfile-podman-agent` | client Podman collegato al socket dell'host, contesto di build montato | `build and push` |
| `ansible` (`10.0.0.4`) | `ansible` | `ansible`, da `Dockerfile-ansible-agent` | chiave SSH, playbook e inventario montati | `deploy immagine` |

Entrambi seguono lo stesso schema, ciascuno con il proprio playbook lanciato dal Mac — `mac/podman-agent.yaml` e `mac/ansible-agent.yaml` — che copia il contesto, builda l'immagine e avvia il container col segreto letto da `vault.yaml`.

---

## `Dockerfile-ansible-agent` — l'immagine dell'agent Ansible

```dockerfile
FROM jenkins/inbound-agent:latest

USER root

RUN apt-get update && \
    apt-get install -y rsync ansible python3-netaddr git curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

USER jenkins
```

**Perché partire da `jenkins/inbound-agent`** — è l'immagine ufficiale già pronta a registrarsi presso un controller Jenkins con il protocollo *inbound* (JNLP/WebSocket): contiene Java e lo script di aggancio al controller. Non c'è da reinventare quella parte, basta aggiungere sopra gli strumenti mancanti.

**Perché ogni pacchetto:**

- `ansible` — questo è l'unico agent che deve eseguire `ansible-playbook`.
- `python3-netaddr` — libreria richiesta da vari filtri e moduli Ansible che manipolano indirizzi IP e reti (per esempio il filtro `ipaddr`). Non sempre indispensabile, ma evita errori a runtime se un modulo la cerca.
- `rsync` — per eventuali sincronizzazioni di file verso i bersagli.
- `git` — per il checkout del codice nel workspace.
- `curl` e `ca-certificates` — per chiamate HTTPS affidabili verso registry o altri servizi.

**Perché `USER root` … `USER jenkins`** — l'installazione dei pacchetti richiede privilegi di root, ma l'agent deve poi girare con l'utente non privilegiato `jenkins`, quindi alla fine del Dockerfile si torna a quell'utente. È anche l'utente che possiede `/home/jenkins/agent`, la working directory.

---

## `Dockerfile-podman-agent` — l'immagine dell'agent di build

```dockerfile
FROM jenkins/inbound-agent:latest

USER root

RUN apt-get update && \
    apt-get install -y podman && \
    rm -rf /var/lib/apt/lists/*

RUN ln -s $(which podman) /usr/local/bin/docker

ENV CONTAINER_HOST=unix:///var/run/podman.sock

USER jenkins
```

Stessa base dell'altro agent — l'immagine ufficiale che sa già agganciarsi al controller — ma con strumenti opposti: qui non serve Ansible, serve saper parlare con un motore container.

- **`podman`** — è il **client**, non il motore. Dentro questo container non gira nessun demone: i comandi vengono inoltrati al Podman della VM attraverso il socket montato dal playbook.
- **`ln -s $(which podman) /usr/local/bin/docker`** — crea un alias `docker` che punta a `podman`. Serve a far funzionare senza modifiche tutto ciò che invoca `docker` per abitudine: script, plugin Jenkins, esempi copiati. Le due CLI sono compatibili sui comandi di uso comune, quindi `docker build` finisce per essere `podman build`.
- **`ENV CONTAINER_HOST=unix:///var/run/podman.sock`** — dice al client dove trovare il socket del motore. È la stessa variabile che il playbook passa anche via `env:`: averla nell'immagine significa che il client funziona anche se qualcuno avvia il container senza ripeterla.
- **`USER root` … `USER jenkins`** — come nell'altra immagine: si installa da root, si torna all'utente non privilegiato per l'esecuzione. Qui ha una conseguenza in più, ed è il motivo del `group_add` nel playbook: `jenkins` deve appartenere al gruppo proprietario del socket, altrimenti non riesce a usarlo.

---

## Cosa "riceve" questa macchina

### 1. Dal Mac: la costruzione dell'agent ansible

Il playbook `mac/ansible-agent.yaml` arriva da fuori e fa qui cinque cose in sequenza:

1. **copia `Dockerfile-ansible-agent` in `/home/andrea/build/`** — la directory viene creata al volo (lo slash finale in `dest`);
2. **builda l'immagine `ansible`** da quel contesto, con `podman_image` e `state: build`;
3. **copia `inventario` e `playbook-pipeline.yaml` in `/srv/ansible/`** — anche questa creata al volo;
4. **genera la coppia di chiavi** `ansible-agent-key` / `.pub` in `/srv/ansible`, di proprietà dell'uid 1000 e con permessi `0600`;
5. **avvia il container `ansible`**: rete `network_1`, IP `10.0.0.4`, SELinux disattivato per quel container (`label=disable`, necessario perché Podman possa leggere il bind mount senza rietichettare la directory), variabili `JENKINS_*` per l'auto-registrazione e il bind mount `/srv/ansible:/ansible`.

Le due directory restano separate di proposito: `/home/andrea/build` è solo contesto di build, `/srv/ansible` è il bind mount dell'agent. La chiave privata vive nella seconda e non entra mai nel contesto di build, quindi non può finire in un layer dell'immagine.

### 2. Dal Mac: la configurazione dell'agent podman

Il playbook `mac/podman-agent.yaml` fa qui cinque cose:

1. **rende `registry.conf.j2` in `/etc/containers/registries.conf.d/insecure-registry.conf`**, autorizzando Podman a usare il registry in HTTP;
2. **copia `Dockerfile-podman-agent` in `/home/andrea/build/`**;
3. **builda l'immagine `jenkins-agent2`** da quel contesto;
4. **copia `Dockerfile` ed `entrypoint.sh` di `docker-ssh` in `/home/jenkins/agent`**, il contesto che userà la pipeline;
5. **avvia il container `jenkins-agent`**, che riceve **il socket Podman dell'host** (`/run/podman/podman.sock`) più la variabile `CONTAINER_HOST`.

Il primo punto è quello che rende possibile il `podman push` della pipeline, e va sull'**host**, non nel container: il push lo esegue il Podman della VM, quindi è la sua configurazione a contare.

Il `podman` lanciato dentro quel container non avvia quindi un motore proprio: fa da client al Podman della VM, che è quello che esegue davvero build e push. `group_add: ["1234"]` serve a dargli il permesso di leggere quel socket.

### 3. Da Jenkins: l'esecuzione degli stage

A ogni build il controller assegna lavoro agli agent che vivono qui.

---

## La cartella `/srv/ansible`

È il ponte tra la VM e il container agent, e viene popolata interamente dal playbook:

```
/srv/ansible/
├── inventario                  (copiato dal Mac)
├── playbook-pipeline.yaml      (copiato dal Mac)
├── ansible-agent-key           (chiave PRIVATA, generata qui, uid 1000, 0600)
└── ansible-agent-key.pub       (chiave pubblica, generata qui)
```

Dentro il container agent la stessa cartella si vede come `/ansible`, ed è proprio quel percorso che compare nel `Jenkinsfile`:

```
ansible-playbook -i /ansible/inventario -e image=... /ansible/playbook-pipeline.yaml
```

Tenere questi file fuori dall'immagine significa poterli modificare senza ricostruire nulla — un inventario aggiornato è visibile subito dentro il container, senza nemmeno ricrearlo — e soprattutto **non far finire la chiave privata in un layer dell'immagine**.

Il playbook gira come root, ma dentro il container il processo che legge la chiave è l'utente `jenkins`, **uid 1000**. Con Podman rootful quell'uid coincide con l'uid 1000 dell'host, quindi una chiave `root:root 0600` risulta illeggibile all'agent; allargare i permessi non è una via d'uscita, perché SSH rifiuta le chiavi private leggibili da altri. Da qui `owner: "1000"` nella task di generazione.

---

## Cosa resta da preparare a mano

### La chiave pubblica sul bersaglio

Il contenuto di `/srv/ansible/ansible-agent-key.pub`, generato dal playbook, va installato nelle `authorized_keys` dell'utente `andrea` **dentro il container `docker-ssh` sulla VM Debian**. È l'unica credenziale che apre quel canale, perché lì l'autenticazione a password è disabilitata — ed è l'unico passaggio manuale in tutta la preparazione.

---

## `registry.conf.j2` — il registry insicuro lato Podman

Il `podman push` dello stage di build va verso un registry in **HTTP**, senza TLS. Per default Podman, come Docker, rifiuta di parlare in chiaro con un registry e fallisce con un errore di verifica TLS/certificato. Serve quindi una whitelist, che `mac/podman-agent.yaml` scrive con `ansible.builtin.template`:

```jinja
[[registry]]
location = "{{ registry_insicuro }}"
insecure = true
```

**Perché un template e non un file statico** — l'indirizzo del registry è l'unica cosa che cambia fra un ambiente e l'altro. Tenendolo in una variabile (`registry_insicuro`, definita nel playbook) il file resta riutilizzabile, e l'indirizzo compare in un posto solo invece che sparso nei file di configurazione.

**Perché in `registries.conf.d/` e non in `registries.conf`** — Podman legge la configurazione di sistema e poi vi fonde i frammenti trovati in `/etc/containers/registries.conf.d/`. Scrivendo lì un file dedicato non si sovrascrive il `registries.conf` della distribuzione, che contiene fra l'altro gli `unqualified-search-registries`: sostituirlo in blocco romperebbe la risoluzione dei nomi brevi delle immagini.

**Perché non serve riavviare nulla** — Podman non ha un demone che tenga la configurazione in memoria: la rilegge a ogni comando. Il file è efficace dalla `podman push` successiva.

È l'equivalente Podman del `daemon.json` con `insecure-registries` che sta sul lato Debian — con la differenza che quello vive *dentro* il container bersaglio e serve al pull, mentre questo vive sull'host Rocky e serve al push.

---

## `inventario` — chi è il bersaglio

```ini
[server]
192.168.56.14 ansible_user=andrea ansible_port=2224 ansible_ssh_private_key_file=/ansible/ansible-agent-key ansible_ssh_common_args='-o StrictHostKeyChecking=no'
```

- **`192.168.56.14`** — è l'IP della **VM Debian**, non del container. Il container non ha un indirizzo raggiungibile dall'esterno: lo si raggiunge attraverso il port mapping dell'host.
- **`ansible_port=2224`** — coerente con il `published_ports: "2224:22"` con cui il container è stato avviato. Ci si connette alla 2224 della VM Debian, e Docker inoltra la connessione alla porta 22 **dentro** il container `docker-ssh`. Quindi Ansible, pur sembrando connettersi alla VM, finisce nel container.
- **`ansible_user=andrea`** — l'utente creato nel Dockerfile del container, l'unico ammesso dal filtro `AllowUsers` del suo `sshd_config`.
- **`ansible_ssh_private_key_file=/ansible/ansible-agent-key`** — il percorso della chiave privata **visto da dentro il container agent**, cioè il bind mount di `/srv/ansible`.
- **`ansible_ssh_common_args='-o StrictHostKeyChecking=no'`** — è ciò che elimina l'ultimo prompt interattivo. Alla prima connessione verso un host mai visto, SSH chiederebbe conferma della fingerprint della chiave host remota e **attenderebbe una risposta**: una pipeline non può darla, e si blocca o fallisce con *host key verification failed*. Con `no` la verifica viene disattivata: gli host sconosciuti sono accettati senza chiedere nulla, e anche una chiave host cambiata produce al più un avviso invece di un errore bloccante.

---

## `playbook-pipeline.yaml` — il playbook di deploy

```yaml
- name: Deploy container
  hosts: server
  become: true
  gather_facts: false
  vars:
    image: 192.168.56.14:5000/docker-ssh:latest

  tasks:
    - name: Avvia il container
      community.docker.docker_container:
        name: docker-ssh
        image: "{{ image }}"
        state: started
        recreate: true
        published_ports:
          - "2224:22"
```

Questo playbook viene eseguito dall'agent `ansible`, ma tutti i suoi task si applicano al container bersaglio sulla VM Debian.

- **`hosts: server`** — il gruppo dell'inventario, cioè il container `docker-ssh` esterno sulla VM Debian.
- **`gather_facts: false`** — salta la raccolta dei facts di sistema: qui non servono e il playbook parte più in fretta.
- **`vars: image: ...:latest`** — un default ragionevole per un lancio manuale. Nella pipeline reale viene **sovrascritto** dal `-e image=...` passato da Jenkins, che inietta il tag progressivo appena buildato. È il meccanismo con cui il numero di build arriva fino al deploy.
- **`recreate: true`** — forza la rimozione e ricreazione del container anche se ne esiste già uno con lo stesso nome. Senza questa opzione, un container già in esecuzione verrebbe lasciato com'è e il deploy non aggiornerebbe nulla: il nome sarebbe lo stesso ma il contenuto resterebbe vecchio. È ciò che rende il deploy realmente aggiornante a ogni build.
- **`published_ports: "2224:22"`** — ripubblica la porta 22 del container interno sulla 2224, ma **a un livello di annidamento più interno**: dalla VM Debian al container esterno il mapping 2224→22 esiste già, qui lo stesso mapping viene rifatto dal container esterno verso quello interno.

Il fatto che il container interno si chiami anch'esso `docker-ssh` non è un errore: vive in un motore Docker completamente separato (quello *dentro* il container esterno), quindi non c'è alcun conflitto di nomi.