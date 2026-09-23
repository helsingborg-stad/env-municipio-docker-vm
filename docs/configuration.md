# Configuration

## Goal

Keep installation and runtime settings in one root-owned dotenv file. The interactive installer collects values and generates this file; operators can review it before any later reconfiguration.

The installed file is `/etc/municipio/municipio.env`, owned by root with mode `0600`.

## The file has two readers

This matters more than it used to. The file is read by:

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
MUNICIPIO_IMAGE=ghcr.io/municipio-se/municipio-deployment-docker@sha256:...
MARIADB_IMAGE=mariadb@sha256:...
CADDY_IMAGE=caddy@sha256:...
DB_NAME=municipio
DB_USER=municipio
DB_PASSWORD=...
DB_ROOT_PASSWORD=...
```

Set `DOCKER_SWARM=1` to use Swarm instead of Compose. It defaults to `0`. In a two-VM deployment, the preferred VM is the Swarm manager and the secondary VM joins as a worker.

## Images

All three services are pinned by digest and `validate_config` rejects mutable tags for every one of them. `update.municipio.sh` likewise requires a digest.

`MARIADB_IMAGE` and `CADDY_IMAGE` replace what were previously distribution packages. Changing either one is a deliberate operator action, not a side effect of an application deployment; there is no automatic database upgrade on image change.

## Credentials

`DB_ROOT_PASSWORD` is new. It initializes the database container's `root@localhost` account and is used by maintenance commands. The image is also given `MARIADB_ROOT_HOST=localhost`, so no `root@'%'` account is created.

In cluster modes the wizard requires both `DB_PASSWORD` and `DB_ROOT_PASSWORD` to be entered rather than generated, because a Galera state transfer replicates the privilege tables and both data VMs must agree. `cluster.municipio.sh join` verifies root access after the transfer and fails loudly on a mismatch.

## Modes

`standalone` requires no peer settings.

`cluster-manual` requires both data-node names and addresses. The primary node must be listed first because both Galera weighting and Gluster replica ordering use it as the preferred survivor.

`cluster-arbitrator` additionally requires an independent arbitrator name and address. The third host stores no MariaDB data and only Gluster metadata.

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

`DB_SOCKET_DIR` is deliberately not under `/run`. That is a tmpfs, so the directory would be gone after a reboot and the database container would start with nowhere to create its socket.

`DB_SOCKET_UID` and `DB_SOCKET_GID` default to `999` and must match the `mysql` user inside `MARIADB_IMAGE`. The installer verifies them against the running container and refuses a mismatch rather than leaving a socket the application cannot use.

In standalone mode Docker bind-mounts `DATA_ROOT` directly. In cluster mode the same path becomes the local GlusterFS view, backed by `GLUSTER_BRICK` on that VM's disk.

`SITE_ADDRESS` is the public WordPress hostname. `CADDY_SITE_ADDRESS` controls Caddy's listener. Use the hostname when Caddy terminates TLS, or `:80` when an upstream HTTP load balancer terminates TLS and forwards plaintext traffic to the VM.
