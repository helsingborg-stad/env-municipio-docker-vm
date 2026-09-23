# Installation and operation runbook

## Before installation

- Use Ubuntu Server 22.04, 24.04, or 26.04 LTS, or Debian 12 or 13, on amd64. Patch releases within those versions are accepted.
- Point DNS at the VM for standalone, or at the HTTP load balancer for a cluster.
- Permit ports 80/443 as appropriate.
- Between cluster hosts permit MariaDB/Galera and Gluster traffic, but never expose it publicly.
- When an upstream load balancer terminates TLS, set `CADDY_SITE_ADDRESS=:80`, preserve the public Host header, and send `X-Forwarded-Proto: https`.
- Automatic package installation configures the official Docker repository for the detected distribution and codename, plus Caddy's Debian/Ubuntu apt repository. If conflicting Docker packages are already installed, remove or migrate them deliberately before running the installer. Alternatively set `INSTALL_PACKAGES=false` and preinstall all dependencies.

The exact port matrix is documented in [Network boundaries](components/network.md). MariaDB port 3306 stays local; only Galera and Gluster replication ports cross between VMs.

## Interactive installation on the server

```bash
curl -fL https://raw.githubusercontent.com/helsingborg-stad/env-municipio-docker-vm/main/installer.sh -o installer.sh
sudo sh installer.sh
sudo /scripts/status.municipio.sh
```

Choose `swarm` in the wizard to set `DOCKER_SWARM=1`. Standalone initializes a one-node Swarm. In a cluster, bootstrap initializes the preferred VM as manager and the secondary joins as a worker. See [Swarm mode](components/swarm.md) for the join sequence.

If an earlier run saved `/etc/municipio/municipio.env` but did not finish, run the downloaded installer again and confirm the resume prompt. It reuses the existing configuration without asking for credentials again. The lower-level `bin/install.sh --env-file` remains available for carefully reviewed reconfiguration from a local checkout; it is not the normal installation path.

## Initialize a two-node cluster

Run the wizard on both data VMs first. Use the same OS release and package versions for both data VMs and the arbitrator; mixing distro releases can produce incompatible MariaDB, Galera, or Gluster versions. Choose the same deployment and runtime modes and enter identical shared settings. The first VM remains prepared rather than serving until the peer is ready; cluster creation requires explicit coordination. Use the correct node-specific name/address on each VM. The secondary should be prepared before bootstrapping the primary. The wizard offers bootstrap or join after installation; choose **no** until the peer is ready, then use the local commands below. For Swarm, the secondary's join needs the worker token from the primary manager, and the manager must then enable the worker task.

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

Then validate from both:

```bash
sudo /scripts/status.municipio.sh
curl -fsS https://www.example.se/healthz
```

For arbitrator mode, run the installer on the arbitrator host first with `NODE_ROLE=arbiter`; this starts Gluster but prepares `garbd` without starting it. Bootstrap the preferred data node, join the secondary, and then run this on the arbitrator:

```bash
sudo /scripts/cluster.municipio.sh start-arbitrator
```

Verify `garb=active`, both Galera data nodes, and Gluster heal status before relying on automatic failover.

## Update one node

```bash
sudo /scripts/update.municipio.sh \
  ghcr.io/municipio-se/municipio-deployment-docker@sha256:<new-digest>
```

With Compose, update one node at a time. With Swarm, run the update **once on the manager**; the global service rolls tasks across both data VMs. After every node runs the same digest, drain both nodes briefly and run `cluster.municipio.sh clear-cache --all-nodes-drained` once before returning them to service. Cache behavior still needs validation before zero-downtime production rollout.

## Back up

```bash
sudo /scripts/backup.municipio.sh manual
```

Local backups alone do not protect against VM or storage loss. Copy them to an independent backup target and regularly test restoration.
