# Ruolo `registry`

Crea un registry privato basato sull'immagine ufficiale `registry:2`, con storage persistente su bind mount, e configura l'engine per accettarlo come *insecure registry*.

## Struttura

```
registry/
├── defaults/main.yml     # path dati, nome/porta/immagine del registry, registry_host
├── handlers/main.yml     # "Riavvia Docker" (dopo la modifica di daemon.json)
├── templates/
│   └── daemon.json.j2    # configurazione insecure-registries per Docker
└── tasks/
    ├── main.yml          # directory dati + engine detection
    ├── docker.yaml       # variante Docker
    └── podman.yaml       # variante Podman
```

## Variabili

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

registry_host: 192.168.56.14    # IP/hostname con cui il registry viene raggiunto
```

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
| `registry_host` | `192.168.56.14` | host da dichiarare come *insecure registry* |
| `container_engine` | rilevato automaticamente | forza `docker` o `podman` bypassando la detection |

`registry_host` deve corrispondere all'indirizzo con cui il registry viene **effettivamente contattato**: è quello che finisce nella configurazione dell'engine, e un push verso un nome diverso da quello dichiarato non è coperto. Fa eccezione `localhost`, che Docker considera insicuro d'ufficio senza bisogno di dichiararlo: è il motivo per cui un push locale funziona comunque.

## Cosa fa (`tasks/main.yml`)

1. Crea `/opt/registry/data` con owner/group/permessi presi dalle variabili → i dati del registry sono **persistenti**, se ricrei il container le immagini restano.
2. Rileva l'engine.
3. Include `docker.yaml` o `podman.yaml`.

Il meccanismo di *engine detection* è spiegato in dettaglio nel [README generale](../README.md#il-meccanismo-dual-engine-docker--podman).

## Variante Docker (`tasks/docker.yaml`)

- Avvia il container `registry` con `community.docker.docker_container`: porta `5000:5000`, `restart_policy: always` (riparte da solo dopo un reboot), volume `/opt/registry/data:/var/lib/registry`.
- Crea `/etc/docker` e genera `daemon.json` dal template:

  ```jinja
  {
     "insecure-registries": ["{{ registry_host }}:{{ container.host_port }}"]
  }
  ```

  che rende, con i default:

  ```json
  {
     "insecure-registries": ["192.168.56.14:5000"]
  }
  ```

  Serve perché il registry parla **HTTP in chiaro**, mentre Docker per default pretende HTTPS con certificato valido: senza questa riga il push fallirebbe con `http: server gave HTTP response to HTTPS client`.
- Il task notifica l'handler **`Riavvia Docker`**: `daemon.json` viene letto solo all'avvio del demone, quindi il restart è indispensabile. Essendo un handler, scatta solo se il file è cambiato davvero.

Il template non richiede nessun path: Ansible cerca `src` dentro `templates/` del ruolo, e la ricerca è relativa al **ruolo**, non al file di task — per questo funziona anche da `docker.yaml` invece che da `main.yml`.

## Variante Podman (`tasks/podman.yaml`)

- Avvia il container con `containers.podman.podman_container`, stessa porta e stesso volume, ma immagine `docker.io/library/registry:2`: Podman non assume Docker Hub e vuole il registry esplicito nel nome.
- Con `blockinfile` aggiunge a `/etc/containers/registries.conf` il blocco:

  ```toml
  [[registry]]
  location = "192.168.56.10:5000"
  insecure = true
  ```

- Qui **non serve alcun restart**: Podman è daemonless e rilegge `registries.conf` a ogni invocazione. È anche il motivo per cui l'ordine dei due task è indifferente.

## Verifica

```bash
# il container è attivo
docker ps | grep registry      # oppure: podman ps | grep registry

# il registry risponde (prima del push il catalogo è vuoto)
curl http://localhost:5000/v2/_catalog
# atteso: {"repositories":[]}

# la configurazione è stata scritta
cat /etc/docker/daemon.json                     # Docker
grep -A2 '\[\[registry\]\]' /etc/containers/registries.conf   # Podman
```