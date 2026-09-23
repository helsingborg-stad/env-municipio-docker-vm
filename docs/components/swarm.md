# Docker Swarm execution mode

## Goal

Run one coordinated Municipio service across the data VMs with a single flag, while each task uses the MariaDB socket and file copy on its own VM.

## Enable it

```dotenv
DOCKER_SWARM=1
```

The default is `DOCKER_SWARM=0`, which uses Docker Compose. `DEPLOYMENT_MODE=standalone` creates a one-node Swarm; a cluster mode creates one Swarm across both data VMs.

## Swarm manages the application only

`compose.swarm.yaml` contains exactly one service: the application. MariaDB and Caddy are always per-VM Compose services from `compose.yaml`, in both runtime modes.

That is the same split the host-installed design had, where MariaDB and Caddy were per-VM systemd services and Swarm managed only the application. Both own node-local state — a data directory, a socket, ACME certificates, ports 80/443 — that must never be rescheduled onto another VM. `tests/check.sh` asserts that no `db` or `caddy` service appears in `compose.swarm.yaml`.

## Topology

The preferred data VM is the Swarm manager. The second data VM joins as a worker. The service has `mode: global` and a `municipio.data=true` node constraint, so it starts exactly one task on each enabled data VM. The optional Galera/Gluster arbitrator is outside the Swarm.

The service publishes its port in host mode. Caddy on each VM reaches its **local** task at `127.0.0.1:8080`. Swarm's routing mesh is not used, because it could route a request to another VM's task while the local database and filesystem are unavailable. Because the Caddy container shares the host network namespace, that loopback address means the same thing to it as it did to a host-installed Caddy.

The manager controls image updates for both nodes. Swarm replaces tasks one at a time with `stop-first` and rolls back a failed service update. The local `/healthz` endpoint continues to evaluate the application, local MariaDB, and local storage together. The external HTTP round-robin service checks that endpoint.

## Joining a second VM

Install both VMs and bootstrap the preferred data VM. On the manager, display the worker token:

```bash
sudo docker swarm join-token -q worker
```

On the secondary VM, enter that token when prompted (input is hidden):

```bash
sudo /scripts/cluster.municipio.sh join --token-stdin
```

After the secondary has joined Galera and mounted its Gluster view, enable its Swarm task on the manager:

```bash
sudo /scripts/cluster.municipio.sh enable-node SECONDARY_HOSTNAME
```

Use the hostname shown by `docker node ls`. The secondary must have its local Galera and Gluster state ready before joining; `enable-node` verifies that the ready worker has the configured secondary address before labeling it. Run `status.municipio.sh` on both VMs and confirm that each local `/healthz` returns 200.

Then clear the primary's Galera bootstrap flag:

```bash
# On the primary VM, once the secondary is in the cluster:
sudo /scripts/cluster.municipio.sh clear-bootstrap-flag
```

## Control-plane failure

The two-node Swarm has one manager and one worker. If the manager VM fails, a task already running on the worker can continue serving traffic if its local Galera and Gluster state is writable. Service deployment, rolling updates, and scheduling changes are unavailable until the manager recovers or an operator establishes a new manager. The optional database/storage arbitrator does not vote in Swarm manager elections.

Because MariaDB and Caddy are Compose services, they keep running on the surviving VM regardless of Swarm's control-plane state, and `docker compose` on that VM can still restart them.

This is a limit of the two-VM topology. Automatic Swarm manager failover would require a third Swarm manager. Swarm does not replace Galera or Gluster failover: it can manage application tasks, but it cannot make a VM's local database or files writable after quorum loss.

## Network and local ownership

Swarm host-mode publishing does not bind the application port to loopback. `municipio-swarm-firewall.service` adds persistent INPUT and DOCKER-USER rules that reject non-loopback traffic to the published port. Caddy continues to use loopback.

The local bind mounts and the MariaDB socket directory must exist on **each** data VM before it receives the `municipio.data=true` label. The configuration values supplied to `docker stack deploy` on the manager apply to every task, so `SITE_ADDRESS`, database credentials, mount paths, and app port must match across both data VMs.

Changing an existing VM from Compose to Swarm is a migration operation. Remove the old Compose application after a backup and before enabling the Swarm task to avoid a port conflict. The database and proxy containers are unaffected by that switch.
