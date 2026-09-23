# Maintenance scripts

## Goal

Provide simple local commands for maintenance after the interactive installation.

## Installed commands

| Command | Purpose |
| --- | --- |
| `/scripts/status.municipio.sh` | Show container, database, Galera, Gluster, socket and health state. |
| `/scripts/update.municipio.sh DIGEST` | Back up and replace the local app in Compose mode, or roll the shared service across data VMs from the Swarm manager. |
| `/scripts/maintenance.municipio.sh on\|off` | Remove or return the node from HTTP service. |
| `/scripts/backup.municipio.sh LABEL` | Dump MariaDB and archive persistent files. |
| `/scripts/health.municipio.sh` | Recalculate the health marker. |
| `/scripts/cluster.municipio.sh` | Bootstrap, join, clear the Galera bootstrap flag, enable a Swarm worker, inspect, restore storage quorum, or clear shared cache. |
| `/scripts/failover.municipio.sh` | Provision the DB or perform fenced manual promotion. |

Scripts serialize application updates with `flock`. Cluster creation is never part of unattended installation.

## Talking to a containerized database

No `mariadb` client is installed on the host. Every database command runs inside the database container through two helpers in `scripts/lib/common.sh`:

- `db_exec` — run a command in the local database container.
- `db_root` — the same, with the root password supplied through the exec environment so it never appears in a process list.

Both resolve the container first and fail with a distinct message when it is not running, so "the database is down" and "the database answered something unexpected" never share an exit path. `health.municipio.sh` depends on that distinction.

## Galera bootstrap flag

`cluster.municipio.sh clear-bootstrap-flag` is new and has no host-installed equivalent. It exists because `--wsrep-new-cluster` is a persistent container argument rather than a one-shot systemd setting; see [MariaDB and Galera](database.md). `status.municipio.sh` reports the flag on every run until it is cleared.
