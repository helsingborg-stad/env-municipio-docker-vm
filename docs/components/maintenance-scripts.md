# Maintenance scripts

## Goal

Provide simple local commands for maintenance after the interactive installation.

## Installed commands

| Command | Purpose |
| --- | --- |
| `/scripts/status.municipio.sh` | Show container, database, Galera, Gluster, socket and health state. |
| `/scripts/monitor.municipio.sh [--watch [SECONDS]]` | Draw an ASCII status board for this node and what it can see of its peers, with a fix hint for every problem. |
| `/scripts/update.municipio.sh DIGEST` | Back up and replace the local app in Compose mode, or roll the shared service across data VMs from the Swarm manager. |
| `/scripts/maintenance.municipio.sh on\|off` | Remove or return the node from HTTP service. |
| `/scripts/backup.municipio.sh LABEL` | Dump MariaDB and archive persistent files. |
| `/scripts/health.municipio.sh` | Recalculate the health marker. |
| `/scripts/cluster.municipio.sh` | Bootstrap, join, clear the Galera bootstrap flag, enable a Swarm worker, inspect, restore storage quorum, or clear shared cache. |
| `/scripts/failover.municipio.sh` | Provision the DB or perform fenced manual promotion. |
| `/scripts/refresh-sites.municipio.sh` | Discover local WordPress sites and refresh the Caddy host list; see [site discovery](../site-discovery.md). |

Scripts serialize application updates with `flock`. Cluster creation is never part of unattended installation.

## Talking to a containerized database

No `mariadb` client is installed on the host. Every database command runs inside the database container through two helpers in `scripts/lib/common.sh`:

- `db_exec` — run a command in the local database container.
- `db_root` — the same, with the root password supplied through the exec environment so it never appears in a process list.

Both resolve the container first and fail with a distinct message when it is not running, so "the database is down" and "the database answered something unexpected" never share an exit path. `health.municipio.sh` depends on that distinction.

## Galera bootstrap flag

`cluster.municipio.sh clear-bootstrap-flag` is new and has no host-installed equivalent. It exists because `--wsrep-new-cluster` is a persistent container argument rather than a one-shot systemd setting; see [MariaDB and Galera](database.md). `status.municipio.sh` reports the flag on every run until it is cleared.

## Status board

`monitor.municipio.sh` answers "is this setup correct right now?" on one screen:

1. A topology diagram matching [Architecture](../architecture.md). Every box carries the worst status of its component.
2. A table with one row per check.
3. A *what to do* list. It orders every warning and failure by severity and gives the command to run next.

```bash
sudo /scripts/monitor.municipio.sh             # one snapshot
sudo /scripts/monitor.municipio.sh --watch 5   # redraw every five seconds
/scripts/monitor.municipio.sh --demo cluster   # sample screen; also standalone, arbiter
```

The exit status is 0 when everything is OK, 1 on a warning and 2 on a failure, so cron or an external monitor can call it. Output is plain ASCII within 80 columns, except fix hints: they are commands to paste and are never cut. Colour is added only on a terminal and only repeats the `[ OK ]`, `[WARN]` and `[FAIL]` tags.

It is read-only. It does not run `health.municipio.sh`, because that script deletes the health marker before re-evaluating it. It reads the marker's age and the timer state instead. Each probe has its own timeout, so a hung peer or a stuck `gluster` command delays the screen by seconds.

It does not use SSH. A peer VM is judged by what this VM can observe:

- the peer's `/healthz` through its Caddy;
- its Galera (4567) and Gluster (24007) ports;
- Galera cluster size, Gluster peer and brick state, and Swarm node state.

Two values have to be compared by eye between the two screens:

- the **shared settings fingerprint**, a hash of the settings that must be identical on both data VMs (passwords excluded);
- the **Galera cluster UUID**. Different UUIDs mean the nodes formed two separate clusters.
