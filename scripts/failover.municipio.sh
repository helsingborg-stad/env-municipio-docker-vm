#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/municipio/common.sh
load_config
action="${1:-}"

case "$action" in
    provision-database) provision_database ;;
    promote)
        [[ "$DEPLOYMENT_MODE" == cluster-manual ]] || die 'Manual promotion applies only to cluster-manual'
        [[ "${2:-}" == --fence-confirmed ]] || die 'Refusing promotion without --fence-confirmed'
        /scripts/maintenance.municipio.sh on
        # Recreating with the overlay both stops the old container and starts a new
        # primary component. The marker survives so that status keeps reporting that a
        # reboot of this node would form yet another cluster.
        touch "$(galera_bootstrap_marker)"
        compose_galera_bootstrap up -d --no-deps --force-recreate db
        wait_for_database 600 || die 'Promoted MariaDB did not become available'
        [[ "$(db_status_value wsrep_cluster_status)" == Primary ]] || die 'Promoted node did not reach the Primary component'
        gluster volume set municipio cluster.quorum-type none
        mountpoint -q "$DATA_ROOT" || mount "$DATA_ROOT"
        /scripts/maintenance.municipio.sh off
        log 'Node promoted. Do not return the fenced node before completing the recovery runbook.'
        log 'After the former node has rejoined, run: cluster.municipio.sh clear-bootstrap-flag'
        ;;
    *) echo "Usage: $0 provision-database | promote --fence-confirmed" >&2; exit 2 ;;
esac
