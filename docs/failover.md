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

This is deliberately not automatic. Before returning the former node, start it as a joiner and verify Galera state transfer and Gluster healing. Then restore normal filesystem quorum with `cluster.municipio.sh restore-quorum` and re-enable HTTP health.

## Cluster with arbitrator

Loss of either data VM leaves one data vote plus the independent arbitrator vote. Galera and Gluster retain safe quorum, and the HTTP round-robin layer removes only the failed node.

Loss of the arbitrator alone leaves both data nodes operating, but the deployment temporarily has manual two-node failure characteristics. Restore the arbitrator before planned maintenance of a data VM.

## Full-cluster outage

Do not guess which node is newest. Compare Galera recovery positions and Gluster heal state, select one authoritative node, fence all others, bootstrap once, and only then join the other nodes. The first version does not automate this destructive decision.
