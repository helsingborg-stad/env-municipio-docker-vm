# Installation and operation runbook

## Before installation

- Use Ubuntu Server 22.04, 24.04, or 26.04 LTS, or Debian 12 or 13, on amd64. Patch releases within those versions are accepted.
- Point DNS at the VM for standalone, or at the HTTP load balancer for a cluster.
- Permit ports 80/443 as appropriate.
- Between cluster hosts permit MariaDB/Galera and Gluster traffic, but never expose it publicly.
- When an upstream load balancer terminates TLS, set `CADDY_SITE_ADDRESS=:80`, preserve the public Host header, and send `X-Forwarded-Proto: https`.
- Automatic package installation configures the official Docker repository for the detected distribution and codename. No database or web server package is installed: MariaDB and Caddy are digest-pinned container images. If conflicting Docker packages are already installed, remove or migrate them deliberately before running the installer. Alternatively set `INSTALL_PACKAGES=false` and preinstall all dependencies.
- The VM needs outbound access to the container registries for the application, MariaDB and Caddy images.

The exact port matrix is documented in [Network boundaries](components/network.md) and is unchanged by containerization. MariaDB port 3306 stays local; only Galera and Gluster replication ports cross between VMs.

## Interactive installation on the server

```bash
curl -fL https://raw.githubusercontent.com/helsingborg-stad/env-municipio-docker-vm/main/installer.sh -o installer.sh
sudo sh installer.sh
sudo /scripts/status.municipio.sh
```

The configuration holds a **database root password** in addition to the application database password. In standalone mode the wizard generates both. In cluster mode it derives both from the shared cluster password, which must be typed identically on both data VMs; see [Configuration](configuration.md#credentials).

Answer *yes* to the wizard's advanced settings and choose Docker Swarm to set `DOCKER_SWARM=1`. Standalone initializes a one-node Swarm. In a cluster, bootstrap initializes the preferred VM as manager and the secondary joins as a worker. Swarm manages the application only; MariaDB and Caddy stay per-VM Compose services. See [Swarm mode](components/swarm.md) for the join sequence.

If an earlier run saved `/etc/municipio/municipio.env` but did not finish, run the downloaded installer again and confirm the resume prompt. On a cluster server it then continues with the same next step a fresh installation offers: starting the cluster on website server 1, or connecting website server 2. The lower-level `bin/install.sh --env-file` remains available for carefully reviewed reconfiguration from a local checkout; it is not the normal installation path.

## Migrating a host-installed node

There is no in-place conversion from the previous host-installed layout. Migrate with a backup and a fresh install:

1. On the existing node, take a backup and copy it off the VM:
   ```bash
   sudo /scripts/backup.municipio.sh pre-containerization
   ```
2. Install the containerized version on a fresh VM, or reinstall the node after removing the old `mariadb-server` and `caddy` packages.
3. Restore the archive. There is no `mariadb` client on the host any more, so the dump
   goes in through the database container:
   ```bash
   sudo /scripts/maintenance.municipio.sh on
   # shellcheck disable=SC2154
   DB_ROOT_PASSWORD="$(sudo sed -n "s/^DB_ROOT_PASSWORD='\(.*\)'$/\1/p" /etc/municipio/municipio.env)"
   zcat database.sql.gz | sudo docker exec -i -e MYSQL_PWD="$DB_ROOT_PASSWORD" \
     municipio-db mariadb -uroot municipio
   sudo tar -C /srv/municipio/data -xzf files.tar.gz
   sudo /scripts/maintenance.municipio.sh off
   ```
   Use the database name from `DB_NAME` if it is not the default.

Do not point `DB_DATA_ROOT` at the old `/var/lib/mysql`. The image version is pinned by digest and may differ from the distribution package the directory was written by.

## Initialize a two-node cluster

Run the wizard on both data VMs first. Use the same OS release for both data VMs and the arbitrator; the database and web server versions now come from pinned image digests, but GlusterFS still comes from the distribution. Choose the same number of servers and the same advanced settings, and enter identical shared settings, **including the cluster password and the WordPress password**. Use the correct node-specific name/address on each VM. The secondary should be prepared before bootstrapping the primary.

On the preferred node only:

```bash
sudo /scripts/cluster.municipio.sh bootstrap
```

On the secondary with Compose:

```bash
sudo /scripts/cluster.municipio.sh join
```

With Swarm, display the token on the primary manager, enter it on the secondary, then enable its task on the manager:

```bash
# On the primary VM:
sudo docker swarm join-token -q worker
# On the secondary VM (paste the token when prompted):
sudo /scripts/cluster.municipio.sh join --token-stdin
# Back on the primary VM:
sudo /scripts/cluster.municipio.sh enable-node SECONDARY_HOSTNAME
```

### Then clear the bootstrap flag

This step is new and is not optional.

The bootstrapped node's database container runs with `--wsrep-new-cluster`. Unlike the distribution's one-shot `galera_new_cluster` helper, a container keeps that argument across restarts, so rebooting the node would form a second primary component. Once the secondary is in the cluster, run on the **primary**:

```bash
sudo /scripts/cluster.municipio.sh clear-bootstrap-flag
```

It refuses while `wsrep_cluster_size` is below 2, and verifies that the node returns to the Primary component afterwards. `status.municipio.sh` reports `galera_bootstrap=ACTIVE` until it succeeds.

Then validate from both:

```bash
sudo /scripts/status.municipio.sh
curl -fsS https://www.example.se/healthz
```

For arbitrator mode, run the installer on the arbitrator host first with `NODE_ROLE=arbiter`. That host gets `galera-arbitrator-4` and GlusterFS as packages and no Docker at all, by design. Bootstrap the preferred data node, join the secondary, clear the bootstrap flag, and then run this on the arbitrator:

```bash
sudo /scripts/cluster.municipio.sh start-arbitrator
```

Verify `garb=active`, both Galera data nodes, and Gluster heal status before relying on automatic failover.

## Update the application on one node

```bash
sudo /scripts/update.municipio.sh \
  ghcr.io/municipio-se/municipio-deployment-docker@sha256:<new-digest>
```

With Compose, update one node at a time. With Swarm, run the command **once on the manager**; the global service rolls tasks across both data VMs. Application updates never recreate the database container. After every node runs the same digest, drain both nodes briefly and run `cluster.municipio.sh clear-cache --all-nodes-drained` once before returning them to service.

## Update the MariaDB or Caddy image

Deliberately not automated, and deliberately not part of an application update.

1. Take a backup and copy it off the VM.
2. Put the node into maintenance: `sudo /scripts/maintenance.municipio.sh on`.
3. Edit `MARIADB_IMAGE` or `CADDY_IMAGE` in `/etc/municipio/municipio.env` (single-quoted, digest-pinned).
4. Recreate only that service:
   ```bash
   sudo docker compose --env-file /etc/municipio/municipio.env \
     -f /opt/municipio/compose.yaml up -d --no-deps --force-recreate db
   ```
5. Return to service: `sudo /scripts/maintenance.municipio.sh off`.

A MariaDB major-version change across a Galera cluster is a rolling-upgrade procedure, not a digest swap. Plan it separately.

## Back up

```bash
sudo /scripts/backup.municipio.sh manual
```

The archive records all three image references in `image.txt`, so a restore can reproduce the exact application, database and proxy versions.

Local backups alone do not protect against VM or storage loss. Copy them to an independent backup target and regularly test restoration.
