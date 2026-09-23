# Network boundaries

## Goal

Expose only web traffic publicly and restrict all replication to the cluster network.

## Solution

| Port | Protocol | Source | Purpose |
| --- | --- | --- | --- |
| 22 | TCP | Administration networks | Optional remote administration. The installer itself runs on the VM. |
| 80, 443 | TCP | Public or upstream HTTP load balancer | Caddy container (host network namespace). |
| 8080 | TCP | Loopback only | Caddy to local Municipio container. |
| 3306 | TCP/socket | Loopback and local Unix socket only | Local MariaDB client traffic. |
| 4567 | TCP/UDP | Galera members and arbitrator | Galera replication. |
| 4568 | TCP | Data nodes | Galera incremental state transfer. |
| 4444 | TCP | Data nodes | Galera snapshot state transfer. |
| 24007-24008 | TCP | Gluster members | Gluster management. |
| 49152-49251 | TCP | Gluster members | Gluster brick traffic. Narrow after confirming assigned brick ports. |

This table is unchanged by containerization, and that was a design goal rather than a coincidence.

## Why the database moved into a container without changing the matrix

The MariaDB and Caddy containers share the host network namespace. MariaDB keeps `bind-address=127.0.0.1`, so port 3306 is still bound to loopback and is still not used between nodes — Galera has its own replication ports. Galera advertises and binds the node's real address exactly as a host-installed server did, so cross-VM replication and state transfer need no NAT-aware provider options and the firewall policy is the same policy.

The application reaches the database through the shared Unix socket, not over TCP. It is on a private Docker bridge network that the database container is not attached to, so there is no network path from the application to the database to firewall in the first place.

Cluster ports must be filtered to the exact node addresses.

## Application port

Docker publishes the application port explicitly on `127.0.0.1`. Docker's official documentation notes that published container ports can bypass some UFW rules, so public exposure must not rely only on a deny rule: the loopback bind is part of the security boundary.

In Swarm mode, Docker does not support binding the service's host-mode published port to a specific host address. The installed `municipio-swarm-firewall.service` therefore enforces loopback-only access in the INPUT and DOCKER-USER chains. Because Caddy shares the host network namespace, it reaches the application over loopback in both runtime modes and that rule needs no exception.

## Swarm

The data VMs also need Swarm management traffic: TCP 2377 to the manager, and TCP/UDP 7946 plus UDP 4789 between Swarm members. Restrict these ports to the data VM addresses.
