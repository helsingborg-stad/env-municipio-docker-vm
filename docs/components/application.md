# Application container

## Goal

Run an immutable Municipio release and replace it consistently without building on production VMs.

## Solution

`compose.yaml` runs one container named `municipio-app`. It binds OpenLiteSpeed only to `127.0.0.1:8080`, so direct public access is impossible. Caddy is the public entry point.

The selected release is pinned by OCI digest. The current example points to the index digest published for `6.2.5`.

The container reaches MariaDB through a read-only bind mount of `DB_SOCKET_DIR` at `/run/mysqld` and a Unix socket connection. `WP_CONF_DB_HOST` is unchanged by containerization: it is still `localhost:/run/mysqld/mysqld.sock`. The application container has no network route to the database at all — it does not share a Docker network with it, and MariaDB publishes no port.

Persistent writable paths are bind-mounted from `DATA_ROOT`.

The deployment does not replace the image's WordPress configuration. Municipio's force-SSL plugin handles HTTP references to public content, while `WP_HOME` and `WP_SITEURL` are configured with the public HTTPS address.

In Compose mode, `update.municipio.sh` drains the local node, takes a backup, replaces only its application container, verifies health, and returns the node to service. Every application-level `compose up` passes `--no-deps`, so an application deployment can never recreate the database container — that would drop a Galera bootstrap flag or interrupt replication. In Swarm mode, run the command once on the manager: it updates the shared global service one task at a time across the data VMs.
