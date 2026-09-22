#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/municipio/common.sh
load_config
action="${1:-}"

provision_database() {
    local db_name db_user db_password
    db_name="$(sql_escape "$DB_NAME")"
    db_user="$(sql_escape "$DB_USER")"
    db_password="$(sql_escape "$DB_PASSWORD")"
    mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';
ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

case "$action" in
    provision-database) provision_database ;;
    promote)
        [[ "$DEPLOYMENT_MODE" == cluster-manual ]] || die 'Manual promotion applies only to cluster-manual'
        [[ "${2:-}" == --fence-confirmed ]] || die 'Refusing promotion without --fence-confirmed'
        /scripts/maintenance.municipio.sh on
        systemctl stop mariadb || true
        galera_new_cluster
        gluster volume set municipio cluster.quorum-type none
        mountpoint -q "$DATA_ROOT" || mount "$DATA_ROOT"
        /scripts/maintenance.municipio.sh off
        log 'Node promoted. Do not return the fenced node before completing the recovery runbook.'
        ;;
    *) echo "Usage: $0 provision-database | promote --fence-confirmed" >&2; exit 2 ;;
esac
