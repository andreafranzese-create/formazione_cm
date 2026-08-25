# Build di container SSH multi-OS con Ansible

Automazione, tramite Ansible, della **build di due immagini Docker basate su distribuzioni Linux diverse** (Ubuntu 24.04 e Rocky Linux 9) e del relativo avvio come container.

## Architettura e flusso di esecuzione

```
Control node (dove lanci ansible-playbook)
        │
        │  SSH
        ▼
   host "server3"  ──────────────────────────────────────────┐
        │                                                    │
        │ Docker daemon                                      │
        ├──► immagine ubuntu-ssh:latest ──► container        │
        │      ubuntu-ssh-server   0.0.0.0:2222 ──► :22      │
        │                                                    │
        └──► immagine rocky-ssh:latest  ──► container        │
               rocky-ssh-server    0.0.0.0:2223 ──► :22      │
                                                             │
   test: ssh -p 2222 andrea@127.0.0.1 'sudo whoami'  ────────┘
         ssh -p 2223 andrea@127.0.0.1 'sudo whoami'
```

Il flusso completo è:

1. Ansible si collega a `server3` e diventa root (`become: true`), perché parlare col socket Docker richiede privilegi.
2. Per ogni voce della lista `immagini`, costruisce l'immagine dal Dockerfile corrispondente.
3. Per ogni voce, avvia un container pubblicando la porta 22 interna su una porta diversa dell'host (2222 / 2223) — necessario perché due container non possono occupare la stessa porta host.
4. Esegue due test funzionali: si collega in SSH con la chiave e lancia `sudo whoami`. Se entrambi rispondono `root`, i tre requisiti dell'esercizio sono verificati end-to-end.
5. Stampa i risultati.

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
RUN useradd --create-home --shell /bin/bash --groups sudo andrea && \
    echo "andrea ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    mkdir -p /home/andrea/.ssh && \
    chmod 700 /home/andrea/.ssh && \
    chown andrea:andrea /home/andrea/.ssh
```

**`useradd`** crea l'utente, con tre opzioni che contano:

- `--create-home` crea `/home/andrea`. Senza, l'utente esisterebbe ma non avrebbe una home e senza home non c'è posto dove mettere `.ssh/authorized_keys`.
- `--shell /bin/bash` gli assegna una shell interattiva vera.
- `--groups sudo` lo mette nel gruppo `sudo`, che su Ubuntu è il gruppo degli amministratori.

**La riga in `/etc/sudoers`** `andrea ALL=(ALL) NOPASSWD:ALL`: l'utente `andrea`, su qualsiasi host (`ALL=`), può impersonare qualsiasi utente (`(ALL)`), eseguendo qualsiasi comando (`:ALL`), **senza che gli venga chiesta la password** (`NOPASSWD`).

**`mkdir` + `chmod 700` + `chown`** preparano la cartella `.ssh`. Il `700` (leggibile/scrivibile solo dal proprietario): `sshd` ha un controllo chiamato *StrictModes* e, se trova `~/.ssh` scrivibile dal gruppo o dagli altri, **ignora la chiave** e il login fallisce con un laconico `Permission denied (publickey)`.

#### Layer 5 

```dockerfile
COPY id_key_andrea.pub /home/andrea/.ssh/authorized_keys
```

Prende il file `id_key_andrea.pub` dal build context (la cartella `/root/immagini` sull'host) e lo mette dentro l'immagine, rinominandolo `authorized_keys` — che è esattamente il file dove `sshd` cerca le chiavi autorizzate per quell'utente.

#### Layer 6 

```dockerfile
RUN chmod 600 /home/andrea/.ssh/authorized_keys && \
    chown andrea:andrea /home/andrea/.ssh/authorized_keys
```

`COPY` inserisce il file come `root:root`. Se lo lasciassi così, `andrea` non ne sarebbe il proprietario e `sshd` — di nuovo per StrictModes — rifiuterebbe la chiave. Questi due comandi assegnano la proprietà all'utente giusto e restringono i permessi a "solo il proprietario può leggere e scrivere".

#### Layer 7 

```dockerfile
EXPOSE 22
```

È pura documentazione: dice a chi legge il Dockerfile che questa immagine offre un servizio sulla porta 22. Non apre nessuna porta verso l'esterno.

#### Layer 8 

```dockerfile
CMD ["/usr/sbin/sshd", "-D", "-e"]
```

Definisce il comando che viene lanciato quando il container parte. Non crea un layer di filesystem: è solo un'informazione salvata nei metadati dell'immagine.

**`-D`** (*don't detach*): normalmente `sshd` si "demonizza": si sdoppia, il processo padre termina e il figlio resta in background. Con `-D`, `sshd` resta in primo piano.

**`-e`** (*log to stderr*): normalmente `sshd` scrive i log su syslog. In un container syslog non gira, quindi i log finirebbero nel vuoto e non si avrebbe modo di capire perché un login fallisce. Con `-e` i log vanno su standard error, che è lo stream che si legge con `docker logs`.

---

## Dockerfile Rocky 

La logica è la stessa del file Ubuntu: installa, configura, crea l'utente, copia la chiave, avvia `sshd`. Cambia il "dialetto" della distribuzione. 

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
RUN useradd --create-home --shell /bin/bash --groups wheel andrea && \
    echo "andrea ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    mkdir -p /home/andrea/.ssh && \
    chmod 700 /home/andrea/.ssh && \
    chown andrea:andrea /home/andrea/.ssh
```

**Qui viene utilizzato `--groups wheel` invece di `--groups sudo`.** Il gruppo degli utenti autorizzati a usare `sudo`, ma le due famiglie lo chiamano diversamente:

- famiglia **Debian/Ubuntu** → gruppo `sudo`
- famiglia **RHEL/Rocky/Fedora/CentOS** → gruppo `wheel`

---

## Il playbook Ansible 

### Header

```yaml
- name: Build immagini docker con OS diversi
  hosts: server3
  become: true
  gather_facts: false
```

- `hosts: server3` — host in cui viene eseguito il playbook
- `become: true` — escalation a root
- `gather_facts: false` — salta la raccolta dei fatti. Qui nessun task usa variabili `ansible_*`

### Variabili

```yaml
  vars:
    immagini:
      - name: ubuntu-ssh
        container_name: ubuntu-ssh-server
        Dockerfile: Dockerfile-ubuntu
        port: 2222
      - name: rocky-ssh
        container_name: rocky-ssh-server
        Dockerfile: Dockerfile-rocky
        port: 2223
```

Invece di duplicare i task per ogni OS, tutta la variabilità è concentrata in una **lista di dizionari**, e i task la iterano con `loop`.

### Task 1 — Build delle immagini

```yaml
    - name: Build immagini docker
      community.docker.docker_image:
        name: "{{ item.name }}"
        tag: latest
        source: build
        build:
          path: /root/immagini
          dockerfile: "{{ item.Dockerfile }}"
      loop: "{{ immagini }}"
```

- `source: build` dice al modulo di **costruire** l'immagine
- `build.path` è il **build context**: la directory che viene inviata al Docker daemon. Tutto ciò che `COPY` referenzia deve stare lì dentro.
- `build.dockerfile` sceglie quale Dockerfile usare all'interno del context

### Task 2 — Avvio dei container

```yaml
    - name: Build container
      community.docker.docker_container:
        name: "{{ item.container_name }}"
        image: "{{ item.name }}:latest"
        state: started
        restart_policy: unless-stopped
        published_ports:
          - "{{ item.port }}:22"
      loop: "{{ immagini }}"
```

- `state: started` crea il container se non esiste e lo avvia; se esiste già ma con una configurazione diversa, il modulo lo ricrea.
- `restart_policy: unless-stopped`: Docker riavvia il container se il processo va in crash e al riavvio del daemon o dell'host, ma rispetta uno stop manuale esplicito.
- `published_ports: "2222:22"` mappa la porta 22 **del container** sulla 2222 **dell'host**.

### Task 3 e 4 — Test funzionali

```yaml
    - name: Test connessione ssh e sudo Ubuntu
      ansible.builtin.command:
        cmd: "ssh -i /home/andrea/.ssh/id_key_andrea -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null andrea@127.0.0.1 'sudo whoami'"
      register: test_ssh_ubuntu
      changed_when: false
```

Questo task verifica **tutti e tre i requisiti in un colpo solo**: se `sudo whoami` risponde `root`, allora il container è in ascolto, `sshd` è attivo, la chiave è stata accettata e l'utente ha privilegi sudo senza password.

Le opzioni:

- `-i` indica la chiave privata da usare.
- `-p 2222` la porta host mappata.
- `-o StrictHostKeyChecking=no` accetta la host key senza chiedere conferma. 
- `-o UserKnownHostsFile=/dev/null` evita di scrivere la host key in `~/.ssh/known_hosts`. Serve perché a ogni ricostruzione dell'immagine la host key cambia, e una voce vecchia genererebbe il temuto `REMOTE HOST IDENTIFICATION HAS CHANGED`, bloccando le esecuzioni successive.
- `register:` salva il risultato (stdout, stderr, rc) in una variabile.
- `changed_when: false` dichiara che il task non modifica nulla. Senza, `command` riporterebbe sempre `changed`, sporcando il report di idempotenza — un playbook rieseguito su un sistema già configurato dovrebbe risultare tutto `ok`.

Il task **fallisce** se `ssh` esce con codice diverso da zero, il che è il comportamento voluto: se il test non passa, il playbook si ferma.

### Task 5 — Report

```yaml
    - name: Stampa risultati
      ansible.builtin.debug:
        msg:
          - "Ubuntu: {{ test_ssh_ubuntu.stdout }}"
          - "Rocky: {{ test_ssh_rocky.stdout }}"
```

Stampa l'output dei due test. L'output atteso è:

```
ok: [server3] => {
    "msg": [
        "Ubuntu: root",
        "Rocky: root"
    ]
}
```