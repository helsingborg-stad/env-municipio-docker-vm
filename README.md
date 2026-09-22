# Municipio on a small VM fleet

This repository installs and operates the Municipio container on one or two Ubuntu Server 24.04 LTS amd64 VMs. The default is a single self-contained VM. Optional cluster modes keep a local MariaDB and a local copy of persistent files on every data VM.

The design deliberately has no database load balancer, shared database endpoint, Kubernetes layer, or central file server.

## Supported modes

| Mode | Data VMs | Third voter | Failover |
| --- | ---: | ---: | --- |
| `standalone` | 1 | No | Restore or replace the VM manually. |
| `cluster-manual` | 2 | No | Preferred node survives; promotion of the other node requires fencing and a manual command. |
| `cluster-arbitrator` | 2 | Optional third host | Automatic quorum for one data-VM failure. |

`standalone` is the default.

## Components

- Caddy runs on the host and proxies only to the local Municipio container.
- Municipio runs from an immutable, digest-pinned Docker image.
- MariaDB runs on the host. The container connects only to its own VM through a Unix socket.
- Galera synchronizes databases in cluster modes.
- GlusterFS synchronizes uploads and cache directories in cluster modes.
- A health timer publishes `/healthz` only while the complete local node is usable.
- Maintenance commands are installed in `/scripts`.
- A documented runtime override fixes forwarded HTTPS and `WP_CONTENT_URL` behavior in image `6.2.5`.
- `DOCKER_SWARM=1` switches application execution from Compose to an independent single-node Swarm on each VM.

See [Architecture](docs/architecture.md), [Configuration](docs/configuration.md), [Docker Swarm mode](docs/components/swarm.md), [Host preparation](docs/components/host.md), [Network boundaries](docs/components/network.md), and the [Runbook](docs/runbook.md).

## Quick start: standalone

On a fresh Ubuntu Server 24.04 LTS amd64 VM:

```bash
git clone <this-repository> /tmp/municipio-installer
cd /tmp/municipio-installer
cp .env.example .env
sudo editor .env
sudo ./bin/install.sh --env-file "$PWD/.env"
```

The installer copies the effective configuration to `/etc/municipio/municipio.env` and installs operational commands under `/scripts`.

```bash
sudo /scripts/status.municipio.sh
sudo /scripts/update.municipio.sh ghcr.io/municipio-se/municipio-deployment-docker@sha256:<digest>
sudo /scripts/backup.municipio.sh manual
```

## Run remotely

```bash
rsync -a --delete ./ deploy@example:/tmp/municipio-installer/
ssh deploy@example 'sudo /tmp/municipio-installer/bin/install.sh --env-file /tmp/municipio-installer/.env'
```

CI uses the same command. Generate a shell-compatible dotenv file from protected CI variables, copy the repository and file to the target, then invoke `install.sh` over SSH. Never pass database passwords as command-line arguments.

## Current maturity

This is a reviewable first version. Standalone installation is the first validation target. Cluster bootstrap and failover must be tested on disposable VMs before production use, especially firewall policy, package paths, Gluster healing, full-cluster restart, and Municipio's behavior behind HTTPS.

Run static checks with `make check`.
