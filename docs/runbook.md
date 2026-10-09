# Installation and operation runbook

## Before installation

- Use Ubuntu Server 22.04, 24.04, or 26.04 LTS, or Debian 12 or 13, on amd64. Patch releases within those versions are accepted.
- Point DNS at the VM for standalone, or at the HTTP load balancer for a cluster.
- Permit ports 80/443 as appropriate.
- Between cluster hosts permit MariaDB/Galera and Gluster traffic, but never expose it publicly.
- For Caddy-managed TLS on both data VMs, route ports 80 and 443 to either healthy node; Caddy shares its certificates and ACME challenge state through Gluster. When an upstream load balancer terminates TLS, set `CADDY_SITE_ADDRESS=:80`, preserve the public Host header, and send `X-Forwarded-Proto: https`.
- Automatic package installation configures the official Docker repository for the detected distribution and codename. No database or web server package is installed: MariaDB and Caddy are digest-pinned container images. If conflicting Docker packages are already installed, remove or migrate them deliberately before running the installer. Alternatively set `INSTALL_PACKAGES=false` and preinstall all dependencies.
- The VM needs outbound access to the container registries for the application, MariaDB and Caddy images.

The exact port matrix is documented in [Network boundaries](components/network.md). MariaDB port 3306 stays local; only Galera and Gluster replication ports cross between VMs.

## Interactive installation on the server

```bash
curl -fL https://install.getmunicipio.com/installer.sh -o installer.sh
sudo sh installer.sh
sudo /scripts/status.municipio.sh
```

If custom-domain HTTPS is still provisioning, use the [GitHub HTTPS installer](https://raw.githubusercontent.com/helsingborg-stad/env-municipio-docker-vm/main/installer.sh) for the download.

The configuration holds a **database root password** in addition to the application database password. In standalone mode the wizard generates both. In cluster mode it derives both from the shared cluster password, which must be typed identically on both data VMs; see [Configuration](configuration.md#credentials).

Answer *yes* to the wizard's advanced settings and choose Docker Swarm to set `DOCKER_SWARM=1`. Standalone initializes a one-node Swarm. In a cluster, bootstrap initializes the preferred VM as manager and the secondary joins as a worker. Swarm manages the application only; MariaDB and Caddy stay per-VM Compose services. See [Swarm mode](components/swarm.md) for the join sequence.

If an earlier run saved `/etc/municipio/municipio.env` but did not finish, run the downloaded installer again and confirm the resume prompt. On a cluster server it then continues with the same next step a fresh installation offers: starting the cluster on website server 1, or connecting website server 2.

Running the installer on a server installed by an older version works the same way. When the saved file lacks settings the current installer writes, it lists them and, after confirmation, adds only those: path and other defaults are copied from `.env.example`, and the [ACME DNS-01](configuration.md#acme-dns-01) choice is asked on a data server whose Caddy manages TLS (an arbiter, or a server behind upstream TLS, gets `ACME_DNS_PROVIDER=none`). Existing values are never changed, except that choosing DNS-01 replaces `CADDY_IMAGE` with the installer's own Caddy image, which includes the DNS modules. The installer pulls it and checks for the provider's module first, and stops without changes if it is missing. The merged file is validated before anything is changed, the previous file is kept as `/etc/municipio/municipio.env.<timestamp>.bak`, and the installation then runs again. A running Galera node is left running. In a cluster, update both website servers with the same answers, because they share Caddy's certificate storage. Choosing DNS-01 recreates the Caddy container, so expect a short interruption on ports 80 and 443; update one server at a time. If the installation still fails after the settings were saved, restore the `.bak` file over `municipio.env` and run the installer again to be asked once more. The lower-level `bin/install.sh --env-file` remains available for carefully reviewed reconfiguration from a local checkout; it is not the normal installation path.

## Initialize a two-node cluster

Run the wizard on both data VMs first. Use the same OS release for both data VMs and the arbitrator; GlusterFS comes from the distribution. Choose the same number of servers and the same advanced settings, and enter identical shared settings, **including the cluster password and the WordPress password**. Use the correct node-specific name/address on each VM. The secondary should be prepared before bootstrapping the primary.

The primary waits up to 60 seconds for the secondary's Gluster service, and the secondary waits up to 60 seconds for the new Gluster volume to become mountable. You may therefore confirm the two wizard prompts close together; they no longer need manual timing. `bootstrap` and `join` are safe to run again after an interrupted setup: they accept an already connected peer, reuse the existing `municipio` volume and verify that it is started. If either wait expires, leave both installations in place, check `sudo systemctl status glusterd` and the cluster firewall on both VMs, then run the relevant command again. Do not create a Gluster volume manually on the secondary.

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

This step is required.

The bootstrapped node's database container runs with `--wsrep-new-cluster`. A container keeps that argument across restarts, so rebooting the node would form a second primary component. Once the secondary is in the cluster, run on the **primary**:

```bash
sudo /scripts/cluster.municipio.sh clear-bootstrap-flag
```

It refuses while `wsrep_cluster_size` is below 2, and verifies that the node returns to the Primary component afterwards. `status.municipio.sh` reports `galera_bootstrap=ACTIVE` until it succeeds.

Then validate from both:

```bash
sudo /scripts/monitor.municipio.sh
sudo /scripts/status.municipio.sh
curl -fsS https://www.example.se/healthz
```

For arbitrator mode, run the installer on the arbitrator host first with `NODE_ROLE=arbiter`. That host gets `galera-arbitrator-4` and GlusterFS as packages and no Docker at all, by design. Bootstrap the preferred data node, join the secondary, clear the bootstrap flag, and then run this on the arbitrator:

```bash
sudo /scripts/cluster.municipio.sh start-arbitrator
```

Verify `garb=active`, both Galera data nodes, and Gluster heal status before relying on automatic failover.

## Change the IP addresses of a two-node cluster

Gluster names its bricks by IP, and the Galera configuration of an initialized cluster is never regenerated, so a node does not follow an address change by itself. Once the provider has moved the addresses, run this on **both** data VMs, in either order:

```bash
sudo /scripts/change-ip.municipio.sh NEW_IP [PEER_NEW_IP]
```

`NEW_IP` is this server's new address and must already be configured on it. The other server's new address is asked for when `PEER_NEW_IP` is omitted. The script then stops the node and rewrites `municipio.env`, the Galera configuration, `/etc/fstab` and Gluster's metadata in `/var/lib/glusterd`, saving the previous files under `BACKUP_ROOT` first. The primary bootstraps Galera and serves again before the secondary is back. The secondary waits for the primary and joins it. The primary then waits for the secondary and clears the bootstrap flag.

Progress is saved in `/etc/municipio/ip-change.state`, and running the script again resumes where it stopped. If MariaDB on the primary is not in the Primary component when the script starts, for example after a reboot, it asks you to confirm that the secondary was never promoted before it bootstraps from the primary. A secondary with the Galera bootstrap flag set is refused; recover that as a [full-cluster outage](failover.md#full-cluster-outage). It supports `cluster-manual` with Compose and IPv4 only. Firewall rules, load balancers and DNS that use the old addresses are reported, not changed.

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
4. For `MARIADB_IMAGE`, recreate only the database container:
   ```bash
   sudo docker compose --env-file /etc/municipio/municipio.env \
     -f /opt/municipio/compose.yaml up -d --no-deps --force-recreate db
   ```
   For `CADDY_IMAGE`, run `sudo /scripts/refresh-sites.municipio.sh` instead. It checks the Gluster mount before Compose recreates Caddy.
5. Return to service: `sudo /scripts/maintenance.municipio.sh off`.

A MariaDB major-version change across a Galera cluster is a rolling-upgrade procedure, not a digest swap. Plan it separately.

## Back up

```bash
sudo /scripts/backup.municipio.sh manual
```

The archive includes uploads, cache, and Caddy certificate data. It records all three image references in `image.txt`, so a restore can reproduce the exact application, database and proxy versions. Protect backups as they contain TLS private keys.

Local backups alone do not protect against VM or storage loss. Copy them to an independent backup target and regularly test restoration.

## Add or change a WordPress hostname

Use the [site discovery guide](site-discovery.md). Change WordPress data and DNS/TLS separately; then run `sudo /scripts/refresh-sites.municipio.sh` on each data VM. The timer also polls for changes every minute. Check the generated host list and verify both nodes before sending round-robin traffic.
