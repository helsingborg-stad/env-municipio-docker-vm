# Caddy and health

## Goal

Expose only healthy, fully usable nodes to an HTTP round-robin service, without installing a web server on the host.

## Containerized Caddy

Caddy runs from `CADDY_IMAGE`, digest-pinned. The Caddy apt repository, its signing key and the `caddy` system user are all gone from the host.

Like the database container it uses the host network namespace, so it owns ports 80/443 on the VM directly, sees real client addresses, and reaches the local application at the same loopback address in both Compose and Swarm mode.

| Mount | Purpose |
| --- | --- |
| `CONFIG_ROOT/caddy` → `/etc/caddy` (read-only) | The generated `Caddyfile`. |
| `HEALTH_ROOT` → `/var/lib/municipio/health` (read-only) | The health marker `/healthz` is served from. |
| `caddy_data` volume → `/data` | ACME certificates and account keys. |
| `caddy_config` volume → `/config` | Caddy's autosaved configuration. |

The `caddy_data` volume matters: losing it discards issued certificates and forces reissue, which can hit rate limits. It is a named volume so that recreating the container never touches it.

The **directory** is mounted rather than the `Caddyfile` itself. Replacing a bind-mounted single file swaps its inode and silently detaches the mount, which would only show up on the second configuration change.

## Configuration changes

`install/proxy.sh` writes the candidate `Caddyfile` to a staging directory and validates it with `docker run --rm ... caddy validate` before installing it. Validate-then-install is why a broken configuration never reaches the running proxy.

If the file changed and the container is already running, the installer issues `caddy reload`, which re-reads the bind-mounted file in place. Otherwise it starts the container.

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

Caddy automatic TLS is suitable for standalone. In a multi-node deployment, terminating TLS at the upstream load balancer avoids distributed ACME challenge state; configure `CADDY_SITE_ADDRESS=:80` in that case. The load balancer must preserve the public `Host` header. In this mode Caddy explicitly sends `X-Forwarded-Proto: https` to the loopback-only application.
