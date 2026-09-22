#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

while (($#)); do
    case "$1" in
        --env-file) ENV_FILE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0 --env-file /path/to/env" >&2
    exit 1
fi

export MUNICIPIO_REPO_ROOT="$ROOT_DIR"
export MUNICIPIO_ENV_FILE="$ENV_FILE"
source "$ROOT_DIR/scripts/lib/common.sh"
load_config

for component in host storage database maintenance application proxy; do
    log "Installing component: $component"
    "$ROOT_DIR/scripts/install/$component.sh"
done

log "Installation prepared successfully"
if [[ "$DEPLOYMENT_MODE" == "standalone" ]]; then
    log "Standalone is running. Check: /scripts/status.municipio.sh"
else
    log "Cluster is prepared but not bootstrapped. See docs/runbook.md"
fi
