# Host preparation

## Goal

Turn a fresh Ubuntu Server 24.04 LTS amd64 VM into a predictable Municipio node while keeping the host layer small and inspectable.

## Solution

The downloaded `installer.sh` fetches the source bundle and runs `bin/interactive-install.sh`. The wizard writes a temporary root-only dotenv file, validates it, then calls `bin/install.sh`. That lower-level installer runs six independent component installers in order: host, storage, database, maintenance, application, and proxy. Standalone services are started before the wizard exits. Cluster services are prepared, then the wizard offers activation only when peers are ready.

The host component installs required packages, creates `/etc/municipio`, `/opt/municipio`, and the backup directory, and copies the effective configuration to `/etc/municipio/municipio.env` with mode `0600`.

The installer configures the official Docker Engine and Caddy apt repositories when their commands are absent. It installs Docker CE with the Compose plugin, Caddy, MariaDB 10.11 from Ubuntu Noble, and cluster packages when requested. It refuses to remove conflicting Docker packages automatically. Set `INSTALL_PACKAGES=false` when a VM template or configuration-management system supplies all dependencies.

References: [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/) and [Caddy packages for Ubuntu](https://caddyserver.com/docs/install#debian-ubuntu-raspbian).

Installation requires root because it writes system configuration and manages systemd services. Day-to-day read operations can be delegated separately, but update, backup, failover, and maintenance commands are root operations in the first version.
