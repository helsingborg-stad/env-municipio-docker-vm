#!/usr/bin/env bash
set -euo pipefail
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/common.sh"
load_config

if [[ "$NODE_ROLE" == arbiter ]]; then
    # garbd is not part of the MariaDB image and the arbitrator runs no container at
    # all, so it stays a host package on this quorum-only witness host.
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

# The container reads every file in this directory through the image's
# `!includedir /etc/mysql/conf.d/`.
conf_dir="$CONFIG_ROOT/mariadb"
cnf="$conf_dir/60-municipio.cnf"
install -d -m 0755 "$conf_dir"
tmp_cnf="$(mktemp)"
trap 'rm -f "$tmp_cnf"' EXIT
{
    echo '[mysqld]'
    # The container shares the host network namespace, so this is the host loopback.
    # Client traffic never leaves the VM; the application uses the Unix socket.
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

if [[ "$DEPLOYMENT_MODE" != standalone && -f "$CONFIG_ROOT/cluster-initialized" && "$config_changed" == true ]]; then
    die 'Live Galera configuration differs; apply it with a planned rolling maintenance procedure'
fi
install -m 0644 "$tmp_cnf" "$cnf"

if [[ "$DEPLOYMENT_MODE" == standalone ]]; then
    docker pull -q "$MARIADB_IMAGE" >/dev/null
    if [[ "$config_changed" == true ]]; then
        compose up -d --no-deps --force-recreate db
    else
        start_database
    fi
    wait_for_database 300 || die 'MariaDB container did not become available'
    verify_socket_ownership
    provision_database
elif [[ ! -f "$CONFIG_ROOT/cluster-initialized" ]]; then
    compose stop db >/dev/null 2>&1 || true
    log 'Galera configured but stopped pending explicit bootstrap/join'
else
    log 'Existing Galera node left running'
fi
