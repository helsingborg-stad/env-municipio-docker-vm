# Configuration

## Goal

Keep installation and runtime settings in one root-owned dotenv file. The interactive installer collects values and generates this file; operators can review it before any later reconfiguration.

The installed file is `/etc/municipio/municipio.env`, owned by root with mode `0600`. It is sourced by root-run maintenance scripts, so its content must be trusted and shell-compatible.

Quote values containing shell metacharacters with single quotes, for example `DB_PASSWORD='a-$-complex-value'`. Do not place commands or command substitutions in the file.

## Required common values

```dotenv
DEPLOYMENT_MODE=standalone
NODE_ROLE=data
NODE_NAME=municipio-01
NODE_ADDRESS=10.20.0.11
SITE_ADDRESS=www.example.se
CADDY_SITE_ADDRESS=www.example.se
MUNICIPIO_IMAGE=ghcr.io/municipio-se/municipio-deployment-docker@sha256:...
DB_NAME=municipio
DB_USER=municipio
DB_PASSWORD=...
```

Set `DOCKER_SWARM=1` to use Swarm instead of Compose. It defaults to `0`. In a two-VM deployment, the preferred VM is the Swarm manager and the secondary VM joins as a worker.

Image tags are intentionally rejected by `update.municipio.sh`; production updates require a digest.

`SITE_ADDRESS` is the initial/main WordPress hostname (and a temporary proxy seed until WordPress starts). It can be an IDN. WP-CLI discovers the actual Caddy host list thereafter. Set `CADDY_SITE_ADDRESS` equal to `SITE_ADDRESS` for Caddy-managed TLS, or `:80` when an upstream HTTP load balancer terminates TLS and forwards plaintext traffic to the VM. It is a TLS-mode switch, not an override for the host list.

Changing a site's domain in WordPress is a database/content migration, not just an env edit. The [site discovery procedure](site-discovery.md) explains how the resulting WordPress hostnames become Caddy routes; the force-SSL plugin does not replace old hostnames in stored content.

## Modes

`standalone` requires no peer settings.

`cluster-manual` requires both data-node names and addresses. The primary node must be listed first because both Galera weighting and Gluster replica ordering use it as the preferred survivor.

`cluster-arbitrator` additionally requires an independent arbitrator name and address. The third host stores no MariaDB data and only Gluster metadata.

## Paths

`DATA_ROOT` is a normal directory on the VM's existing disk. In standalone mode Docker bind-mounts it directly. In cluster mode the same path becomes the local GlusterFS view, backed by `GLUSTER_BRICK` on that VM's disk.

No extra disk or network filesystem is assumed.
