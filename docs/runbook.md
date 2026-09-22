# Installation and operation runbook

## Before installation

- Use Ubuntu Server 24.04 LTS on amd64.
- Point DNS at the VM for standalone, or at the HTTP load balancer for a cluster.
- Permit ports 80/443 as appropriate.
- Between cluster hosts permit MariaDB/Galera and Gluster traffic, but never expose it publicly.
- When an upstream load balancer terminates TLS, set `CADDY_SITE_ADDRESS=:80`, preserve the public Host header, and send `X-Forwarded-Proto: https`.
- Automatic package installation configures the official Docker and Caddy apt repositories. If conflicting Ubuntu Docker packages are already installed, remove or migrate them deliberately before running the installer. Alternatively set `INSTALL_PACKAGES=false` and preinstall all dependencies.

The exact port matrix is documented in [Network boundaries](components/network.md). MariaDB port 3306 stays local; only Galera and Gluster replication ports cross between VMs.

## Local execution on the server

```bash
cp .env.example .env
sudo editor .env
sudo ./bin/install.sh --env-file "$PWD/.env"
sudo /scripts/status.municipio.sh
```

To use Docker Swarm execution, set `DOCKER_SWARM=1` before installation. The installer initializes an independent single-node Swarm on that VM. All operational commands remain the same.

The installer is intended to be rerunnable. Review configuration diffs before rerunning it on an established cluster.

## Execute through SSH

```bash
rsync -a --delete ./ deploy@server:/tmp/municipio-installer/
scp production.env deploy@server:/tmp/municipio.env
ssh deploy@server 'sudo /tmp/municipio-installer/bin/install.sh --env-file /tmp/municipio.env'
```

## Execute from CI

1. Render `municipio.env` from protected CI variables without printing it.
2. Copy the repository and env file to the target VM.
3. Run the same `install.sh` command over SSH.
4. Run `/scripts/status.municipio.sh` and request `/healthz`.
5. Delete the temporary env file; the installed copy remains under `/etc/municipio`.

## Initialize a two-node cluster

Run the installer on both data VMs first. Use the same shared settings and correct node-specific `NODE_NAME`/`NODE_ADDRESS`.

On the preferred node only:

```bash
sudo /scripts/cluster.municipio.sh bootstrap
```

On the secondary:

```bash
sudo /scripts/cluster.municipio.sh join
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

In a cluster, update one node at a time and confirm `/healthz` before moving to the next. After every node runs the same digest, drain both nodes briefly and run `cluster.municipio.sh clear-cache --all-nodes-drained` once before returning them to service. Cache behavior still needs validation before zero-downtime production rollout.

## Back up

```bash
sudo /scripts/backup.municipio.sh manual
```

Local backups alone do not protect against VM or storage loss. Copy them to an independent backup target and regularly test restoration.
