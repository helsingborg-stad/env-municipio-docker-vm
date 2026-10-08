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

- Caddy runs as a container and proxies WordPress site hostnames to the local Municipio container.
- A timer discovers WordPress site hostnames and refreshes the Caddy configuration.
- Municipio runs from an immutable, digest-pinned Docker image.
- MariaDB runs as a container. The application connects only to its own VM through a shared Unix socket.
- Galera synchronizes databases in cluster modes.
- GlusterFS synchronizes uploads, cache, and Caddy certificate data in cluster modes. It stays on the host, because it is a kernel/FUSE storage layer rather than an application service.
- A health timer publishes `/healthz` only while the complete local node is usable. It stays on the host, because its cluster checks read the host's mount table.
- Maintenance commands are installed in `/scripts`.
- `DOCKER_SWARM=1` runs one coordinated Swarm service across the data VMs, with one local application task per VM. Swarm manages the application only.

The MariaDB and Caddy containers share the host network namespace so Galera can use the VMs' real addresses and Caddy can reach the local application over loopback; see [Architecture](docs/architecture.md) for the trade-off.

See [Architecture](docs/architecture.md), [Configuration](docs/configuration.md), [Docker Swarm mode](docs/components/swarm.md), [Host preparation](docs/components/host.md), [Network boundaries](docs/components/network.md), [Outbound connections](docs/outbound-connections.md), [WordPress site discovery](docs/site-discovery.md), and the [Runbook](docs/runbook.md).

## Quick start: standalone

On a fresh VM with one of the supported releases, download the installer and run it locally:

```bash
curl -fL https://install.getmunicipio.com/installer.sh -o installer.sh
sudo sh installer.sh
```

The wizard first asks how many servers the site runs on; press Enter for a single server. It then asks only for the website address, who handles HTTPS, the WordPress administrator's email and a login password. Database passwords, the server name and address, and Docker Compose are chosen automatically; an optional *advanced settings* question lets experienced operators change them. When it finishes, the Caddy, MariaDB and Municipio containers are running and enabled for reboot. The effective configuration is stored at `/etc/municipio/municipio.env`; operational commands are installed under `/scripts`.

The project documentation is published at [http://install.getmunicipio.com/](http://install.getmunicipio.com/). The custom domain serves the installer and uninstaller from this repository.

```bash
sudo /scripts/status.municipio.sh
sudo /scripts/update.municipio.sh ghcr.io/municipio-se/municipio-deployment-docker@sha256:<digest>
sudo /scripts/backup.municipio.sh manual
```

For the short walkthrough, see [Quick start](docs/quick-start.md). Two-VM and Swarm setups require peer coordination; see the [Runbook](docs/runbook.md).

## Uninstalling

`uninstaller.sh` returns a VM to its pre-install state. Like the installer, it is downloaded and run on its own, with no clone needed:

```bash
curl -fL https://install.getmunicipio.com/uninstaller.sh -o uninstaller.sh
sudo sh uninstaller.sh        # asks for confirmation; --yes skips it
sudo reboot
```

It removes the containers, Swarm membership, systemd units, firewall rules, Gluster volume, every Municipio directory, and Docker Engine with all of its data. The database, uploads and backups under `BACKUP_ROOT` are deleted, so copy anything you need off the VM first. Docker Engine is removed even if it was present before the install. Base packages such as `curl`, `tar` and `rsync` are kept. In cluster modes, run it on every node, including the arbitrator.
