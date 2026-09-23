# Application container

## Goal

Run an immutable Municipio release and replace it consistently without building on production VMs.

## Solution

`compose.yaml` runs one container named `municipio-app`. It binds OpenLiteSpeed only to `127.0.0.1:8080`, so direct public access is impossible. Caddy is the public entry point.

The selected release is pinned by OCI digest. The current example points to the index digest published for `6.2.5`.

The container reaches the VM's native MariaDB through a read-only bind mount of `/run/mysqld` and a Unix socket connection. Persistent writable paths are bind-mounted from `DATA_ROOT`.

The deployment does not replace the image's WordPress configuration. Municipio's force-SSL plugin handles HTTP references to public content, while `WP_HOME` and `WP_SITEURL` are configured with the public HTTPS address.

In Compose mode, `update.municipio.sh` drains the local node, takes a backup, replaces only its application container, verifies health, and returns the node to service. It does not run `docker compose down`. In Swarm mode, run the command once on the manager: it updates the shared global service one task at a time across the data VMs.
