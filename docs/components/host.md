# Host preparation

## Goal

Turn a fresh supported Ubuntu or Debian amd64 VM into a predictable Municipio node while keeping the host layer small and inspectable.

## Solution

The downloaded `installer.sh` fetches the source bundle and runs `bin/interactive-install.sh`. The wizard writes a temporary root-only dotenv file, validates it, then calls `bin/install.sh`. That lower-level installer runs six independent component installers in order: host, storage, database, maintenance, application, and proxy. Standalone services are started before the wizard exits. Cluster services are prepared, then the wizard offers activation only when peers are ready.

The host component installs required packages, creates `/etc/municipio`, `/opt/municipio`, and the backup directory, and copies the effective configuration to `/etc/municipio/municipio.env` with mode `0600`.
With the default `INSTALL_PACKAGES=true`, the host installer automatically installs the small `idn2` and `psl` command-line packages on every data VM. They generate safe IDN and apex-domain Caddy routes; no Python runtime is required by site discovery. If package installation is disabled, both commands must already be present or installation stops with an error.

The installer supports Ubuntu 22.04 (Jammy), 24.04 (Noble), and 26.04 (Resolute) LTS, plus Debian 12 (Bookworm) and 13 (Trixie), on amd64. It reads `/etc/os-release` and chooses the matching official Docker Engine repository instead of a hardcoded Ubuntu suite. Caddy uses its Debian/Ubuntu apt repository. The distribution provides MariaDB and cluster packages, so their versions vary by OS release. The installer refuses to remove conflicting Docker packages automatically. Set `INSTALL_PACKAGES=false` when a VM template or configuration-management system supplies all dependencies.

On a data VM, the host component requires a Docker Engine systemd unit, enables and starts it, and verifies the daemon API before any Compose or Swarm command runs. A Docker CLI binary alone is not enough. If installation stops after the root-owned configuration has been saved, running the downloaded installer again offers to resume with that configuration.

This is an installer compatibility matrix, not a claim that every mode has passed VM-level acceptance tests on every release. Validate package availability and a full install on disposable VMs before production rollout.

References: [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/), [Docker Engine on Debian](https://docs.docker.com/engine/install/debian/), and [Caddy packages for Debian/Ubuntu](https://caddyserver.com/docs/install#debian-ubuntu-raspbian).

Installation requires root because it writes system configuration and manages systemd services. Day-to-day read operations can be delegated separately, but update, backup, failover, and maintenance commands are root operations in the first version.
