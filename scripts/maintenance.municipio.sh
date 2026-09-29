#!/usr/bin/env bash
set -euo pipefail
# Installed by install/maintenance.sh; the repository copy is scripts/lib/common.sh.
# shellcheck disable=SC1091
source /usr/local/lib/municipio/common.sh
load_config
action="${1:-}"
flag=/run/municipio/maintenance
install -d -m 0755 /run/municipio

case "$action" in
    on)
        touch "$flag"
        rm -f "${HEALTH_ROOT}/healthz"
        if [[ "${2:-}" == --database-read-only ]]; then
            db_root mariadb -uroot -e 'SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;' 2>/dev/null || \
                db_root mariadb -uroot -e 'SET GLOBAL read_only=ON;'
        fi
        echo 'maintenance=on'
        ;;
    off)
        db_root mariadb -uroot -e 'SET GLOBAL read_only=OFF;' 2>/dev/null || true
        rm -f "$flag"
        /scripts/health.municipio.sh
        echo 'maintenance=off'
        ;;
    *) echo "Usage: $0 on [--database-read-only] | off" >&2; exit 2 ;;
esac
