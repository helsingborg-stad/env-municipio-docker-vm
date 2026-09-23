#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/municipio/common.sh
load_config
label="${1:-scheduled}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
target="${BACKUP_ROOT}/${stamp}-${label}"
install -d -m 0700 "$target"
db_root mariadb-dump -uroot --single-transaction --routines --events "$DB_NAME" | gzip -c > "$target/database.sql.gz"
tar -C "$DATA_ROOT" -czf "$target/files.tar.gz" uploads cache
install -m 0600 "$MUNICIPIO_ENV_FILE" "$target/municipio.env"
# Record every image the restore has to reproduce, not just the application.
{
    if [[ "$DOCKER_SWARM" == 1 ]]; then
        local_container="$(docker ps -q --filter label=com.docker.swarm.service.name="$(swarm_service_name)" --filter status=running | head -n 1)"
        [[ -n "$local_container" ]] || die 'No local Municipio task to record'
        docker inspect -f '{{.Config.Image}}' "$local_container"
    else
        docker inspect -f '{{.Config.Image}}' municipio-app
    fi
    printf '%s\n%s\n' "$MARIADB_IMAGE" "$CADDY_IMAGE"
} > "$target/image.txt"
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +"${BACKUP_RETENTION_DAYS:-14}" -print -exec rm -rf -- {} +
echo "$target"
