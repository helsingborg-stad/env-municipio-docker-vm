#!/usr/bin/env bash
set -euo pipefail
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/common.sh"
load_config

if [[ "$NODE_ROLE" == arbiter ]]; then
    cat > /etc/default/garb <<EOF
GALERA_NODES="${PRIMARY_NODE_ADDRESS}:4567,${SECONDARY_NODE_ADDRESS}:4567"
GALERA_GROUP="municipio"
GALERA_OPTIONS=""
LOG_FILE="/var/log/garb.log"
EOF
    systemctl disable garb >/dev/null 2>&1 || true
    systemctl stop garb >/dev/null 2>&1 || true
    log 'Galera arbitrator configured but stopped pending explicit cluster start'
    exit 0
fi

if [[ "${INSTALL_PACKAGES:-true}" == true ]]; then
    export DEBIAN_FRONTEND=noninteractive
    packages=(mariadb-server mariadb-backup)
    [[ "$DEPLOYMENT_MODE" != standalone ]] && packages+=(galera-4 rsync)
    apt-get install -y "${packages[@]}"
fi

cnf=/etc/mysql/mariadb.conf.d/60-municipio.cnf
tmp_cnf="$(mktemp)"
trap 'rm -f "$tmp_cnf"' EXIT
install -d -m 0755 "$(dirname "$cnf")"
{
    echo '[mysqld]'
    echo 'bind-address=127.0.0.1'
    echo 'skip-name-resolve=1'
    if [[ "$DEPLOYMENT_MODE" != standalone ]]; then
        weight=1
        [[ "$NODE_NAME" == "$PRIMARY_NODE_NAME" && "$DEPLOYMENT_MODE" == cluster-manual ]] && weight=2
        echo 'binlog_format=ROW'
        echo 'default_storage_engine=InnoDB'
        echo 'innodb_autoinc_lock_mode=2'
        echo 'wsrep_on=ON'
        echo 'wsrep_provider=/usr/lib/galera/libgalera_smm.so'
        echo "wsrep_cluster_name=municipio"
        echo "wsrep_cluster_address=gcomm://${PRIMARY_NODE_ADDRESS},${SECONDARY_NODE_ADDRESS}"
        echo "wsrep_node_name=${NODE_NAME}"
        echo "wsrep_node_address=${NODE_ADDRESS}"
        echo 'wsrep_sst_method=rsync'
        echo "wsrep_provider_options=pc.weight=${weight}"
    fi
} > "$tmp_cnf"

config_changed=true
if [[ -f "$cnf" ]] && cmp -s "$tmp_cnf" "$cnf"; then
    config_changed=false
fi

if [[ "$DEPLOYMENT_MODE" != standalone && -f /etc/municipio/cluster-initialized && "$config_changed" == true ]]; then
    die 'Live Galera configuration differs; apply it with a planned rolling maintenance procedure'
fi
install -m 0644 "$tmp_cnf" "$cnf"

if [[ "$DEPLOYMENT_MODE" == standalone ]]; then
    systemctl enable mariadb
    if [[ "$config_changed" == true ]]; then
        systemctl restart mariadb
    else
        systemctl start mariadb
    fi
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
else
    if [[ ! -f /etc/municipio/cluster-initialized ]]; then
        systemctl disable mariadb >/dev/null 2>&1 || true
        systemctl stop mariadb >/dev/null 2>&1 || true
        log "Galera configured but stopped pending explicit bootstrap/join"
    else
        log "Existing Galera node left running"
    fi
fi
