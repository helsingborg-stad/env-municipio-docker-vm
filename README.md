# Municipio on a small VM fleet

This repository installs and operates Municipio on one or two amd64 Linux VMs. The installer accepts Ubuntu Server 22.04, 24.04, or 26.04 LTS, and Debian 12 or 13. The default is a single self-contained VM. Optional cluster modes keep a local MariaDB and a local copy of persistent files on every data VM.

Every long-running service runs as a digest-pinned container. A data VM installs a container runtime — not a database server and not a web server.

The design deliberately has no database load balancer, shared database endpoint, Kubernetes layer, or central file server.

## Supported modes

| Mode | Data VMs | Third voter | Failover |
| --- | ---: | ---: | --- |
| `standalone` | 1 | No | Restore or replace the VM manually. |
| `cluster-manual` | 2 | No | Preferred node survives; promotion of the other node requires fencing and a manual command. |
| `cluster-arbitrator` | 2 | Optional third host | Automatic quorum for one data-VM failure. |

`standalone` is the default.

## Components

- Caddy runs as a container and proxies only to the local Municipio container.
- Municipio runs from an immutable, digest-pinned Docker image.
- MariaDB runs as a container. The application connects only to its own VM through a shared Unix socket.
- Galera synchronizes databases in cluster modes.
- GlusterFS synchronizes uploads and cache directories in cluster modes. It stays on the host, because it is a kernel/FUSE storage layer rather than an application service.
- A health timer publishes `/healthz` only while the complete local node is usable. It stays on the host, because its cluster checks read the host's mount table.
- Maintenance commands are installed in `/scripts`.
- `DOCKER_SWARM=1` runs one coordinated Swarm service across the data VMs, with one local application task per VM. Swarm manages the application only.

The MariaDB and Caddy containers share the host network namespace. That keeps the published port matrix, the firewall policy and Galera's replication behaviour identical to the previous host-installed design; see [Architecture](docs/architecture.md) for the trade-off.

See [Architecture](docs/architecture.md), [Configuration](docs/configuration.md), [Docker Swarm mode](docs/components/swarm.md), [Host preparation](docs/components/host.md), [Network boundaries](docs/components/network.md), and the [Runbook](docs/runbook.md).

## Quick start: standalone

On a fresh VM with one of the supported releases, download the installer and run it locally:

```bash
curl -fL https://raw.githubusercontent.com/helsingborg-stad/env-municipio-docker-vm/main/installer.sh -o installer.sh
sudo sh installer.sh
```

The wizard asks for your hostname, website hostname, TLS choice, database credentials, and WordPress administrator. Press Enter to accept the standalone and Docker Compose defaults. When it finishes, the Caddy, MariaDB and Municipio containers are running and enabled for reboot. The effective configuration is stored at `/etc/municipio/municipio.env`; operational commands are installed under `/scripts`.

The URL above becomes usable when this repository's `main` branch is published. A friendly download domain can serve the same `installer.sh` file; see [Quick start](docs/quick-start.md) for publishing and verification notes.

```bash
sudo /scripts/status.municipio.sh
sudo /scripts/update.municipio.sh ghcr.io/municipio-se/municipio-deployment-docker@sha256:<digest>
sudo /scripts/backup.municipio.sh manual
```

For the short walkthrough, see [Quick start](docs/quick-start.md). Two-VM and Swarm setups require peer coordination; see the [Runbook](docs/runbook.md).

## Migrating from the host-installed layout

There is no in-place conversion. Back up, then install the containerized version on a fresh VM and restore. See [Runbook](docs/runbook.md#migrating-a-host-installed-node).

## Current maturity

This is a reviewable version. Standalone installation is the first validation target. Cluster bootstrap and failover must be tested on disposable VMs before production use, especially firewall policy, Gluster healing, full-cluster restart, the Galera bootstrap flag lifecycle, and Municipio's behavior behind HTTPS.

Run static checks with `make check`.
