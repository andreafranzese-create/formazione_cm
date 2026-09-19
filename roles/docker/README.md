# Ruolo `docker` (facoltativo)

Installa Docker Engine dai repository ufficiali.

## Struttura

```
docker/
├── defaults/main.yml     # docker_user, docker_packages
└── tasks/
    ├── main.yml          # include per OS family + install + service + gruppo docker
    ├── Debian.yaml       # repo APT ufficiale Docker (chiave GPG + deb822)
    └── RedHat.yaml       # repo YUM ufficiale Docker CE
```

## Variabili

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

| Variabile | Default | Descrizione |
|---|---|---|
| `docker_user` | `vagrant` | utente da aggiungere al gruppo `docker` |
| `docker_packages` | lista Docker CE | pacchetti da installare |

## Cosa fa (`tasks/main.yml`)

1. `include_tasks: "{{ ansible_os_family }}.yaml"` — stesso pattern di dispatch dinamico usato per il container engine negli altri ruoli, ma basato sul fatto `ansible_os_family`, quindi carica `Debian.yaml` o `RedHat.yaml`.
2. Installa `docker_packages` con il modulo generico `ansible.builtin.package` (astrae apt/dnf).
3. Avvia e abilita il servizio `docker`.
4. Aggiunge `docker_user` al gruppo `docker` con `append: true` (non sovrascrive gli altri gruppi dell'utente) così può usare Docker senza `sudo`.

**`Debian.yaml`** — installa `ca-certificates` e `python3-debian` (richiesto dal modulo `deb822_repository`), crea `/etc/apt/keyrings`, scarica la chiave GPG ufficiale e registra il repository in formato **deb822**, ricavando dinamicamente distro (`ansible_distribution | lower`), suite (`ansible_distribution_release`) e architettura (`amd64`/`arm64` da `ansible_architecture`).

**`RedHat.yaml`** — aggiunge il repo `docker-ce-stable` con `yum_repository`, `gpgcheck: true` e chiave ufficiale, versione maggiore presa da `ansible_distribution_major_version`; installa `python3-pip` per l'SDK Python di Docker, di cui hanno bisogno i moduli `community.docker` usati dagli altri ruoli.

## Verifica

```bash
docker --version
systemctl is-enabled docker
id vagrant | grep docker      # l'utente è nel gruppo docker
```