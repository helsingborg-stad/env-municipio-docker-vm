# Configuration

## Goal

Keep installation and runtime settings in one root-owned dotenv file. The interactive installer collects values and generates this file; operators can review it before any later reconfiguration.

The installed file is `/etc/municipio/municipio.env`, owned by root with mode `0600`.

## The file has two readers

The file is read by:

1. `bash source`, in the maintenance scripts; and
2. **Docker Compose's dotenv parser**, which supplies container environments.

The two do not decode escapes the same way. The installer therefore writes every value single-quoted — `DB_PASSWORD='a-$-complex-value'` — which is the only encoding both readers return identically for `$`, backslashes, spaces and shell operators. A value written with backslash escaping would reach the database and the container as two different strings, and the site would be locked out of its own database with no error at install time.

A value may not contain a single quote; the wizard refuses one, and `tests/check.sh` verifies the encoding round-trips through both parsers.

Hand-edit the file the same way: single-quote values, and do not place commands or command substitutions in it.

## Required common values

```dotenv
DEPLOYMENT_MODE=standalone
NODE_ROLE=data
NODE_NAME=municipio-01
NODE_ADDRESS=10.20.0.11
SITE_ADDRESS=www.example.se
CADDY_SITE_ADDRESS=www.example.se
ACME_DNS_PROVIDER=none
ACME_DNS_CHALLENGE_DOMAIN=
MUNICIPIO_IMAGE=ghcr.io/municipio-se/municipio-deployment-docker@sha256:...
MARIADB_IMAGE=mariadb@sha256:...
CADDY_IMAGE=ghcr.io/helsingborg-stad/municipio-caddy@sha256:...
DB_NAME=municipio
DB_USER=municipio
DB_PASSWORD=...
DB_ROOT_PASSWORD=...
```

Set `DOCKER_SWARM=1` to use Swarm instead of Compose. It defaults to `0`. In a two-VM deployment, the preferred VM is the Swarm manager and the secondary VM joins as a worker.

## Images

All three services are pinned by digest and `validate_config` rejects mutable tags for every one of them. `update.municipio.sh municipio [VERSION]` may accept a mutable tag such as `latest`, but resolves it to a digest before saving and deploying it.

Changing `MARIADB_IMAGE` or `CADDY_IMAGE` is a deliberate operator action, not a side effect of an application deployment; there is no automatic database upgrade on image change.

`CADDY_IMAGE` is Caddy with the [ACME DNS-01](#acme-dns-01) provider modules compiled in, because Caddy has no runtime plugins. It is built from [`docker/caddy/Dockerfile`](../docker/caddy/Dockerfile) by the *Caddy image* GitHub Actions workflow, which checks that both DNS modules are present before it publishes `ghcr.io/helsingborg-stad/municipio-caddy` and prints the digest in its run summary. To update Caddy or a module, change the pinned versions in the Dockerfile, merge to `main`, and copy the reported digest into `.env.example`. The same image serves HTTP-01, so every new installation uses it; an existing server keeps its saved `CADDY_IMAGE` until DNS-01 is chosen or the image is changed deliberately.

## Credentials

`DB_ROOT_PASSWORD` initializes the database container's `root@localhost` account and is used by maintenance commands. The image is also given `MARIADB_ROOT_HOST=localhost`, so no `root@'%'` account is created.

Editing `DB_ROOT_PASSWORD` in this file after installation does **not** change the password. The image applies it only when it initializes an empty data directory; afterwards the credential lives in the database itself, and every later maintenance command would fail with "Access denied". To rotate it, change the account first and then update the file:

```bash
sudo docker exec -it municipio-db mariadb -uroot -p \
  -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'new-password'; FLUSH PRIVILEGES;"
```

In a cluster the change replicates, so update the file on **both** data VMs.

In cluster modes both data VMs must agree on `DB_PASSWORD` and `DB_ROOT_PASSWORD`, because a Galera state transfer replicates the privilege tables. The wizard therefore asks for one shared *cluster password* and derives both values from it, as the first 48 hex characters of `sha256("municipio:<label>:<cluster password>")` with the labels `db-password` and `db-root-password`. Typing the same cluster password on each VM gives identical credentials regardless of install order. To match a VM installed with hand-chosen values, enter them directly under the wizard's advanced settings. `cluster.municipio.sh join` verifies root access after the transfer and fails loudly on a mismatch.

## Modes

`standalone` requires no peer settings.

`cluster-manual` requires both data-node names and addresses. The primary node must be listed first because both Galera weighting and Gluster replica ordering use it as the preferred survivor.

`cluster-arbitrator` additionally requires an independent arbitrator name and address. The third host stores no MariaDB data and only Gluster metadata.

The local `NODE_NAME` and `NODE_ADDRESS` must match the primary, secondary, or arbitrator entry for that VM. All three entries need distinct names and addresses. The arbitrator uses `NODE_ROLE=arbiter` and does not run Swarm.

## Paths

| Variable | Default | Notes |
| --- | --- | --- |
| `CONFIG_ROOT` | `/etc/municipio` | Holds the configuration, the generated `mariadb/` and `caddy/` config, and cluster markers. |
| `INSTALL_ROOT` | `/opt/municipio` | The installed Compose project. |
| `DATA_ROOT` | `/srv/municipio/data` | Uploads and cache. The Gluster view in cluster mode. |
| `DB_DATA_ROOT` | `/var/lib/municipio/mysql` | MariaDB data directory. **Local disk only.** |
| `DB_SOCKET_DIR` | `/var/lib/municipio/mysqld-socket` | Shared MariaDB socket. |
| `GLUSTER_BRICK` | `/srv/municipio/gluster-brick` | Cluster modes only. |
| `BACKUP_ROOT` | `/var/backups/municipio` | Local backups. |
| `HEALTH_ROOT` | `/var/lib/municipio/health` | The `/healthz` marker Caddy serves. |

`DB_DATA_ROOT` must not be inside `DATA_ROOT` or `GLUSTER_BRICK`; `validate_config` refuses that, because a MariaDB data directory on replicated storage corrupts silently.

`APP_BIND_ADDRESS` must remain `127.0.0.1`; the application port is for local Caddy only.

`DB_SOCKET_DIR` is deliberately not under `/run`. That is a tmpfs, so the directory would be gone after a reboot and the database container would start with nowhere to create its socket.

`DB_SOCKET_UID` and `DB_SOCKET_GID` default to `999` and must match the `mysql` user inside `MARIADB_IMAGE`. The installer verifies them against the running container and refuses a mismatch rather than leaving a socket the application cannot use.

In standalone mode Docker bind-mounts `DATA_ROOT` directly. In cluster mode the same path becomes the local GlusterFS view, backed by `GLUSTER_BRICK` on that VM's disk.

`SITE_ADDRESS` is the setup WordPress hostname and the temporary proxy seed until WordPress starts. It can be an IDN. WP-CLI discovers the actual Caddy host list thereafter, but the setup hostname must appear explicitly in the WordPress result before a refresh can replace existing routes. Set `CADDY_SITE_ADDRESS` equal to `SITE_ADDRESS` for Caddy-managed TLS, or `:80` when an upstream HTTP load balancer terminates TLS. It is a TLS-mode switch, not an override for the host list. See [WordPress site discovery](site-discovery.md).

## ACME DNS-01

By default Caddy uses HTTP validation. Set `ACME_DNS_PROVIDER` to `loopia` or `namedotcom` to use DNS-01. The default `CADDY_IMAGE` already includes both DNS modules (see [Images](#images)). A custom `CADDY_IMAGE` must include the matching module; the site refresh refuses to activate a configuration when it is absent.

| Provider | Required credentials | Caddy module |
| --- | --- | --- |
| `loopia` | `ACME_DNS_LOOPIA_USERNAME`, `ACME_DNS_LOOPIA_PASSWORD` | `github.com/caddy-dns/loopia` |
| `namedotcom` | `ACME_DNS_NAMEDOTCOM_USER`, `ACME_DNS_NAMEDOTCOM_TOKEN` | `github.com/caddy-dns/namedotcom` |

`ACME_DNS_NAMEDOTCOM_SERVER` defaults to `https://api.name.com`. Loopia needs a separate API user (normally ending in `@loopiaapi`), rather than the normal account login. Credentials may contain spaces, but not double quotes, backslashes, braces or line breaks; configuration validation and the installer reject them.

Leave `ACME_DNS_CHALLENGE_DOMAIN` empty for ordinary DNS-01: Caddy writes each site's normal `_acme-challenge.<site>` TXT record. To delegate a challenge to another DNS zone, create the CNAME yourself and set this value to its full target. For example, with a CNAME from `_acme-challenge.dns01.example.com` to `_acme-challenge.dns01.example.io` (note the top domain change), use:

```dotenv
ACME_DNS_PROVIDER=loopia
ACME_DNS_CHALLENGE_DOMAIN=_acme-challenge.dns01.example.io
ACME_DNS_LOOPIA_USERNAME=api-user@loopiaapi
ACME_DNS_LOOPIA_PASSWORD=...
```

The provider API credentials must control the target zone (`example.io` in this example), not necessarily the certificate hostname's zone. The installer offers the same choice and stores the selected credentials only in root-owned `/etc/municipio/municipio.env`. On a server installed before DNS-01 support, run the installer again: it detects the missing settings and asks this question without changing the rest of the configuration (see the [runbook](runbook.md)).
