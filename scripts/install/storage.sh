#!/usr/bin/env bash
set -euo pipefail
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/common.sh"
load_config

if [[ "$NODE_ROLE" == arbiter ]]; then
    install -d -m 0750 "${GLUSTER_BRICK}"
    exit 0
fi

# Owned by the mysql user inside MARIADB_IMAGE. install/database.sh verifies the
# identifiers against the running container and fails loudly on a mismatch.
install -d -o "$DB_SOCKET_UID" -g "$DB_SOCKET_GID" -m 0755 "$DB_DATA_ROOT"
install -d -o "$DB_SOCKET_UID" -g "$DB_SOCKET_GID" -m 0755 "$DB_SOCKET_DIR"

if [[ "$DEPLOYMENT_MODE" == standalone ]]; then
    install -d -o 1000 -g 1000 -m 0755 "${DATA_ROOT}/uploads" "${DATA_ROOT}/cache"
    # OpenLiteSpeed runs as lsadm (994) and stores its rendered page cache here.
    # DATA_ROOT is Gluster-backed in cluster mode, so this cache is replicated too.
    install -d -o 994 -g 994 -m 0755 "${DATA_ROOT}/cache/litespeed"
    install -d -m 0700 "${DATA_ROOT}/caddy"
else
    install -d -m 0750 "${GLUSTER_BRICK}" "${DATA_ROOT}"
    log "Gluster directories prepared; bootstrap/join is an explicit cluster operation"
fi
