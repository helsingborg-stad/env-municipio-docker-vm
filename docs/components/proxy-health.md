# Caddy and health

## Goal

Expose only healthy, fully usable nodes to an HTTP round-robin service.

## Solution

Caddy runs natively and proxies registered WordPress hostnames to the local container. The generated host blocks are imported from `/etc/caddy/municipio-sites.caddy`; see [WordPress site discovery](../site-discovery.md). `/healthz` is served from a marker file maintained by `municipio-health.timer` every ten seconds.

The marker exists only when:

- maintenance mode is off;
- the local container is running and responds over HTTP;
- local MariaDB responds;
- in cluster mode, Galera is ready and in the Primary component;
- in cluster mode, the replicated data path is mounted read/write.

An upstream HTTP load balancer should treat every non-2xx response as unhealthy. DNS round-robin without active healthchecks is not sufficient for failover.

Caddy automatic TLS is suitable for standalone. In a multi-node deployment, terminating TLS at the upstream HTTP load balancer avoids distributed ACME challenge state; configure `CADDY_SITE_ADDRESS=:80` in that case. The load balancer must preserve the public `Host` header, including for health checks. In this mode Caddy explicitly sends `X-Forwarded-Proto: https` to the loopback-only application.
