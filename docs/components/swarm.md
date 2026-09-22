# Docker Swarm execution mode

## Goal

Allow the same VM design to run the Municipio container as a Docker Swarm service with one configuration flag.

## Enable it

```dotenv
DOCKER_SWARM=1
```

The default is `DOCKER_SWARM=0`, which uses Docker Compose.

## Deliberate scope

Every VM creates its own independent single-node Swarm. A two-VM Municipio cluster therefore consists of two single-node Swarms plus Galera and Gluster replication. The VMs are not joined into one shared Swarm scheduler.

This preserves the core ownership rule: the task on a VM uses that VM's MariaDB Unix socket and local replicated filesystem. An external HTTP round-robin service still distributes requests between VMs.

The installer refuses Swarm mode when the local engine is a worker or belongs to a Swarm with more than one node.

## Deployment behavior

`compose.swarm.yaml` deploys exactly one task constrained to the local hostname. Updates use `docker stack deploy`, stop-first replacement, health monitoring, and Swarm's rollback action. Existing `/scripts` commands select Compose or Swarm from the same flag.

Swarm cannot bind a service's host-published port specifically to `127.0.0.1`. The service therefore publishes the application port in host mode, and `municipio-swarm-firewall.service` inserts a `DOCKER-USER` rule that rejects non-loopback traffic to that port. Caddy continues to connect to `127.0.0.1:8080`.

Changing an existing VM between Compose and Swarm is a migration operation, not a routine configuration toggle. Stop and remove the existing Compose project or Swarm stack before changing the flag.

