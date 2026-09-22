# Application container

## Goal

Run an immutable Municipio release and replace it consistently without building on production VMs.

## Solution

`compose.yaml` runs one container named `municipio-app`. It binds OpenLiteSpeed only to `127.0.0.1:8080`, so direct public access is impossible. Caddy is the public entry point.

The selected release is pinned by OCI digest. The current example points to the index digest published for `6.2.5`.

The container reaches the VM's native MariaDB through a read-only bind mount of `/run/mysqld` and a Unix socket connection. Persistent writable paths are bind-mounted from `DATA_ROOT`.

Image `6.2.5` hardcodes `WP_CONTENT_URL` with `http://`. This repository bind-mounts `runtime/config/content.php` over that configuration file. The override derives the content URL from `WP_HOME` and marks requests as HTTPS when they arrive from the loopback-only Caddy proxy with `X-Forwarded-Proto: https`.

`update.municipio.sh` drains the local node, takes a backup, pulls the new digest, recreates only the application container, verifies health, and returns the node to service. It does not run `docker compose down`.

