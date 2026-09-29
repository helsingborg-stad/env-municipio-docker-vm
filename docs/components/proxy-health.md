# Caddy and health

## Goal

Expose only healthy, fully usable nodes to an HTTP round-robin service, without installing a web server on the host.

## Containerized Caddy

Caddy runs from `CADDY_IMAGE`, digest-pinned. The Caddy apt repository, its signing key and the `caddy` system user are all gone from the host.

Like the database container it uses the host network namespace, so it owns ports 80/443 on the VM directly, sees real client addresses, and reaches the local application at the same loopback address in both Compose and Swarm mode.

| Mount | Purpose |
| --- | --- |
| `CONFIG_ROOT/caddy` → `/etc/caddy` (read-only) | The generated `Caddyfile` and site fragment. |
| `HEALTH_ROOT` → `/var/lib/municipio/health` (read-only) | The health marker `/healthz` is served from. |
| `DATA_ROOT/caddy` → `/data` | Shared certificate, account, lock, and challenge storage. |
| `caddy_config` volume → `/config` | Caddy's autosaved configuration. |

Caddy uses the explicit filesystem storage root `/data/caddy`. In standalone mode this is on local disk; in cluster modes it is on the Gluster volume, visible to both Caddy instances. The Caddy container has no Docker restart policy: `municipio-caddy.service` starts it after the data mount is ready. The refresh command also checks the Gluster filesystem and read/write state before starting or reloading Caddy. Losing this directory discards certificates and forces reissue, so backups include it.

The **directory** is mounted rather than the `Caddyfile` itself. Replacing a bind-mounted single file swaps its inode and silently detaches the mount, which would only show up on the second configuration change.

## Configuration changes

`refresh-sites.municipio.sh` discovers WordPress hostnames and writes a candidate `Caddyfile` and `municipio-sites.caddy` fragment to a staging directory. It validates them with the pinned Caddy image before installing them. See [WordPress site discovery](../site-discovery.md).

If either file changed and the container is already running, the refresh command issues `caddy reload`, which re-reads the bind-mounted directory. Otherwise it starts the container.

## Health

`/healthz` is served from a marker file maintained by `municipio-health.timer` every ten seconds.

The marker exists only when:

- maintenance mode is off;
- the local application container is running and responds over HTTP;
- local MariaDB answers a ping inside its container, and its socket is present on the host;
- in cluster mode, Galera is ready and in the Primary component;
- in cluster mode, the replicated data path is mounted read/write.

## Why health stays on the host

The health check deliberately remains a host systemd timer rather than a sidecar container. Its cluster checks — `mountpoint` and `findmnt` against `DATA_ROOT` — are facts about the **host's** mount table. Inside a container, `findmnt --target` reports that container's own bind mount and would still answer `rw` after the host's Gluster mount had gone read-only. That would keep a broken node in the load balancer's rotation, which is the exact failure the marker exists to prevent.

Only the database access path changed: the script now asks MariaDB inside its container instead of over a host socket.

`HEALTH_ROOT` is root-owned and world-readable, because there is no longer a `caddy` user on the host to own it.

## TLS

An upstream HTTP load balancer should treat every non-2xx response as unhealthy. DNS round-robin without active healthchecks is not sufficient for failover.

Caddy can manage TLS on both cluster nodes because they share certificate and ACME challenge state on Gluster. The upstream load balancer or DNS must allow challenge traffic on ports 80 and 443 to reach either healthy node. If the upstream load balancer terminates TLS instead, configure `CADDY_SITE_ADDRESS=:80`, preserve the public `Host` header (including health checks), and forward plaintext HTTP. In that mode Caddy sends `X-Forwarded-Proto: https` to the loopback-only application.

## Migrating existing Caddy volumes

An older installation kept `/data` in each node's `municipio_caddy_data` Docker volume. The installer refuses to switch to an empty shared directory when that volume contains data. This prevents certificate reissuance and loss of ACME account state.

For a cluster upgrade, mount the Gluster volume on both data VMs, stop both Caddy containers, and copy **one authoritative node's** volume into the shared directory. Do not merge the two old volumes. On the selected node:

```bash
sudo docker stop municipio-caddy
sudo bash -c '
  source /etc/municipio/municipio.env
  mountpoint -q "$DATA_ROOT" || exit 1
  install -d -m 0700 "$DATA_ROOT/caddy"
  docker run --rm --entrypoint sh \
    -v municipio_caddy_data:/old:ro -v "$DATA_ROOT/caddy:/data" \
    "$CADDY_IMAGE" -c "cp -a /old/. /data/"
'
```

After confirming `DATA_ROOT/caddy/caddy` is visible on both VMs, create the migration marker on the selected node with `sudo touch /srv/municipio/data/caddy/.legacy-data-migrated` (use your configured `DATA_ROOT` if different). Then rerun the installer on both and run `/scripts/refresh-sites.municipio.sh` on each. The old named volumes can be removed only after certificates and challenge handling work through the shared directory. In standalone mode the same copy can be made to its local `DATA_ROOT/caddy` without a Gluster mount.
