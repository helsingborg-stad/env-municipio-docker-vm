#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/municipio/common.sh
load_config
[[ "$DEPLOYMENT_MODE" != standalone ]] || die 'Cluster commands are unavailable in standalone mode'
action="${1:-status}"

mount_volume() {
    grep -qE "^[^#]+[[:space:]]+${DATA_ROOT//\//\\/}[[:space:]]" /etc/fstab || \
        echo "localhost:/municipio ${DATA_ROOT} glusterfs defaults,_netdev,backupvolfile-server=${SECONDARY_NODE_ADDRESS} 0 0" >> /etc/fstab
    mountpoint -q "$DATA_ROOT" || mount "$DATA_ROOT"
    install -d -o 1000 -g 1000 -m 0755 "$DATA_ROOT/uploads" "$DATA_ROOT/cache"
}

case "$action" in
    bootstrap)
        [[ "$NODE_ROLE" == data ]] || die 'Bootstrap must run on a data node'
        [[ "$NODE_NAME" == "$PRIMARY_NODE_NAME" ]] || die 'Bootstrap must run on PRIMARY_NODE_NAME'
        gluster peer probe "$SECONDARY_NODE_ADDRESS"
        if [[ "$DEPLOYMENT_MODE" == cluster-arbitrator ]]; then
            gluster peer probe "$ARBITRATOR_NODE_ADDRESS"
            gluster volume info municipio >/dev/null 2>&1 || gluster volume create municipio replica 2 arbiter 1 \
                "${PRIMARY_NODE_ADDRESS}:${GLUSTER_BRICK}" \
                "${SECONDARY_NODE_ADDRESS}:${GLUSTER_BRICK}" \
                "${ARBITRATOR_NODE_ADDRESS}:${GLUSTER_BRICK}" force
        else
            gluster volume info municipio >/dev/null 2>&1 || gluster volume create municipio replica 2 \
                "${PRIMARY_NODE_ADDRESS}:${GLUSTER_BRICK}" \
                "${SECONDARY_NODE_ADDRESS}:${GLUSTER_BRICK}" force
            gluster volume set municipio cluster.quorum-type auto
        fi
        gluster volume start municipio || true
        mount_volume
        galera_new_cluster
        touch /etc/municipio/cluster-initialized
        /scripts/failover.municipio.sh provision-database
        if [[ "$DOCKER_SWARM" == 1 ]]; then
            swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}')"
            if [[ "$swarm_state" == inactive ]]; then
                docker swarm init --advertise-addr "$NODE_ADDRESS"
            fi
            swarm_is_manager || die 'Bootstrap node must be the Swarm manager'
            docker node update --label-add municipio.data=true "$(docker node inspect self --format '{{.ID}}')"
        else
            compose pull
        fi
        deploy_application
        wait_for_application
        /scripts/refresh-sites.municipio.sh
        /scripts/maintenance.municipio.sh off
        ;;
    join)
        [[ "$NODE_ROLE" == data ]] || die 'Join must run on a data node'
        mount_volume
        systemctl enable --now mariadb
        [[ "$(mariadb --batch --skip-column-names -e "SHOW STATUS LIKE 'wsrep_ready'" | awk '{print $2}')" == ON ]] || die 'Local Galera is not ready'
        [[ "$(mariadb --batch --skip-column-names -e "SHOW STATUS LIKE 'wsrep_cluster_status'" | awk '{print $2}')" == Primary ]] || die 'Local Galera is not in the Primary component'
        mountpoint -q "$DATA_ROOT" || die 'Local Gluster mount is missing'
        findmnt -no OPTIONS --target "$DATA_ROOT" | tr ',' '\n' | grep -qx rw || die 'Local Gluster mount is read-only'
        [[ -w "$DATA_ROOT/uploads" && -w "$DATA_ROOT/cache" ]] || die 'Local shared data is not writable'
        touch /etc/municipio/cluster-initialized
        if [[ "$DOCKER_SWARM" == 1 ]]; then
            [[ "$(docker info --format '{{.Swarm.LocalNodeState}}')" == inactive ]] || die 'This VM already belongs to a Swarm'
            [[ "${2:-}" == --token-stdin ]] || die 'Provide the worker join token on standard input with join --token-stdin'
            [[ ! -t 0 ]] || printf 'Swarm worker join token: ' >&2
            read -r -s join_token
            [[ ! -t 0 ]] || printf '\n' >&2
            [[ -n "$join_token" ]] || die 'Missing Swarm worker join token'
            docker swarm join --token "$join_token" --advertise-addr "$NODE_ADDRESS" "$PRIMARY_NODE_ADDRESS:2377"
            log 'Worker joined. Run enable-node on the manager after verifying local state.'
        else
            compose pull
            deploy_application
            wait_for_application
            /scripts/refresh-sites.municipio.sh
            /scripts/maintenance.municipio.sh off
        fi
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
        systemctl enable --now garb
        systemctl enable --now glusterd
        ;;
    *) echo "Usage: $0 bootstrap | join [--token-stdin] | enable-node HOSTNAME | status | restore-quorum | clear-cache --all-nodes-drained | start-arbitrator" >&2; exit 2 ;;
esac
