#!/usr/bin/env bash
set -euo pipefail

# This service runs during boot before systemd mounts DATA_ROOT.  A Gluster
# client can connect before its local brick is ready, then leave a broken FUSE
# mount behind.  Wait for the exact local brick instead of merely glusterd.
source /usr/local/lib/municipio/common.sh
load_config

[[ "$DEPLOYMENT_MODE" != standalone && "$NODE_ROLE" == data ]] || exit 0

readonly WAIT_SECONDS=120
readonly POLL_SECONDS=2
started=$SECONDS
brick="${NODE_ADDRESS}:${GLUSTER_BRICK}"

brick_online() {
    timeout 10 gluster volume status municipio "$brick" detail 2>/dev/null | \
        grep -Eq '^[[:space:]]*Online[[:space:]]*:[[:space:]]*Y[[:space:]]*$'
}

log "Waiting up to ${WAIT_SECONDS}s for local Gluster brick ${brick}"
while ! brick_online; do
    if (( SECONDS - started >= WAIT_SECONDS )); then
        die "Local Gluster brick ${brick} did not become online within ${WAIT_SECONDS}s"
    fi
    sleep "$POLL_SECONDS"
done
log "Local Gluster brick ${brick} is online"
