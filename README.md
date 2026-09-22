# formazione_cm

Repository di esercitazioni pratiche su **Configuration Management** e **CI/CD**, sviluppate con **Ansible**, **Docker/Podman** e **Jenkins**.

## Struttura del repository

| Cartella | Contenuto |
|---|---|
| [`docker-build/`](docker-build/README.md) | Playbook Ansible che builda ed esegue container SSH multi-OS (Ubuntu 24.04 e Rocky Linux 9), con generazione automatica delle chiavi e test funzionali di accesso |
| [`docker-registry/`](docker-registry/README.md) | Playbook Ansible che crea e configura un registry Docker privato locale, come alternativa "self-hosted" a Docker Hub |
| [`roles/`](roles/README.md) | Collezione di ruoli Ansible riutilizzabili — registry, build delle immagini, push sul registry, installazione di Docker — pensati per essere compatibili sia con Docker che con Podman e parametrizzati tramite variabili |
| [`jenkins&ansible/`](jenkins&ansible/README.md) | Esercizio finale, il più completo: una pipeline Jenkins builda un'immagine, la tagga con un numero di build progressivo, la pusha su un registry locale e infine la deploya tramite Ansible dentro un container bersaglio, coordinando tre macchine diverse (Mac, VM Rocky, VM Debian) |

## Tecnologie utilizzate

- **Ansible** — automazione e configuration management degli host
- **Docker / Podman** — build ed esecuzione dei container
- **Jenkins** — orchestrazione della pipeline di CI/CD