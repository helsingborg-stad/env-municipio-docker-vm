# Maintenance scripts

## Goal

Provide simple local commands for maintenance after the interactive installation.

## Installed commands

| Command | Purpose |
| --- | --- |
| `/scripts/status.municipio.sh` | Show app, Caddy, MariaDB, Galera, Gluster and health state. |
| `/scripts/update.municipio.sh DIGEST` | Back up and replace the local app in Compose mode, or roll the shared service across data VMs from the Swarm manager. |
| `/scripts/maintenance.municipio.sh on|off` | Remove or return the node from HTTP service. |
| `/scripts/backup.municipio.sh LABEL` | Dump MariaDB and archive persistent files. |
| `/scripts/health.municipio.sh` | Recalculate the health marker. |
| `/scripts/cluster.municipio.sh` | Explicitly bootstrap, join, enable a Swarm worker, inspect, restore storage quorum, or clear shared cache. |
| `/scripts/failover.municipio.sh` | Provision the DB or perform fenced manual promotion. |
| `/scripts/change-domain.municipio.sh` | Preview and stage a guarded WordPress domain migration; see the [domain-change guide](../domain-change.md). |

Scripts serialize application updates with `flock`. Cluster creation is never part of unattended installation.
