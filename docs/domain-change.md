# Change the public domain

## Goal

Move an installed Municipio site to a new hostname without leaving old URLs in WordPress data or serving traffic while only part of a cluster has changed.

## Requirements and limits

- Rerun the current installer and choose to reuse the saved configuration before starting, so `/scripts/change-domain.municipio.sh` and the staged proxy command are installed on existing VMs.
- Use a maintenance window. Configure the new DNS and, if TLS terminates upstream, the upstream certificate and routing before starting.
- Take and verify an independent off-VM backup. The command also makes a fresh local database/files/configuration backup before changing anything.
- The pinned Municipio container **must** include WP-CLI. `preflight` checks this and stops without changes if it is missing. The image's WP-CLI availability has not yet been confirmed for every release. Do not replace this step with SQL `REPLACE()`: WordPress data may be PHP-serialized.
- This first version supports single-site WordPress installations only. It refuses multisite. It accepts DNS hostnames, not a scheme, path, port, or custom Caddy listener other than `:80`.
- External Redis caching is not migrated automatically; the command refuses to proceed when Redis is enabled. The normal local/shared file cache is cleared after the backup and database migration.
- The command disables and masks Caddy after staging the change, so a reboot cannot silently reopen traffic. `resume` is a separate, explicit action. If a step fails, leave traffic offline and inspect the migration state and backup; there is no automatic database rollback.

WP-CLI's [search-replace command](https://developer.wordpress.org/cli/commands/search-replace/) supports dry runs and handles serialized data. The command skips WordPress GUID columns, replaces both `http://OLD` and `https://OLD` with `https://NEW`, and runs only once against the cluster's Galera database.

## Standalone

Run locally on the VM, substituting the new hostname:

```bash
sudo /scripts/change-domain.municipio.sh preflight new.example.org
sudo /scripts/change-domain.municipio.sh migrate new.example.org
sudo /scripts/change-domain.municipio.sh status
```

Read the preflight report before running `migrate`. That command enables maintenance, disables and masks Caddy, takes and verifies a backup, migrates database URLs, updates `/etc/municipio/municipio.env`, redeploys the container, and writes the new Caddyfile. It does **not** reopen traffic. After confirming the staged configuration and DNS/TLS readiness:

```bash
sudo /scripts/change-domain.municipio.sh resume
sudo /scripts/status.municipio.sh
curl -fsS https://new.example.org/healthz
```

Verify pages, media, login, and redirects through the new hostname before retiring the old DNS or certificate. The generated Caddyfile does not automatically redirect the old hostname; configure a separate redirect if one is required.

## Two data VMs

Do not run `migrate` while the other VM still accepts writes. On **both** data VMs, first run:

```bash
sudo /scripts/maintenance.municipio.sh on
sudo systemctl disable --now caddy.service
sudo systemctl mask caddy.service
```

Confirm the upstream HTTP round-robin has removed both nodes. On the **primary** data VM only, run the dry run and one database migration:

```bash
sudo /scripts/change-domain.municipio.sh preflight new.example.org
sudo /scripts/change-domain.municipio.sh migrate new.example.org --all-nodes-offline
```

On the **secondary** data VM, update its local configuration and application task:

```bash
sudo /scripts/change-domain.municipio.sh sync-node new.example.org
```

The primary publishes a completion marker on the replicated data volume only after its local staging succeeds; `sync-node` requires that marker. In Swarm mode, the primary manager rolls the global service and `sync-node` waits for the local worker task to have the new hostname. In Compose mode, `sync-node` recreates only the local application container. Neither command restarts Caddy.

Check `change-domain.municipio.sh status` on both VMs. Once both report `PHASE=ready`, the shared database is healthy, and the new DNS/TLS route is ready, run `resume` on each VM. Then verify `/healthz`, pages, media, login, and redirects through the round-robin endpoint. Do not run `migrate` on the secondary; Galera already synchronized the database change.

## Failure and recovery

If any step fails, leave Caddy masked and maintenance enabled on every data VM. `status` shows the last phase and local backup path. Do not run `resume` unless the phase is `ready`. The local backup contains `database.sql.gz`, `files.tar.gz`, `municipio.env`, and `image.txt`; copy it off the VM before attempting a repair. Review the database and Galera state before restoring anything, and restore from the backup under a separate recovery procedure if necessary. Blindly reversing the search/replace or starting only one VM can lose data or expose mixed-domain behavior.
