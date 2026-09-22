#!/usr/bin/env bash
set -euo pipefail
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/common.sh"
load_config

if [[ "$NODE_ROLE" == arbiter ]]; then
    install -d -m 0750 "${GLUSTER_BRICK}"
    systemctl enable --now glusterd
    exit 0
fi

if [[ "$DEPLOYMENT_MODE" == standalone ]]; then
    install -d -o 1000 -g 1000 -m 0755 "${DATA_ROOT}/uploads" "${DATA_ROOT}/cache"
else
    install -d -m 0750 "${GLUSTER_BRICK}" "${DATA_ROOT}"
    systemctl enable --now glusterd
    log "Gluster directories prepared; bootstrap/join is an explicit cluster operation"
fi

