# Docker Registry con Ansible

`Playbook` **Ansible** che crea un registry Docker privato: un **magazzino di immagini personale** da usare al posto di Docker Hub. È raggiungibile solo dalla rete locale sulla porta `5000`, e funziona in HTTP senza autenticazione.

---

## Cosa fa il playbook, task per task

**1. Installa Docker**

Installa il pacchetto `docker.io` dai repository della distribuzione.
`update_cache: true` è l'equivalente di `apt update`: senza, su una macchina
appena installata, apt non sa nemmeno che il pacchetto esiste.

**2. Crea la directory dati del registry**

Crea `/opt/registry/data` sull'host. È lì che finiscono le immagini
che si pubblicano.

**3. Avvia il registry**

Fa partire il container `registry`:

- `ports: 5000:5000` — espone il registry sulla rete
- `volumes: /opt/registry/data:/var/lib/registry` — i dati vivono sull'host, non
  dentro il container: se il container viene ricreato, le immagini restano
- `restart_policy: always` — il registry riparte da solo dopo un riavvio della
  macchina.

**4. Crea /etc/docker e scrive daemon.json**

Docker vuole sempre parlare con i registry in HTTPS. Questo registry invece è in HTTP, quindi Docker si rifiuta di usarlo e dà questo errore:

```bash
http: server gave HTTP response to HTTPS client
```

Per farglielo accettare si aggiunge il registry alla lista delle eccezioni, nel file `/etc/docker/daemon.json`:

```json
{
  "insecure-registries": ["192.168.56.10:5000"]
}
```

L'eccezione vale solo per l'indirizzo elencato: per tutti gli altri registry Docker continua a pretendere HTTPS.

**5. Handler: riavvia Docker**

Docker legge `daemon.json` solo all'avvio, quindi va riavviato dopo una modifica.
Usando `notify` il riavvio scatta **solo quando il file cambia davvero**.

---

## Verifica

**Il container è attivo**

```
ansible registry -b -m command -a 'docker ps'
```

Bisogna vedere `registry:2` in stato `Up` con `0.0.0.0:5000->5000/tcp`.

**L'API risponde**

```
curl http://192.168.56.10:5000/v2/
```

Un `{}` con codice 200 significa che l'API del registry è viva.

**Il catalogo (all'inizio vuoto)**

```
curl http://192.168.56.10:5000/v2/_catalog
{"repositories":[]}
```

**La prova completa: push e pull**

```
docker pull alpine
docker tag alpine 192.168.56.10:5000/alpine:test
docker push 192.168.56.10:5000/alpine:test
```

Quello che decide a quale registry si parla è **il nome dell'immagine**: il
prefisso `192.168.56.10:5000/` indica a Docker dove mandare i dati. Senza
prefisso andrebbe su Docker Hub(default).

Ora il catalogo non è più vuoto:

```
curl http://192.168.56.10:5000/v2/_catalog
{"repositories":["alpine"]}

curl http://192.168.56.10:5000/v2/alpine/tags/list
{"name":"alpine","tags":["test"]}
```

**I dati sul disco**

```
ansible registry -b -m command -a 'ls /opt/registry/data/docker/registry/v2/repositories'
```

**I log del registry** mostrano le richieste ricevute, con IP del client

```
ansible registry -b -m command -a 'docker logs registry'
```