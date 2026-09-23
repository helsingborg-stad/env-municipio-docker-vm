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
mariadb-admin --protocol=socket ping --silent

if [[ "$DEPLOYMENT_MODE" != standalone ]]; then
    [[ "$(mariadb --batch --skip-column-names -e "SHOW STATUS LIKE 'wsrep_ready'" | awk '{print $2}')" == ON ]]
    [[ "$(mariadb --batch --skip-column-names -e "SHOW STATUS LIKE 'wsrep_cluster_status'" | awk '{print $2}')" == Primary ]]
    mountpoint -q "$DATA_ROOT"
    findmnt -no OPTIONS --target "$DATA_ROOT" | tr ',' '\n' | grep -qx rw
fi

tmp="${marker}.tmp"
printf 'ok\n' > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$marker"
