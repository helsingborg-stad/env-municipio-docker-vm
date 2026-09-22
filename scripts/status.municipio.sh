#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/municipio/common.sh
load_config

echo "node=$NODE_NAME role=$NODE_ROLE mode=$DEPLOYMENT_MODE"
if [[ "$NODE_ROLE" == data ]]; then
    if [[ "$DOCKER_SWARM" == 1 ]]; then
        docker stack services municipio 2>/dev/null || echo 'swarm_stack=not-deployed'
        docker stack ps --no-trunc municipio 2>/dev/null || true
    else
        compose ps
    fi
    systemctl --no-pager --quiet is-active caddy && echo 'caddy=active' || echo 'caddy=inactive'
    systemctl --no-pager --quiet is-active mariadb && echo 'mariadb=active' || echo 'mariadb=inactive'
    if [[ "$DEPLOYMENT_MODE" != standalone ]] && systemctl --quiet is-active mariadb; then
        mariadb --table -e "SHOW STATUS WHERE Variable_name IN ('wsrep_ready','wsrep_connected','wsrep_cluster_status','wsrep_cluster_size','wsrep_local_state_comment')"
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
