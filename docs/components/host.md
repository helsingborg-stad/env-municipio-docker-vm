# Host preparation

## Goal

Turn a fresh supported Ubuntu or Debian amd64 VM into a predictable Municipio node while keeping the host layer as small as possible.

## What the host actually runs

After the containerization refactor the host layer is:

| Layer | Provided by |
| --- | --- |
| Container runtime | Docker Engine + Compose plugin (apt, Docker's official repository) |
| Web server | `CADDY_IMAGE` container |
| Database | `MARIADB_IMAGE` container |
| Application | `MUNICIPIO_IMAGE` container |
| Replicated files (cluster only) | `glusterfs-server`/`glusterfs-client` packages |
| Galera arbitrator (arbiter host only) | `galera-arbitrator-4` package |
| Health evaluation | `municipio-health.timer` systemd timer |

A data VM installs no database server and no web server. The Caddy apt repository and its signing key are no longer configured at all.

The remaining host packages are `gzip`, `tar` and `util-linux` for backups and locking, plus `ca-certificates`, `curl` and `gnupg` for repository setup.

## Why GlusterFS and garbd stay on the host

Both are deliberate, documented exceptions rather than unfinished work.

GlusterFS is a kernel/FUSE storage layer, not an application service. The health check, the `DATA_ROOT` mount and `/etc/fstab` all operate on the host's mount table, and a containerized `glusterd` would need a privileged container with shared mount propagation. It belongs to the same layer as the filesystem itself. See [Replicated files](storage.md).

`garbd` is not part of the MariaDB image, and the arbitrator is a quorum-only witness host that stores no data. The installer gives it no Docker at all; adding a container runtime there to run one small daemon would enlarge the host it exists to keep minimal.

## Installation flow

The downloaded `installer.sh` fetches the source bundle and runs `bin/interactive-install.sh`. The wizard writes a temporary root-only dotenv file, validates it, then calls `bin/install.sh`. That lower-level installer runs six component installers in order: host, storage, database, maintenance, application, and proxy.

The host component installs packages, creates `/etc/municipio`, `/opt/municipio` and the backup directory, copies the effective configuration to `/etc/municipio/municipio.env` with mode `0600`, and installs the Compose project files. The Compose project has to exist before the database component can start MariaDB.

Standalone services are started before the wizard exits. Cluster services are prepared. The wizard then prints this server's name and address for the peers' installs, explains the activation order, and offers to activate only once the operator confirms the peers are ready.

## Supported platforms

The installer supports Ubuntu 22.04 (Jammy), 24.04 (Noble) and 26.04 (Resolute) LTS, plus Debian 12 (Bookworm) and 13 (Trixie), on amd64. It reads `/etc/os-release` and chooses the matching official Docker Engine repository.

Containerization narrowed what the OS release actually decides. MariaDB and Caddy versions now come from pinned image digests instead of the distribution, so two data VMs cannot end up with mismatched database builds. The distribution still provides GlusterFS, so cluster hosts should stay on the same release.

Set `INSTALL_PACKAGES=false` when a VM template or configuration-management system supplies the dependencies.

On a data VM the host component requires a Docker Engine systemd unit, enables and starts it, and verifies the daemon API before any Compose or Swarm command runs. A Docker CLI binary alone is not enough. If installation stops after the root-owned configuration has been saved, running the downloaded installer again offers to resume with that configuration.

This is an installer compatibility matrix, not a claim that every mode has passed VM-level acceptance tests on every release. Validate a full install on disposable VMs before production rollout.

References: [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/) and [Docker Engine on Debian](https://docs.docker.com/engine/install/debian/).

Installation requires root because it writes system configuration and manages systemd services and containers. Update, backup, failover and maintenance commands are root operations in the first version.
