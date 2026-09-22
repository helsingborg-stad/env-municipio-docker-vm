# MariaDB and Galera

## Goal

Give every data VM its own MariaDB server and local application connection while optionally keeping two servers synchronized.

## Standalone solution

MariaDB runs as a native systemd service. Installation creates the application database and user. The bridged Docker container uses the host's Unix socket, mounted read-only into the container, so MariaDB client port 3306 remains bound to localhost.

## Cluster solution

Both data VMs run MariaDB with Galera. Municipio always talks to the MariaDB on the same VM. Galera replicates committed transactions between the two servers.

In `cluster-manual`, the preferred node has quorum weight 2 and the other weight 1. Loss of the secondary leaves the preferred node writable. Loss of the preferred node requires fencing and manual promotion.

In `cluster-arbitrator`, both data nodes have equal weight and `garbd` supplies a third vote. A remaining data node plus the arbitrator retains quorum automatically.

On Ubuntu 24.04 the arbitrator uses the `galera-arbitrator-4` package and `/etc/default/garb`. Installation prepares it stopped; `cluster.municipio.sh start-arbitrator` starts it only after the data cluster exists.

After bootstrap or join, `/etc/municipio/cluster-initialized` marks the VM as a live cluster member. A later installer run refuses to replace changed Galera configuration on that node; such changes require an explicit rolling maintenance procedure.

## Forbidden operations

- Never rsync `/var/lib/mysql`.
- Never bootstrap both nodes.
- Never promote a node until the former writable node is fenced.
- Never restore a database dump into a live multi-node cluster without following a restore procedure.
