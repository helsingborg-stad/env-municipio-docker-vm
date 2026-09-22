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
        [[ "$DOCKER_SWARM" == 1 ]] || compose pull
        deploy_application
        wait_for_application
        /scripts/maintenance.municipio.sh off
        ;;
    join)
        [[ "$NODE_ROLE" == data ]] || die 'Join must run on a data node'
        mount_volume
        systemctl enable --now mariadb
        touch /etc/municipio/cluster-initialized
        [[ "$DOCKER_SWARM" == 1 ]] || compose pull
        deploy_application
        wait_for_application
        /scripts/maintenance.municipio.sh off
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
    *) echo "Usage: $0 bootstrap | join | status | restore-quorum | clear-cache --all-nodes-drained | start-arbitrator" >&2; exit 2 ;;
esac
