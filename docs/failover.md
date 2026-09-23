# Failover mechanisms

## Standalone

There is no automatic failover. Restore the VM, create a replacement VM, or restore the latest database and file archive. This is the default and must remain usable without any cluster variables.

## Manual two-node cluster

Normal state: both nodes serve HTTP and write to their local synchronized state.

Secondary failure: the preferred node retains quorum and continues. Repair and rejoin the secondary.

Preferred-node failure: the secondary loses writable quorum and `/healthz` disappears. Confirm that the preferred node is powered off or isolated from both client and replication networks, then run:

```bash
sudo /scripts/failover.municipio.sh promote --fence-confirmed
```

This is deliberately not automatic.

Promotion recreates the local database container with `--wsrep-new-cluster` and sets the Galera bootstrap marker. Because a container keeps that argument across restarts, the promoted node would form another primary component if it rebooted. `status.municipio.sh` reports `galera_bootstrap=ACTIVE` until the flag is cleared.

Before returning the former node, start it as a joiner and verify Galera state transfer and Gluster healing. Then:

```bash
# Restore filesystem quorum:
sudo /scripts/cluster.municipio.sh restore-quorum
# Once the peer is back in the cluster, on the promoted node:
sudo /scripts/cluster.municipio.sh clear-bootstrap-flag
```

`clear-bootstrap-flag` refuses while `wsrep_cluster_size` is below 2 and verifies the Primary component afterwards. Treat a node that still has the marker as not yet fully recovered, even if the site is serving traffic.

With `DOCKER_SWARM=1`, the preferred node is also the sole Swarm manager. The secondary's existing application task can resume serving after manual storage/database promotion, but Swarm updates and scheduling remain unavailable until the manager is recovered or explicitly replaced. The secondary's MariaDB and Caddy containers are Compose-managed and are unaffected by the manager's absence.

## Cluster with arbitrator

Loss of either data VM leaves one data vote plus the independent arbitrator vote. Galera and Gluster retain safe quorum, and the HTTP round-robin layer removes only the failed node. No bootstrap flag is involved, because no node has to be promoted by hand.

Loss of the arbitrator alone leaves both data nodes operating, but the deployment temporarily has manual two-node failure characteristics. Restore the arbitrator before planned maintenance of a data VM.

## Full-cluster outage

Do not guess which node is newest. Compare Galera recovery positions and Gluster heal state, select one authoritative node, fence all others, bootstrap once, and only then join the other nodes. Clear the bootstrap flag once the other nodes have rejoined. The first version does not automate this destructive decision.
