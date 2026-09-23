#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/municipio/common.sh
load_config
[[ "${NODE_ROLE:-data}" == data ]] || exit 0

marker="${HEALTH_ROOT}/healthz"
rm -f "$marker"
[[ ! -e /run/municipio/maintenance ]] || exit 1
if [[ "$DOCKER_SWARM" == 1 ]]; then
    [[ -n "$(docker ps -q --filter label=com.docker.swarm.service.name="$(swarm_service_name)" --filter status=running)" ]]
else
    docker inspect -f '{{.State.Running}}' municipio-app 2>/dev/null | grep -qx true
fi
curl -fsS -o /dev/null "http://${APP_BIND_ADDRESS:-127.0.0.1}:${APP_BIND_PORT:-8080}/"
db_exec mariadb-admin --protocol=socket ping --silent
# The application reaches MariaDB only through this socket, so its presence on the host
# is part of the health contract, not an implementation detail.
[[ -S "${DB_SOCKET_DIR}/mysqld.sock" ]]

if [[ "$DEPLOYMENT_MODE" != standalone ]]; then
    [[ "$(db_status_value wsrep_ready)" == ON ]]
    [[ "$(db_status_value wsrep_cluster_status)" == Primary ]]
    # Evaluated on the host on purpose: inside a container findmnt would report the
    # container's own bind mount and would still say "rw" after the host's Gluster mount
    # had gone read-only, keeping a broken node in the load balancer's rotation.
    mountpoint -q "$DATA_ROOT"
    findmnt -no OPTIONS --target "$DATA_ROOT" | tr ',' '\n' | grep -qx rw
fi

tmp="${marker}.tmp"
printf 'ok\n' > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$marker"
