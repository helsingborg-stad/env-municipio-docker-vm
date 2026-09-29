#!/usr/bin/env bash
set -euo pipefail
# Installed by install/maintenance.sh; the repository copy is scripts/lib/common.sh.
# shellcheck disable=SC1091
source /usr/local/lib/municipio/common.sh
load_config

echo "node=$NODE_NAME role=$NODE_ROLE mode=$DEPLOYMENT_MODE"
if [[ "$NODE_ROLE" == data ]]; then
    compose ps db caddy
    if [[ "$DOCKER_SWARM" == 1 ]]; then
        if swarm_is_manager; then
            docker stack services municipio 2>/dev/null || echo 'swarm_stack=not-deployed'
            docker stack ps --no-trunc municipio 2>/dev/null || true
        else
            docker ps --filter label=com.docker.swarm.service.name="$(swarm_service_name)"
        fi
    else
        compose ps municipio
    fi
    [[ -S "${DB_SOCKET_DIR}/mysqld.sock" ]] && echo 'db_socket=present' || echo 'db_socket=missing'
    if [[ -f "$(galera_bootstrap_marker)" ]]; then
        echo 'galera_bootstrap=ACTIVE - this node re-forms a new cluster on restart.'
        echo '  Run: /scripts/cluster.municipio.sh clear-bootstrap-flag'
    fi
    if [[ "$DEPLOYMENT_MODE" != standalone ]] && db_container >/dev/null 2>&1; then
        db_root mariadb -uroot --table -e "SHOW STATUS WHERE Variable_name IN ('wsrep_ready','wsrep_connected','wsrep_cluster_status','wsrep_cluster_size','wsrep_local_state_comment')"
        gluster volume status municipio || true
        gluster volume heal municipio info summary || true
    fi
else
    systemctl --no-pager --quiet is-active garb && echo 'garb=active' || echo 'garb=inactive'
    systemctl --no-pager --quiet is-active glusterd && echo 'glusterd=active' || echo 'glusterd=inactive'
fi
if [[ "$NODE_ROLE" == data ]]; then
    [[ -f "${HEALTH_ROOT:-/var/lib/municipio/health}/healthz" ]] && echo 'health=ready' || echo 'health=unavailable'
fi
