# Mac — il control node Ansible

## Che cos'è questa macchina

Il Mac è la **workstation dell'operatore** e, in termini Ansible, il **control node**: la macchina da cui si lanciano i playbook.

È l'unica delle tre che **non ospita nulla**:

- non esegue container,
- non ospita Jenkins né il registry,
- non viene mai contattata dalle altre macchine,
- non compare in nessun inventario come host bersaglio.

Il suo ruolo è tutto in **fase di preparazione**: i tre playbook che stanno qui costruiscono da zero l'ambiente delle due VM — contesti di build, immagini, file operativi, chiavi e container. A pipeline avviata, il Mac può essere spento: la CI non dipende più da lui.

```
           ┌──── mac/docker-ssh.yaml ────►  VM Debian   contesto + immagine + overlay + container docker-ssh
           │
  MAC ─────┼──── mac/ansible-agent.yaml ─►  VM Rocky    contesto + immagine + /srv/ansible + chiavi + agent "ansible"
           │
           └──── mac/podman-agent.yaml ──►  VM Rocky    immagine + contesto di build in /home/jenkins/agent + agent "podman"
```

I file sorgente che i playbook copiano sulle VM stanno **sul Mac** in `/etc/ansible/debian/` e `/etc/ansible/rocky/`, cioè una copia delle cartelle `debian/` e `rocky/` di questo repository.

---

## Cosa c'è in questa cartella

| File | A chi è rivolto | Cosa fa |
|---|---|---|
| `docker-ssh.yaml` | VM Debian (`hosts: debian`) | Prepara il contesto, builda l'immagine `docker-ssh`, crea la directory del volume e avvia il container bersaglio |
| `ansible-agent.yaml` | VM Rocky (`hosts: rocky`) | Prepara il contesto, builda l'immagine dell'agent, popola `/srv/ansible`, genera le chiavi SSH e avvia l'agent Jenkins di deploy |
| `podman-agent.yaml` | VM Rocky (`hosts: rocky`) | Configura il registry insicuro, builda l'immagine dell'agent di build, copia il contesto della pipeline in `/home/jenkins/agent` e avvia l'agent |
| `vault.yaml` | — | File cifrato con Ansible Vault che contiene i segreti dei due agent |

---

## Prerequisiti sul Mac

Perché questi playbook funzionino, sul Mac servono:

1. **Le collection usate dai moduli**, che non fanno parte del core:
   ```bash
   ansible-galaxy collection install community.docker
   ansible-galaxy collection install containers.podman
   ansible-galaxy collection install community.crypto
   ```
   `community.crypto` serve per `openssh_keypair`, il modulo che genera la coppia di chiavi dell'agent.
2. **I file sorgente in `/etc/ansible/`**, perché è da lì che i playbook li copiano:
   ```
   /etc/ansible/debian/Dockerfile
   /etc/ansible/debian/entrypoint.sh
   /etc/ansible/rocky/Dockerfile-ansible-agent
   /etc/ansible/rocky/Dockerfile-podman-agent
   /etc/ansible/rocky/registry.conf.j2
   /etc/ansible/rocky/inventario
   /etc/ansible/rocky/playbook-pipeline.yaml
   ```

---

## `docker-ssh.yaml` — preparare la VM Debian

```yaml
- name: Crea il container con ssh e docker
  hosts: debian
  become: true

  tasks:
    - name: Copia il contesto di build
      ansible.builtin.copy:
        src: "{{ item }}"
        dest: /home/andrea/build/
      loop:
        - /etc/ansible/debian/Dockerfile
        - /etc/ansible/debian/entrypoint.sh

    - name: Build immagine docker
      community.docker.docker_image_build:
        name: docker-ssh
        tag: latest
        path: /home/andrea/build
        dockerfile: Dockerfile

    - name: Crea la directory per il volume
      ansible.builtin.file:
        path: /home/andrea/overlay
        state: directory
        owner: root
        group: root
        mode: '0755'

    - name: Avvia il container
      community.docker.docker_container:
        name: docker-ssh
        image: docker-ssh
        pull: never
        state: started
        privileged: true
        published_ports:
          - "2224:22"
        volumes:
          - /home/andrea/overlay:/var/lib/docker
```

- **`hosts: debian` + `become: true`** — agisce sulla VM Debian con privilegi di root, necessari per parlare con il socket Docker.
- **La `copy` con lo slash finale in `dest`** — `src` è sul Mac, `dest` sulla VM. Lo slash finale è quello che fa creare `/home/andrea/build` se non esiste e che fa finire i due file *dentro* la directory: senza, Ansible interpreterebbe `dest` come un file.
- **`docker_image_build` con `path: /home/andrea/build`** — l'immagine viene costruita **dal contesto che si trova sulla VM Debian**, cioè dai file appena copiati dalla task precedente.
- **`file: state=directory` su `/home/andrea/overlay`** — crea il punto di mount prima che serva. Senza, la creerebbe Docker al primo avvio: il risultato è lo stesso, ma così l'owner è esplicito. Sono comunque permessi in buona parte cosmetici, perché il dockerd interno gira come root e si riassegna da solo i permessi della propria directory di stato.
- **`pull: never`** — l'immagine `docker-ssh` esiste solo in locale, appena buildata. Senza questa opzione il modulo potrebbe tentare di scaricare da Docker Hub un'immagine con lo stesso nome; `pull: never` forza l'uso della cache locale.
- **`privileged: true`** — serve per il **Docker-in-Docker**: il dockerd che gira dentro il container ha bisogno di creare namespace di rete, cgroup, device e mount overlay, capability che un container normale non ha.
- **`published_ports: "2224:22"`** — pubblica l'SSH del container sulla porta 2224 della VM. La 22 della VM è già occupata dal suo SSH, quindi il container deve usarne un'altra. È lo stesso numero che ricompare nell'inventario usato dalla pipeline.
- **`volumes: /home/andrea/overlay:/var/lib/docker`** — evita il problema *overlay su overlay*: il dockerd interno tiene il proprio stato in `/var/lib/docker`, e se quella directory è dentro un filesystem già montato in `overlay2` il kernel spesso non regge il doppio strato. Il bind mount verso una directory reale dell'host dà al dockerd interno una base pulita.

Esecuzione tipica dal Mac:

```bash
ansible-playbook -i inventario mac/docker-ssh.yaml
```

Il dettaglio di ciò che viene costruito e di come è fatto il container è in [`debian/README.md`](../debian/README.md).

---

## `ansible-agent.yaml` — agganciare l'agent Jenkins sulla VM Rocky

```yaml
- hosts: rocky
  become: true
  vars_files:
    - vault.yaml

  tasks:
    - name: Copia il contesto di build
      ansible.builtin.copy:
        src: /etc/ansible/rocky/Dockerfile-ansible-agent
        dest: /home/andrea/build/

    - name: Build immagine
      containers.podman.podman_image:
        name: ansible
        state: build
        path: /home/andrea/build
        build:
          file: /home/andrea/build/Dockerfile-ansible-agent

    - name: Copia i file operativi di Ansible
      ansible.builtin.copy:
        src: "{{ item }}"
        dest: /srv/ansible/
      loop:
        - /etc/ansible/rocky/inventario
        - /etc/ansible/rocky/playbook-pipeline.yaml

    - name: Genera la coppia di chiavi dell'agent
      community.crypto.openssh_keypair:
        path: /srv/ansible/ansible-agent-key
        type: ed25519
        owner: "1000"
        group: "1000"
        mode: "0600"

    - name: Avvia l'agent jenkins
      containers.podman.podman_container:
        name: ansible
        image: ansible
        pull: never
        network: network_1
        ip: "10.0.0.4"
        security_opt:
          - "label=disable"
        env:
          JENKINS_URL: "http://10.0.0.2:8080"
          JENKINS_AGENT_NAME: ansible
          JENKINS_SECRET: "{{ ansible_secret }}"
          JENKINS_AGENT_WORKDIR: /home/jenkins/agent
        volumes:
          - /srv/ansible:/ansible
        state: started
```

- **`containers.podman.podman_image` con `state: build`** — costruisce l'immagine **sulla VM Rocky** dal contesto appena copiato. `state: build` è quello che forza il build: con il default `present` il modulo, non trovando l'immagine, tenterebbe di scaricarla. Il contesto è il parametro `path`; `build.file` serve solo perché il file si chiama `Dockerfile-ansible-agent` e non `Containerfile`.
- **`openssh_keypair`** — genera `ansible-agent-key` e `ansible-agent-key.pub` direttamente in `/srv/ansible`, ed è idempotente: se la coppia c'è già non la rigenera. `owner: "1000"`: il play gira come root, ma dentro il container la chiave viene letta dall'utente `jenkins`, che ha **uid 1000**. Con Podman rootful quell'uid è lo stesso sull'host, quindi un file `root:root 0600` risulterebbe illeggibile all'agent; e allargare i permessi non è un'opzione, perché SSH rifiuta le chiavi private leggibili da altri.
- **`containers.podman.podman_container`** — sulla VM Rocky il motore è **Podman**, non Docker: serve la collection `containers.podman`.
- **`image: ansible` + `pull: never`** — usa l'immagine costruita dalla task precedente. `pull: never` impedisce a Podman di scaricare da un registry pubblico un'immagine che si chiama genericamente "ansible".
- **`network: network_1`, `ip: "10.0.0.4"`** — l'agent viene collegato a una rete Podman dedicata con **IP statico**, così il controller (`10.0.0.2`) e l'agent si vedono con indirizzi stabili tra un riavvio e l'altro.
- **`security_opt: ["label=disable"]`** — Rocky Linux ha **SELinux attivo di default**. Quando Podman monta una directory dell'host dentro un container, l'etichetta SELinux della directory deve corrispondere a quella attesa dal container, altrimenti l'accesso viene negato. `label=disable` disattiva l'enforcement dell'etichettatura per questo container, permettendo la lettura del bind mount `/srv/ansible` senza rietichettare a mano.
- **Variabili `JENKINS_*`** — sono i parametri che l'immagine ufficiale `jenkins/inbound-agent` si aspetta per registrarsi da sola presso il controller: URL del controller, nome con cui l'agent si presenta (`ansible`, che è anche la label usata nel `Jenkinsfile`), il segreto di autenticazione e la working directory in cui Jenkins scarica il workspace.
- **`volumes: /srv/ansible:/ansible`** — monta dentro il container la cartella popolata dalle due task precedenti: inventario, playbook di deploy e chiave privata SSH. Restano **fuori dall'immagine**: così si possono modificare senza ricostruirla, e la chiave privata non finisce mai in un layer.

---

## `podman-agent.yaml` — l'agent di build sulla VM Rocky

```yaml
- name: Configurazione agent jenkins
  hosts: rocky
  become: true
  vars_files:
    - vault.yaml
  vars:
    registry_insicuro: "192.168.56.14:5000"

  tasks:
    - name: Configura il registry insicuro per Podman
      ansible.builtin.template:
        src: /etc/ansible/rocky/registry.conf.j2
        dest: /etc/containers/registries.conf.d/insecure-registry.conf
        owner: root
        group: root
        mode: "0644"

    - name: Copia il contesto di build dell'immagine agent
      ansible.builtin.copy:
        src: /etc/ansible/rocky/Dockerfile-podman-agent
        dest: /home/andrea/build/

    - name: Build immagine
      containers.podman.podman_image:
        name: jenkins-agent2
        state: build
        path: /home/andrea/build
        build:
          file: /home/andrea/build/Dockerfile-podman-agent

    - name: Copia il contesto di build della pipeline
      ansible.builtin.copy:
        src: "{{ item }}"
        dest: /home/jenkins/agent/
        owner: "1000"
        group: "1000"
      loop:
        - /etc/ansible/debian/Dockerfile
        - /etc/ansible/debian/entrypoint.sh

    - name: Avvia l'agent jenkins
      containers.podman.podman_container:
        name: jenkins-agent
        image: jenkins-agent2
        pull: never
        network: network_1
        ip: "10.0.0.3"
        security_opt:
          - "label=disable"
        group_add:
          - "1234"
        volumes:
          - "/home/jenkins/agent:/home/jenkins/agent"
          - "/run/podman/podman.sock:/var/run/podman.sock"
        env:
          JENKINS_URL: "http://10.0.0.2:8080"
          JENKINS_AGENT_NAME: agent-1
          JENKINS_SECRET: "{{ podman_secret }}"
          JENKINS_AGENT_WORKDIR: /home/jenkins/agent
          CONTAINER_HOST: "unix:///var/run/podman.sock"
        state: started
```

- **`volumes: /run/podman/podman.sock:/var/run/podman.sock` + `CONTAINER_HOST`** — il comando `podman` lanciato dentro il container non avvia un motore proprio: parla via socket con il **Podman dell'host**, che è quello che esegue davvero build e push. `CONTAINER_HOST` è la variabile che dice al client dove trovare quel socket.
- **`group_add: ["1234"]`** — il socket di Podman è leggibile solo dal proprio gruppo: aggiungere quel gid all'utente del container è ciò che gli dà il permesso di usarlo. Senza, ogni comando fallisce con *permission denied* sul socket.
- **`volumes: /home/jenkins/agent:/home/jenkins/agent`** — lo stesso percorso da entrambe le parti, e non è un vezzo: siccome il build viene eseguito dal Podman dell'host, il contesto passato con `podman build ... /home/jenkins/agent` viene risolto **sul filesystem dell'host**. Montarlo allo stesso path è ciò che fa combaciare quello che vede l'agent con quello che vede il motore.
- **La `copy` del contesto** — da qui discende che per automatizzare la presenza del Dockerfile basta copiarlo in `/home/jenkins/agent` **sulla VM**, senza toccare il container. Sono gli stessi due file che vanno sulla VM Debian, perché l'immagine che la pipeline builda e pusha è proprio `docker-ssh`: senza `entrypoint.sh` il `COPY` del Dockerfile fallirebbe. `owner: "1000"` tiene la directory coerente con l'utente `jenkins`, che è anche quello con cui Jenkins ci scrive i workspace.
- **`ip: "10.0.0.3"`** — indirizzo statico sulla stessa rete `network_1`, distinto dal `10.0.0.4` dell'agent di deploy.
- **`template` su `registries.conf.d/`** — scrive la whitelist del registry insicuro, senza cui il `podman push` della pipeline fallisce con un errore di verifica TLS. Va in `/etc/containers/registries.conf.d/`, la directory di frammenti che Podman fonde con la configurazione di sistema: così non si tocca `registries.conf` e non si rischia di cancellare i default della distribuzione. L'indirizzo arriva dalla variabile `registry_insicuro`, il che rende il file riutilizzabile se un giorno il registry cambia macchina. Non serve riavviare niente: Podman rilegge la configurazione a ogni comando.
- **`podman_image` con `state: build`** — costruisce `jenkins-agent2` da `rocky/Dockerfile-podman-agent`, copiato in `/home/andrea/build`. È la **stessa directory** che usa l'altro agent come contesto: per questo `build.file` è obbligatorio e i due Dockerfile devono avere nomi diversi, altrimenti si sovrascriverebbero.
- **`image: jenkins-agent2` + `pull: never`** — usa l'immagine appena costruita; `pull: never` impedisce a Podman di cercare quel nome su un registry pubblico.

Mettere i due file nella radice della workdir è sicuro: Jenkins crea i workspace dei job in sottodirectory (`workspace/<nome-job>`), quindi non vengono toccati tra una build e l'altra.

---

## `vault.yaml` — i segreti degli agent

```
$ANSIBLE_VAULT;1.1;AES256
32653231663235376263623666376631326139326430376439633663613838326166316439643064
...
```

Il `JENKINS_SECRET` è la credenziale con cui un agent dimostra al controller di essere davvero quell'agent. Scritto in chiaro dentro il playbook finirebbe nel repository e nella cronologia Git, quindi i segreti stanno in un file separato **cifrato con Ansible Vault**, richiamato da entrambi i playbook degli agent con `vars_files`.