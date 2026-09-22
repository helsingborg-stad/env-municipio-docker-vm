# Maintenance scripts

## Goal

Provide identical commands whether invoked interactively, over SSH, or from CI.

## Installed commands

| Command | Purpose |
| --- | --- |
| `/scripts/status.municipio.sh` | Show app, Caddy, MariaDB, Galera, Gluster and health state. |
| `/scripts/update.municipio.sh DIGEST` | Back up and replace the local app container. |
| `/scripts/maintenance.municipio.sh on|off` | Remove or return the node from HTTP service. |
| `/scripts/backup.municipio.sh LABEL` | Dump MariaDB and archive persistent files. |
| `/scripts/health.municipio.sh` | Recalculate the health marker. |
| `/scripts/cluster.municipio.sh` | Explicitly bootstrap, join, inspect, restore storage quorum, or clear shared cache. |
| `/scripts/failover.municipio.sh` | Provision the DB or perform fenced manual promotion. |

Scripts serialize application updates with `flock`. Cluster creation is never part of unattended installation.
