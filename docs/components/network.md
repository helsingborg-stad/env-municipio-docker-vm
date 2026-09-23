# Network boundaries

## Goal

Expose only web traffic publicly and restrict all replication to the cluster network.

## Solution

| Port | Protocol | Source | Purpose |
| --- | --- | --- | --- |
| 22 | TCP | Administration networks | Optional remote administration. The installer itself runs on the VM. |
| 80, 443 | TCP | Public or upstream HTTP load balancer | Caddy. |
| 8080 | TCP | Loopback only | Caddy to local Municipio container. |
| 3306 | TCP/socket | Loopback and local Unix socket only | Local MariaDB client traffic. |
| 4567 | TCP/UDP | Galera members and arbitrator | Galera replication. |
| 4568 | TCP | Data nodes | Galera incremental state transfer. |
| 4444 | TCP | Data nodes | Galera snapshot state transfer. |
| 24007-24008 | TCP | Gluster members | Gluster management. |
| 49152-49251 | TCP | Gluster members | Gluster brick traffic. Narrow after confirming assigned brick ports. |

Cluster ports must be filtered to the exact node addresses. MariaDB port 3306 is not used between nodes; Galera has its own replication ports.

Docker publishes the application port explicitly on `127.0.0.1`. Docker's official documentation notes that published container ports can bypass some UFW rules, so public exposure must not rely only on a deny rule: the loopback bind is part of the security boundary.

In Swarm mode, Docker does not support binding the service's host-mode published port to a specific host address. The installed `municipio-swarm-firewall.service` therefore enforces loopback-only access in the INPUT and DOCKER-USER chains.

The data VMs also need Swarm management traffic: TCP 2377 to the manager, and TCP/UDP 7946 plus UDP 4789 between Swarm members. Restrict these ports to the data VM addresses.
