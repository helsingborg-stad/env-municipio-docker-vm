# Failover mechanisms

## Standalone

There is no automatic failover. Restore the VM, create a replacement VM, or restore the latest database and file archive. This is the default and must remain usable without any cluster variables.

## Manual two-node cluster

Normal state: both nodes serve HTTP and write to their local synchronized state.

### What happens when one server disappears

The two-node manual topology intentionally does **not** promote itself. It cannot know whether a missing server is powered off or merely partitioned, and allowing both sides to write would create split-brain data.

- If the secondary fails, the preferred (primary) node retains quorum and continues serving read/write traffic. Do not detach the failed peer or change Gluster quorum; repair the secondary and use the [rejoin procedure](#reattach-a-returning-server) below.
- If the preferred (primary) node fails, the secondary deliberately loses writable Gluster quorum and the local health endpoint disappears. It will not serve writes until an operator fences the old primary and promotes the secondary.

Do **not** use `gluster peer detach` as a failover mechanism. It only changes Gluster peer metadata; it does not make Galera safe to write and can make recovery harder. The promotion command below is the supported logical detach: it fences the failed side operationally, establishes one Galera primary component, and explicitly permits the surviving Gluster brick to accept writes.

### Detach a surviving server from a dead replica and restore writes

Use this only when the preferred node is genuinely unavailable and the secondary must take over.

1. Fence the failed primary: power it off, or block it from **both** client traffic and all cluster/replication networks. Do not proceed merely because it stopped responding to one check.
2. On the surviving secondary, verify that it is the only server you will allow to write, then run:

```bash
sudo /scripts/failover.municipio.sh promote --fence-confirmed
```

3. Verify that the secondary serves traffic and is writable:

```bash
sudo /scripts/status.municipio.sh
curl -fsS https://YOUR-SITE/healthz
```

This is deliberately not automatic. Promotion puts the node into maintenance briefly, recreates MariaDB with `--wsrep-new-cluster`, records the Galera bootstrap marker, changes Gluster quorum to `none`, remounts the local volume read/write, and then returns the node to service. The former primary must remain fenced throughout this period.

Because the promoted database container keeps `--wsrep-new-cluster` across restarts, rebooting it before recovery would form another primary component. `status.municipio.sh` reports `galera_bootstrap=ACTIVE` until the marker is cleared at the end of reattachment.

### Reattach a returning server and restore the cluster

Do not start the former primary as an independent primary. Keep the promoted node running and perform these steps in order.

1. Restore the former primary's network and start Gluster on it:

```bash
sudo systemctl enable --now glusterd
```

2. On the former primary, start it as a joiner:

```bash
sudo /scripts/cluster.municipio.sh join
```

The join command contacts the live peer, remounts Gluster, then starts MariaDB normally. Galera performs an incremental or full state transfer as needed; it must not be bootstrapped manually.

3. On both nodes, confirm that Gluster peers and bricks are connected, the Galera cluster contains two nodes, and healing has completed:

```bash
sudo /scripts/status.municipio.sh
sudo gluster volume heal municipio info summary
```

Resolve any reported split-brain before continuing. A nonzero healing count immediately after rejoin is normal; it must trend to zero.

4. On the currently promoted node only, restore normal filesystem quorum and remove the temporary Galera bootstrap behavior:

```bash
# Restore filesystem quorum:
sudo /scripts/cluster.municipio.sh restore-quorum
# Once status shows the peer is back in the cluster, on the promoted node:
sudo /scripts/cluster.municipio.sh clear-bootstrap-flag
```

`clear-bootstrap-flag` refuses while `wsrep_cluster_size` is below 2 and verifies the Primary component afterwards. Treat a node that still has the marker as not yet fully recovered, even if the site is serving traffic. At this point both servers have resumed normal replicated operation; the original preferred-primary designation remains configuration metadata and does not require another promotion.

With `DOCKER_SWARM=1`, the preferred node is also the sole Swarm manager. The secondary's existing application task can resume serving after manual storage/database promotion, but Swarm updates and scheduling remain unavailable until the manager is recovered or explicitly replaced. The secondary's MariaDB and Caddy containers are Compose-managed and are unaffected by the manager's absence.

## Cluster with arbitrator

Loss of either data VM leaves one data vote plus the independent arbitrator vote. Galera and Gluster retain safe quorum, and the HTTP round-robin layer removes only the failed node. No bootstrap flag is involved, because no node has to be promoted by hand.

Loss of the arbitrator alone leaves both data nodes operating, but the deployment temporarily has manual two-node failure characteristics. Restore the arbitrator before planned maintenance of a data VM.

## Full-cluster outage

Do not guess which node is newest. Compare Galera recovery positions and Gluster heal state, select one authoritative node, fence all others, bootstrap once, and only then join the other nodes. Clear the bootstrap flag once the other nodes have rejoined. The first version does not automate this destructive decision.
