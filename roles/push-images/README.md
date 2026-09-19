# Ruolo `push-images`

Tagga le immagini costruite da `build-container` verso il registry privato e le carica.

## Struttura

```
push-images/
├── defaults/main.yml     # lista `images` (nome immagine + tag + repo di destinazione)
└── tasks/
    ├── main.yml          # engine detection
    ├── docker.yaml       # docker_image_tag + docker_image_push
    └── podman.yaml       # podman_image con push: true
```

## Variabili

**`defaults/main.yml`**

```yaml
images:
  - name: rocky-ssh
    tag: latest
    repo: localhost:5000
  - name: ubuntu-ssh
    tag: latest
    repo: localhost:5000
```



`repo` vale `localhost:5000` perché il push parte dalla stessa macchina che ospita il registry. Docker considera insicuri d'ufficio i registry su `localhost`, quindi in questa configurazione il push funziona anche senza che `localhost` compaia fra gli `insecure-registries`. Pushando da un'altra macchina, `repo` deve valere lo stesso indirizzo dichiarato in `registry_host` nel ruolo `registry`.

## Cosa fa (`tasks/main.yml`)

1. Rileva l'engine (stesso meccanismo degli altri ruoli, vedi il [README generale](../README.md#il-meccanismo-dual-engine-docker--podman)).
2. Include `docker.yaml` o `podman.yaml`.

## Variante Docker (`tasks/docker.yaml`)

Due step, come richiede il flusso Docker:

1. **`docker_image_tag`** crea un secondo riferimento per la stessa immagine: da `rocky-ssh:latest`
   (sorgente, indicata da `name` + `tag`) produce `localhost:5000/rocky-ssh:latest` (destinazione,
   indicata in `repository`). Non è una copia — l'immagine su disco resta una sola, cambia solo
   il nome con cui la si chiama. Il passaggio è obbligatorio perché **Docker deduce il registry
   di destinazione dal nome dell'immagine**: la parte prima del primo `/` (`localhost:5000`) è
   l'host verso cui pushare. Senza quel prefisso, `docker push rocky-ssh:latest` finirebbe su
   Docker Hub.
2. **`docker_image_push`** esegue il push verso quel repository.

## Variante Podman (`tasks/podman.yaml`)

Un solo step: `podman_image` con `push: true` e `push_args.dest: "{{ item.repo }}"` fa tag e push insieme.

## Verifica

```bash
# il registry contiene le immagini pushate
curl http://localhost:5000/v2/_catalog
# atteso: {"repositories":["rocky-ssh","ubuntu-ssh"]}

# i tag di una singola immagine
curl http://localhost:5000/v2/rocky-ssh/tags/list

# controprova del pull dal registry privato
docker rmi localhost:5000/rocky-ssh && docker pull localhost:5000/rocky-ssh
```