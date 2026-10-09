#!/usr/bin/env bash
set -euo pipefail
# Installed by install/maintenance.sh; the repository copy is scripts/lib/common.sh.
# shellcheck disable=SC1091
source /usr/local/lib/municipio/common.sh
load_config
[[ "$DEPLOYMENT_MODE" != standalone ]] || die 'Cluster commands are unavailable in standalone mode'
action="${1:-status}"
CLUSTER_START_WAIT_SECONDS=60

wait_for_peer() {
    local address="$1" name="$2" started=$SECONDS probe_error
    log "Waiting up to ${CLUSTER_START_WAIT_SECONDS}s for Gluster peer $address"
    while ! peer_is_connected "$address" "$name"; do
        probe_error="$(gluster peer probe "$address" 2>&1)" || true
        (( SECONDS - started >= CLUSTER_START_WAIT_SECONDS )) && \
            die "Gluster peer $address did not become available within ${CLUSTER_START_WAIT_SECONDS}s. Last reply: ${probe_error}. Check that glusterd is active on the other server and that the Gluster ports are reachable."
        sleep 2
    done
}

peer_is_connected() {
    local address="$1" name="$2"
    timeout 5 gluster peer status 2>/dev/null | awk -v address="$address" -v name="$name" '
        /^Hostname:/ { host = $2 }
        /^State: Peer in Cluster \(Connected\)/ && (host == address || host == name) { found = 1 }
        END { exit !found }
    '
}

ensure_volume_started() {
    if gluster volume info municipio 2>/dev/null | grep -q 'Status: Started'; then
        return 0
    fi
    gluster volume start municipio >/dev/null 2>&1 || \
        die 'Gluster volume municipio could not be started. Run gluster volume info municipio and gluster volume status municipio on the primary server.'
    gluster volume info municipio 2>/dev/null | grep -q 'Status: Started' || \
        die 'Gluster volume municipio did not report Status: Started after start.'
}

mount_volume() {
    local wait_for_volume="${1:-}"
    [[ -z "$wait_for_volume" || "$wait_for_volume" == --wait-for-volume ]] || \
        die 'mount_volume accepts only --wait-for-volume'
    grep -qE "^[^#]+[[:space:]]+${DATA_ROOT//\//\\/}[[:space:]]" /etc/fstab || \
        echo "localhost:/municipio ${DATA_ROOT} glusterfs defaults,_netdev,backupvolfile-server=${SECONDARY_NODE_ADDRESS} 0 0" >> /etc/fstab
    if [[ "$wait_for_volume" == --wait-for-volume ]]; then
        # The secondary can reach this point while the primary is still creating the
        # volume. Retrying here gives Gluster time to receive that definition instead
        # of making a simultaneous wizard run fail spuriously.
        local started=$SECONDS
        log "Waiting up to ${CLUSTER_START_WAIT_SECONDS}s for Gluster volume municipio to mount"
        until mountpoint -q "$DATA_ROOT" || timeout 5 mount "$DATA_ROOT"; do
            (( SECONDS - started >= CLUSTER_START_WAIT_SECONDS )) && \
                die "Gluster volume municipio did not mount within ${CLUSTER_START_WAIT_SECONDS}s. Check the primary bootstrap and run gluster peer status on both servers."
            sleep 2
        done
    else
        mountpoint -q "$DATA_ROOT" || mount "$DATA_ROOT"
    fi
    [[ "$(findmnt -no FSTYPE --target "$DATA_ROOT")" == fuse.glusterfs ]] || \
        die "DATA_ROOT is not a Gluster mount: $DATA_ROOT"
    findmnt -no OPTIONS --target "$DATA_ROOT" | tr ',' '\n' | grep -qx rw || \
        die "DATA_ROOT is read-only: $DATA_ROOT"
    install -d -o 1000 -g 1000 -m 0755 "$DATA_ROOT/uploads" "$DATA_ROOT/cache"
    install -d -m 0700 "$DATA_ROOT/caddy"
}

case "$action" in
    bootstrap)
        [[ "$NODE_ROLE" == data ]] || die 'Bootstrap must run on a data node'
        [[ "$NODE_NAME" == "$PRIMARY_NODE_NAME" ]] || die 'Bootstrap must run on PRIMARY_NODE_NAME'
        wait_for_peer "$SECONDARY_NODE_ADDRESS" "$SECONDARY_NODE_NAME"
        if [[ "$DEPLOYMENT_MODE" == cluster-arbitrator ]]; then
            wait_for_peer "$ARBITRATOR_NODE_ADDRESS" "$ARBITRATOR_NODE_NAME"
            gluster volume info municipio >/dev/null 2>&1 || gluster --mode=script volume create municipio replica 2 arbiter 1 \
                "${PRIMARY_NODE_ADDRESS}:${GLUSTER_BRICK}" \
                "${SECONDARY_NODE_ADDRESS}:${GLUSTER_BRICK}" \
                "${ARBITRATOR_NODE_ADDRESS}:${GLUSTER_BRICK}" force
        else
            # --mode=script answers Gluster's replica-2 split-brain confirmation, which would
            # otherwise stop an unattended bootstrap; quorum and fencing handle that risk.
            gluster volume info municipio >/dev/null 2>&1 || gluster --mode=script volume create municipio replica 2 \
                "${PRIMARY_NODE_ADDRESS}:${GLUSTER_BRICK}" \
                "${SECONDARY_NODE_ADDRESS}:${GLUSTER_BRICK}" force
            gluster volume set municipio cluster.quorum-type auto
        fi
        ensure_volume_started
        mount_volume
        docker pull -q "$MARIADB_IMAGE" >/dev/null
        # The container keeps its command across restarts. The marker records that,
        # and status reports it until clear-bootstrap-flag removes both.
        touch "$(galera_bootstrap_marker)"
        compose_galera_bootstrap up -d --no-deps --force-recreate db
        wait_for_database 600 || die 'MariaDB did not form a Galera primary component'
        verify_socket_ownership
        [[ "$(db_status_value wsrep_cluster_status)" == Primary ]] || die 'Galera did not reach the Primary component'
        touch "$CONFIG_ROOT/cluster-initialized"
        provision_database
        if [[ "$DOCKER_SWARM" == 1 ]]; then
            swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}')"
            if [[ "$swarm_state" == inactive ]]; then
                docker swarm init --advertise-addr "$NODE_ADDRESS"
            fi
            swarm_is_manager || die 'Bootstrap node must be the Swarm manager'
            docker node update --label-add municipio.data=true "$(docker node inspect self --format '{{.ID}}')"
        else
            compose pull municipio
        fi
        deploy_application
        wait_for_application
        /scripts/refresh-sites.municipio.sh
        /scripts/maintenance.municipio.sh off
        log 'Bootstrapped. Once the secondary has joined, run: clear-bootstrap-flag'
        ;;
    join)
        [[ "$NODE_ROLE" == data ]] || die 'Join must run on a data node'
        mount_volume --wait-for-volume
        docker pull -q "$MARIADB_IMAGE" >/dev/null
        start_database
        # A joiner receives a full state transfer from the donor before it can answer,
        # so this waits far longer than a standalone start.
        wait_for_database 3600 || die 'MariaDB did not complete its Galera state transfer'
        verify_socket_ownership
        [[ "$(db_status_value wsrep_ready)" == ON ]] || die 'Local Galera is not ready'
        [[ "$(db_status_value wsrep_cluster_status)" == Primary ]] || die 'Local Galera is not in the Primary component'
        # The state transfer overwrites the privilege tables with the donor's copy, so
        # the local root password only works if both nodes were configured with the same
        # DB_ROOT_PASSWORD. Detect that here instead of at the next maintenance command.
        db_root mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1 || \
            die 'DB_ROOT_PASSWORD does not match the one the donor replicated. Both data VMs must be installed with the same database root password.'
        mountpoint -q "$DATA_ROOT" || die 'Local Gluster mount is missing'
        findmnt -no OPTIONS --target "$DATA_ROOT" | tr ',' '\n' | grep -qx rw || die 'Local Gluster mount is read-only'
        [[ -w "$DATA_ROOT/uploads" && -w "$DATA_ROOT/cache" ]] || die 'Local shared data is not writable'
        touch "$CONFIG_ROOT/cluster-initialized"
        if [[ "$DOCKER_SWARM" == 1 ]]; then
            [[ "$(docker info --format '{{.Swarm.LocalNodeState}}')" == inactive ]] || die 'This VM already belongs to a Swarm'
            [[ "${2:-}" == --token-stdin ]] || die 'Provide the worker join token on standard input with join --token-stdin'
            [[ ! -t 0 ]] || printf 'Swarm worker join token: ' >&2
            read -r -s join_token
            [[ ! -t 0 ]] || printf '\n' >&2
            [[ -n "$join_token" ]] || die 'Missing Swarm worker join token'
            docker swarm join --token "$join_token" --advertise-addr "$NODE_ADDRESS" "$PRIMARY_NODE_ADDRESS:2377"
            /scripts/refresh-sites.municipio.sh --bootstrap-if-unavailable
            log 'Worker joined. Run enable-node on the manager after verifying local state, then refresh sites on this worker.'
        else
            compose pull municipio
            deploy_application
            wait_for_application
            /scripts/refresh-sites.municipio.sh
            /scripts/maintenance.municipio.sh off
        fi
        log 'Joined. On the primary VM, run: clear-bootstrap-flag'
        ;;
    clear-bootstrap-flag)
        [[ -f "$(galera_bootstrap_marker)" ]] || { log 'No Galera bootstrap flag is set'; exit 0; }
        size="$(db_status_value wsrep_cluster_size)"
        [[ "$size" =~ ^[0-9]+$ && "$size" -ge 2 ]] || \
            die "Refusing to clear the bootstrap flag with wsrep_cluster_size=${size}. The peer must have joined first."
        log "Recreating MariaDB without --wsrep-new-cluster (current cluster size: ${size})."
        log 'This node will rejoin through gcomm://. If the peer leaves during the'
        log 'restart, this node comes up non-Primary and stays down until the peer returns.'
        compose up -d --no-deps --force-recreate db
        wait_for_database 600 || die 'MariaDB did not return after clearing the bootstrap flag'
        if [[ "$(db_status_value wsrep_cluster_status)" != Primary ]]; then
            die 'MariaDB restarted but is not in the Primary component. Restore the peer, then re-run this command; do not bootstrap a second time.'
        fi
        rm -f "$(galera_bootstrap_marker)"
        log 'Bootstrap flag cleared; this node now joins normally on restart.'
        ;;
    enable-node)
        [[ "$DOCKER_SWARM" == 1 ]] || die 'enable-node is available in Swarm mode only'
        swarm_is_manager || die 'Run enable-node on the Swarm manager'
        node_id="${2:-}"
        [[ -n "$node_id" && "$node_id" =~ ^[A-Za-z0-9._-]+$ ]] || die 'Provide a valid worker hostname'
        [[ "$(docker node inspect "$node_id" --format '{{.Status.State}}')" == ready ]] || die 'Worker is not ready'
        [[ "$(docker node inspect "$node_id" --format '{{.Spec.Role}}')" == worker ]] || die 'Target must be a worker'
        [[ "$(docker node inspect "$node_id" --format '{{.Status.Addr}}')" == "$SECONDARY_NODE_ADDRESS" ]] || die 'Worker address does not match SECONDARY_NODE_ADDRESS'
        docker node update --label-add municipio.data=true "$node_id"
        deploy_application
        wait_for_application
        /scripts/refresh-sites.municipio.sh
        ;;
    status) /scripts/status.municipio.sh ;;
    restore-quorum)
        [[ "$DEPLOYMENT_MODE" == cluster-manual ]] || die 'Only cluster-manual changes storage quorum'
        gluster volume set municipio cluster.quorum-type auto
        ;;
    clear-cache)
        [[ "${2:-}" == --all-nodes-drained ]] || die 'Refusing shared cache deletion without --all-nodes-drained'
        find "${DATA_ROOT:?}/cache" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        ;;
    start-arbitrator)
        [[ "$NODE_ROLE" == arbiter ]] || die 'start-arbitrator must run on the arbitrator host'
        [[ "$DEPLOYMENT_MODE" == cluster-arbitrator ]] || die 'Arbitrator requires cluster-arbitrator mode'
        systemctl enable --now glusterd
        systemctl enable --now garb
        ;;
    *) echo "Usage: $0 bootstrap | join [--token-stdin] | clear-bootstrap-flag | enable-node HOSTNAME | status | restore-quorum | clear-cache --all-nodes-drained | start-arbitrator" >&2; exit 2 ;;
esac
