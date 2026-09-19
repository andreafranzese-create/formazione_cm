# Build di container SSH multi-OS con Ansible

Automazione, tramite Ansible, della **build di due immagini Docker basate su distribuzioni Linux diverse** (Ubuntu 24.04 e Rocky Linux 9) e del relativo avvio come container.

## Architettura e flusso di esecuzione

```
Control node
        │
        │  SSH
        ▼
   host "deb"  ───────────────────────────────────────────────────────┐
        │                                                             │
        │  1. crea l'utente andrea con UID 1500                       │
        │  2. genera la keypair ed25519 di andrea (di sua proprietà)  │
        │  3. crea la build context e ci copia i Dockerfile           │
        │                                                             │
        │ Docker daemon                                               │
        ├──► immagine ubuntu-ssh:latest ──► container                 │
        │      ubuntu-ssh-server   0.0.0.0:2222 ──► :22               │
        │      /home/andrea/.ssh/authorized_keys ◄─ mount ro ─┐       │
        │                                                     │       │
        └──► immagine rocky-ssh:latest  ──► container         │       │
               rocky-ssh-server    0.0.0.0:2223 ──► :22       │       │
               /home/andrea/.ssh/authorized_keys ◄─ mount ro ─┤       │
                                                              │       │
                                          id_key_andrea.pub ──┘       │
                                          (generata al passo 2)       │
                                                                      │
   test: ssh -i id_key_andrea -p 2222 andrea@127.0.0.1 'sudo whoami'──┘
         ssh -i id_key_andrea -p 2223 andrea@127.0.0.1 'sudo whoami'
```

Il flusso completo è:

1. Ansible si collega a `deb` e diventa root (`become: true`), perché parlare col socket Docker richiede privilegi.
2. Crea sull'host l'utente `andrea` con **UID 1500** e la sua home, così che i passi successivi abbiano un utente a cui intestare la chiave.
3. Genera una coppia di chiavi SSH (`ed25519`) per `andrea` direttamente sull'host, se non esiste già, intestandola all'utente appena creato (`owner`/`group`).
4. Crea la directory di build context sull'host e ci copia dentro i Dockerfile presenti sul control node.
5. Per ogni voce della lista `immagini`, costruisce l'immagine dal Dockerfile corrispondente. Dentro i Dockerfile l'utente `andrea` viene creato con lo **stesso UID 1500** dell'utente sull'host.
6. Per ogni voce, avvia un container pubblicando la porta 22 interna su una porta diversa dell'host (2222 / 2223) e montando la chiave pubblica appena generata come `authorized_keys`, in sola lettura.
7. Esegue due test funzionali: si collega in SSH con la chiave privata generata al passo 3 e lancia `sudo whoami`. Se entrambi rispondono `root`, i requisiti dell'esercizio sono verificati end-to-end.
8. Stampa i risultati.

### Perché l'UID deve coincidere

La chiave pubblica non viene copiata dentro l'immagine: viene **montata a runtime** dall'host come `/home/andrea/.ssh/authorized_keys`. Un bind mount non traduce gli utenti: il kernel espone la proprietà del file in forma **numerica**, quindi il file arriva nel container come "di proprietà dell'UID 1500" (l'`andrea` dell'host).

Dall'altra parte `sshd` applica *StrictModes*: `authorized_keys` deve appartenere all'utente che si collega (o a root) e non essere scrivibile da gruppo o altri, altrimenti il file viene **ignorato** e il login fallisce con `Permission denied (publickey)`.

Se dentro il container `andrea` avesse l'UID di default assegnato da `useradd` (1000), le due viste non combacerebbero: il file risulterebbe di un utente estraneo e la chiave verrebbe scartata. Per questo:

- il playbook crea `andrea` sull'host con `uid: 1500` e intesta a lui la keypair;
- entrambi i Dockerfile creano `andrea` con `useradd --uid 1500`.

---

## Dockerfile Ubuntu 

#### Layer 1

```dockerfile
FROM ubuntu:24.04
```

Dice a Docker di partire da un'immagine Ubuntu 24.04 già pronta, scaricata da Docker Hub. Dentro c'è un filesystem Ubuntu minimale: niente kernel (quello lo mette l'host), niente servizi in esecuzione, solo i file di base.

#### Layer 2

```dockerfile
RUN apt-get update && \
    apt-get install -y sudo openssh-server && \
    rm -rf /var/lib/apt/lists/*
```

- `apt-get update` scarica gli indici dei repository.
- `apt-get install -y sudo openssh-server` installa i due pacchetti. `openssh-server` è il demone `sshd`; `sudo` serve al requisito "poter fare sudo". 
- `rm -rf /var/lib/apt/lists/*` butta via gli indici appena usati, che pesano decine di MB e non servono più.

#### Layer 3

```dockerfile
RUN mkdir -p /var/run/sshd && \
    sed -i -E 's/^#?#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i -E 's/^#?PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i -E 's/^#?PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    echo 'AllowUsers andrea' >> /etc/ssh/sshd_config
```

**`mkdir -p /var/run/sshd`** — `sshd` si rifiuta di partire se non trova questa cartella (la usa per la *privilege separation*, un meccanismo di sicurezza che gli fa girare le parti rischiose in un processo senza privilegi). Su una macchina normale la crea systemd al boot; in un container systemd non c'è, quindi va creata a mano.

**I tre `sed`** modificano il file di configurazione `/etc/ssh/sshd_config`:

| Riga modificata | Cosa ottieni |
|---|---|
| `PermitRootLogin no` | Nessuno può collegarsi in SSH direttamente come root. Per fare cose da amministratore bisogna entrare come `andrea` e usare `sudo` — così ogni azione privilegiata è tracciabile |
| `PasswordAuthentication no` | Niente login con password: solo chiave. Rende inutili i tentativi di indovinare la password |
| `PubkeyAuthentication yes` | Abilita l'autenticazione a chiave. È già il default, ma scriverlo esplicito significa che non dipendi dal default di una futura immagine base |
| `AllowUsers andrea` | Una whitelist: `sshd` accetta login solo per l'utente `andrea`. Chiunque altro viene rifiutato prima ancora di provare le credenziali |

#### Layer 4

```dockerfile
RUN useradd --uid 1500 --create-home --shell /bin/bash --groups sudo andrea && \
    echo "andrea ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    mkdir -p /home/andrea/.ssh && \
    chmod 700 /home/andrea/.ssh && \
    chown andrea:andrea /home/andrea/.ssh
```

**`useradd`** crea l'utente, con quattro opzioni che contano:

- `--uid 1500` fissa l'UID numerico, allineandolo a quello dell'utente `andrea` sull'host. È quello che fa combaciare la proprietà del file `authorized_keys` montato a runtime (vedi *Perché l'UID deve coincidere*). Senza, `useradd` assegnerebbe il primo UID libero (tipicamente 1000) e il login a chiave fallirebbe.
- `--create-home` crea `/home/andrea`. Senza, l'utente esisterebbe ma non avrebbe una home e senza home non c'è posto dove mettere `.ssh/authorized_keys`.
- `--shell /bin/bash` gli assegna una shell interattiva vera.
- `--groups sudo` lo mette nel gruppo `sudo`, che su Ubuntu è il gruppo degli amministratori.

**La riga in `/etc/sudoers`** `andrea ALL=(ALL) NOPASSWD:ALL`: l'utente `andrea`, su qualsiasi host (`ALL=`), può impersonare qualsiasi utente (`(ALL)`), eseguendo qualsiasi comando (`:ALL`), **senza che gli venga chiesta la password** (`NOPASSWD`).

**`mkdir` + `chmod 700` + `chown`** preparano la cartella `.ssh`. Il `700` (leggibile/scrivibile solo dal proprietario): `sshd` ha un controllo chiamato *StrictModes* e, se trova `~/.ssh` scrivibile dal gruppo o dagli altri, **ignora la chiave** e il login fallisce con un laconico `Permission denied (publickey)`.

#### Layer 5 

```dockerfile
EXPOSE 22
```

È pura documentazione: dice a chi legge il Dockerfile che questa immagine offre un servizio sulla porta 22. Non apre nessuna porta verso l'esterno.

#### Layer 6

```dockerfile
CMD ["/usr/sbin/sshd", "-D", "-e"]
```

**`-D`** (*don't detach*): normalmente `sshd` si "demonizza": si sdoppia, il processo padre termina e il figlio resta in background. Con `-D`, `sshd` resta in primo piano.

**`-e`** (*log to stderr*): normalmente `sshd` scrive i log su syslog. In un container syslog non gira, quindi i log finirebbero nel vuoto e non si avrebbe modo di capire perché un login fallisce. Con `-e` i log vanno su standard error, che è lo stream che si legge con `docker logs`.

---

## Dockerfile Rocky 

La logica è la stessa del file Ubuntu: installa, configura, crea l'utente, avvia `sshd`. Cambia il "dialetto" della distribuzione.

### Layer differenti da ubuntu:

#### Layer 2 

```dockerfile
RUN dnf install -y sudo openssh-server && \
    rm -rf /var/cache/dnf
```

 Fa la stessa cosa del layer Ubuntu — installa server SSH e `sudo`, poi pulisce la cache.

**Qui manca `update`.** `apt` ha bisogno di un `apt-get update` esplicito per scaricare gli indici dei repository, che nell'immagine base non ci sono. `dnf` invece scarica e aggiorna i metadati da solo, quando servono: `dnf install` funziona anche senza.


#### Layer 3 

```dockerfile
RUN ssh-keygen -A
```

Genera le **host key** mancanti con cui il server dimostra al client di essere davvero lui. Finiscono in `/etc/ssh/ssh_host_*_key`. Il flag `-A` significa "genera tutti i tipi che mancano, e lascia stare quelli che già esistono".

Senza host key `sshd` non parte. Su Ubuntu il pacchetto `openssh-server` le genera nel suo script post-installazione, quindi sono già lì dopo `apt-get install`. Su RHEL/Rocky il pacchetto delega il compito a un servizio systemd che parte al boot — ma in un container systemd non gira, quindi quel servizio non viene mai eseguito e le chiavi non vengono mai create.

#### Layer 4 

```dockerfile
RUN sed -i -E 's/^#?#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i -E 's/^#?PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i -E 's/^#?PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    echo 'AllowUsers andrea' >> /etc/ssh/sshd_config
```

**Qui manca `mkdir -p /var/run/sshd`**. Quella cartella è una convenzione Debian/Ubuntu; su RHEL/Rocky la privilege separation directory è già gestita dal pacchetto e non va creata a mano.

#### Layer 5 

```dockerfile
RUN useradd --uid 1500 --create-home --shell /bin/bash --groups wheel andrea && \
    echo "andrea ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    mkdir -p /home/andrea/.ssh && \
    chmod 700 /home/andrea/.ssh && \
    chown andrea:andrea /home/andrea/.ssh
```

**Qui viene utilizzato `--groups wheel` invece di `--groups sudo`.** Il gruppo degli utenti autorizzati a usare `sudo`, ma le due famiglie lo chiamano diversamente:

- famiglia **Debian/Ubuntu** → gruppo `sudo`
- famiglia **RHEL/Rocky/Fedora/CentOS** → gruppo `wheel`

`--uid 1500` invece è identico nei due Dockerfile: l'allineamento con l'UID dell'utente sull'host non dipende dalla distribuzione.

---

## Il playbook Ansible 

### Header

```yaml
- name: Build immagini docker con OS diversi
  hosts: deb
  become: true
  gather_facts: false
```

- `hosts: deb` — host in cui viene eseguito il playbook
- `become: true` — escalation a root
- `gather_facts: false` — salta la raccolta dei fatti. Qui nessun task usa variabili `ansible_*`

### Variabili

```yaml
  vars:
    build_context: /root/immagini
    ssh_key_path: /home/andrea/.ssh/id_key_andrea
    immagini:
      - name: ubuntu-ssh
        container_name: ubuntu-ssh-server
        Dockerfile: Dockerfile-ubuntu
        port: 2222
      - name: rocky-ssh
        container_name: rocky-ssh-server
        Dockerfile: Dockerfile-rocky
        port: 2223
    user:
      name: andrea
      shell: /bin/bash
      uid: 1500
```

- `build_context` — la cartella sull'host `deb` dove finiscono i Dockerfile e da cui Docker costruisce le immagini. Prima era scritta a mano dentro ogni task che ne aveva bisogno; ora è una variabile unica.
- `ssh_key_path` — il percorso (senza estensione) della coppia di chiavi SSH di `andrea` sull'host `deb`. Da questa variabile derivano sia il file privato (`ssh_key_path`) sia il pubblico (`ssh_key_path.pub`), usati rispettivamente per i test SSH e per il mount in `authorized_keys`.
- `immagini` — invece di duplicare i task per ogni OS, tutta la variabilità specifica di ogni immagine è concentrata in una **lista di dizionari**, e i task la iterano con `loop`.
- `user` — i dati dell'utente creato sull'host: `name`, `shell` e soprattutto `uid`. L'UID è qui perché deve corrispondere a quello usato nei Dockerfile (`useradd --uid 1500`), altrimenti l'`authorized_keys` montato non risulta di proprietà di `andrea` dentro il container.

# Task del playbook Ansible

### Task 1 — Crea l'utente andrea

```yaml
    - name: Crea l'utente andrea
      ansible.builtin.user:
        name: "{{ user.name }}"
        shell: "{{ user.shell }}"
        uid: "{{ user.uid}}"
        create_home: true
```

Crea sull'host `deb` l'utente `andrea`, che è il proprietario della coppia di chiavi e il riferimento numerico per i container.

- `uid: "{{ user.uid }}"` — fissa l'UID a **1500** invece di lasciarlo scegliere al sistema. È il perno di tutto il meccanismo: lo stesso numero è usato dal `useradd --uid 1500` dentro i Dockerfile, e solo così il file montato come `authorized_keys` risulta di proprietà di `andrea` anche dentro il container.
- `create_home: true` — crea `/home/andrea`, cioè la directory sotto cui il task successivo scrive la coppia di chiavi (`ssh_key_path` punta a `/home/andrea/.ssh/id_key_andrea`).
- `shell: /bin/bash` — shell interattiva, coerente con quella dell'utente dentro i container.

È il **primo** task della lista perché i due task successivi dipendono da lui: la chiave viene scritta dentro la sua home e gli viene intestata, quindi l'utente deve già esistere. Il modulo è idempotente: a run successive l'utente c'è già e il task riporta `ok`.

### Task 2 — Genera coppia di chiavi SSH per andrea

```yaml
    - name: Genera coppia di chiavi SSH per andrea
      community.crypto.openssh_keypair:
        path: "{{ ssh_key_path }}"
        type: ed25519
        owner: "{{ user.name }}"
        group: "{{ user.name }}"
```

Genera sull'host una coppia di chiavi SSH per l'utente `andrea`, nel percorso indicato da `ssh_key_path`.

- `type: ed25519` sceglie l'algoritmo (più moderno e compatto di RSA).
- `owner` / `group` intestano i file della chiave ad `andrea`. Il playbook gira come root (`become: true`), quindi senza queste due righe chiave privata e pubblica resterebbero di root: la chiave verrebbe generata "per andrea" ma non gli apparterrebbe, e il `.pub` montato nel container arriverebbe con UID 0 invece che 1500. Così invece la proprietà è coerente su tutto il percorso host → mount → `sshd`.
- Il modulo è idempotente: se la coppia di chiavi esiste già in `ssh_key_path`, il task non fa nulla e riporta `ok` invece di `changed`. Rieseguire il playbook non genera una nuova chiave a ogni run, e i container restano accessibili con la stessa chiave tra un'esecuzione e l'altra.

### Task 3 — Crea la directory di build

```yaml
    - name: Crea la directory di build
      ansible.builtin.file:
        path: "{{ build_context }}"
        state: directory
        mode: "0755"
```

Crea, sull'host, la directory indicata da `build_context`, che farà da build context per Docker. `state: directory` dice al modulo `ansible.builtin.file` di assicurarsi che quel percorso esista come cartella (creandola se manca), con permessi `0755`.

### Task 4 — Copia i Dockerfile dal Mac

```yaml
    - name: Copia i Dockerfile dal Mac
      ansible.builtin.copy:
        src: "{{ item.Dockerfile }}"
        dest: "{{ build_context }}/{{ item.Dockerfile }}"
        mode: "0644"
      loop: "{{ immagini }}"
```

Per ogni voce della lista `immagini`, copia il Dockerfile corrispondente dal control node dentro la build context sull'host, con permessi `0644`. Il `loop: "{{ immagini }}"` fa eseguire il task una volta per ogni immagine da costruire (Ubuntu e Rocky), usando `item.Dockerfile` per sapere quale file copiare.

### Task 5 — Build delle immagini

```yaml
    - name: Build immagine docker
      community.docker.docker_image:
        name: "{{ item.name }}"
        tag: latest
        source: build
        build:
          path: "{{ build_context }}"
          dockerfile: "{{ item.Dockerfile }}"
      loop: "{{ immagini }}"
```

Per ogni voce di `immagini`, costruisce l'immagine Docker corrispondente.

- `source: build` dice al modulo di **costruire** l'immagine (invece di scaricarla da un registry).
- `build.path` è il **build context**: la directory che viene inviata al Docker daemon, presa dalla variabile `build_context`.
- `build.dockerfile` sceglie quale Dockerfile usare all'interno del context.
- `tag: latest` assegna il tag `latest` all'immagine appena costruita.

### Task 6 — Avvio dei container

```yaml
    - name: Build container
      community.docker.docker_container:
        name: "{{ item.container_name }}"
        image: "{{ item.name }}:latest"
        state: started
        restart_policy: unless-stopped
        published_ports:
          - "{{ item.port }}:22"
        volumes:
          - "{{ ssh_key_path }}.pub:/home/andrea/.ssh/authorized_keys:ro"
      loop: "{{ immagini }}"
```

Per ogni voce di `immagini`, crea e avvia il container corrispondente.

- `state: started` crea il container se non esiste e lo avvia; se esiste già ma con una configurazione diversa, il modulo lo ricrea.
- `restart_policy: unless-stopped`: Docker riavvia il container se il processo va in crash o al riavvio del daemon/host, ma rispetta uno stop manuale esplicito.
- `published_ports: "{{ item.port }}:22"` mappa la porta 22 **del container** sulla porta dell'host indicata da `item.port` (2222 per Ubuntu, 2223 per Rocky).
- `volumes: "{{ ssh_key_path }}.pub:/home/andrea/.ssh/authorized_keys:ro"` monta il file `{{ ssh_key_path }}.pub` — la chiave pubblica generata al Task 2 — dentro il container, al posto di `/home/andrea/.ssh/authorized_keys`, in sola lettura (`:ro`). È così che l'utente `andrea` nel container risulta autorizzato a collegarsi con quella chiave.

### Task 7 e 8 — Test funzionali

```yaml
    - name: Test connessione ssh e sudo Ubuntu
      ansible.builtin.command:
        cmd: "ssh -i {{ ssh_key_path }} -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null andrea@127.0.0.1 'sudo whoami'"
      register: test_ssh_ubuntu
      changed_when: false
```

Verifica che il container Ubuntu funzioni correttamente end-to-end: si collega in SSH come `andrea` ed esegue `sudo whoami`. Se risponde `root`, vuol dire che il container è in ascolto, `sshd` è attivo, la chiave montata al Task 6 è stata accettata e l'utente ha privilegi sudo senza password.

Le opzioni:

- `-i {{ ssh_key_path }}` indica la chiave privata da usare, quella generata al Task 2.
- `-p 2222` la porta host mappata.
- `-o StrictHostKeyChecking=no` accetta la host key senza chiedere conferma.
- `-o UserKnownHostsFile=/dev/null` evita di scrivere la host key in `~/.ssh/known_hosts`. Serve perché a ogni ricostruzione dell'immagine la host key cambia, e una voce vecchia genererebbe il temuto `REMOTE HOST IDENTIFICATION HAS CHANGED`, bloccando le esecuzioni successive.
- `register:` salva il risultato (stdout, stderr, rc) in una variabile.
- `changed_when: false` dichiara che il task non modifica nulla. Senza, `command` riporterebbe sempre `changed`, sporcando il report di idempotenza — un playbook rieseguito su un sistema già configurato dovrebbe risultare tutto `ok`.

Il task **fallisce** se `ssh` esce con codice diverso da zero, il che è il comportamento voluto: se il test non passa, il playbook si ferma. Il test su Rocky (`test_ssh_rocky`, porta 2223) fa la stessa cosa, cambia solo la porta.

### Task 9 — Report

```yaml
    - name: Stampa risultati
      ansible.builtin.debug:
        msg:
          - "Ubuntu: {{ test_ssh_ubuntu.stdout }}"
          - "Rocky: {{ test_ssh_rocky.stdout }}"
```

Stampa l'output dei due test tramite `ansible.builtin.debug`. L'output atteso è:

```
ok: [deb] => {
    "msg": [
        "Ubuntu: root",
        "Rocky: root"
    ]
}
```