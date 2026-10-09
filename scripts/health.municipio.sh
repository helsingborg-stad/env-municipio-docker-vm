#!/usr/bin/env bash
set -euo pipefail
# Installed by install/maintenance.sh; the repository copy is scripts/lib/common.sh.
# shellcheck disable=SC1091
source /usr/local/lib/municipio/common.sh
load_config
[[ "${NODE_ROLE:-data}" == data ]] || exit 0

marker="${HEALTH_ROOT}/healthz"
# Keep the last successful marker while a new check is in progress. This avoids a
# transient 404 from Caddy on every healthy timer run. Any failed or interrupted
# evaluation removes it, so a node leaves load-balancer rotation promptly.
remove_marker_on_failure() {
    local status=$?
    if ((status != 0)); then
        rm -f "$marker"
    fi
    return "$status"
}
trap remove_marker_on_failure EXIT
trap 'exit 1' INT TERM

[[ ! -e /run/municipio/maintenance ]] || exit 1
if [[ "$DOCKER_SWARM" == 1 ]]; then
    [[ -n "$(docker ps -q --filter label=com.docker.swarm.service.name="$(swarm_service_name)" --filter status=running)" ]]
else
    docker inspect -f '{{.State.Running}}' municipio-app 2>/dev/null | grep -qx true
fi
curl -fsS --max-time 15 -o /dev/null "http://${APP_BIND_ADDRESS:-127.0.0.1}:${APP_BIND_PORT:-8080}/"
# Without credentials the ping still succeeds, but MariaDB logs a denied root login
# on every run of the 10-second timer.
db_root mariadb-admin -uroot --protocol=socket ping --silent
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
