#!/usr/bin/env bash
set -euo pipefail
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/common.sh"
load_config
[[ "$NODE_ROLE" == data ]] || exit 0

install -d -m 0755 "$INSTALL_ROOT"
install -m 0644 "$MUNICIPIO_REPO_ROOT/compose.yaml" "$INSTALL_ROOT/compose.yaml"
install -m 0644 "$MUNICIPIO_REPO_ROOT/compose.swarm.yaml" "$INSTALL_ROOT/compose.swarm.yaml"
if [[ "$DOCKER_SWARM" == 1 ]]; then
    swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}')"
    if [[ "$DEPLOYMENT_MODE" == standalone && "$swarm_state" == inactive ]]; then
        docker swarm init --advertise-addr "$NODE_ADDRESS"
        swarm_state=active
    fi
    if [[ "$DEPLOYMENT_MODE" == standalone ]]; then
        swarm_is_manager || die 'Standalone Swarm requires this VM to be a manager'
        docker node update --label-add municipio.data=true "$(docker node inspect self --format '{{.ID}}')"
    elif [[ "$swarm_state" != inactive && "$swarm_state" != active ]]; then
        die "Unexpected Swarm state: $swarm_state"
    fi
fi

if [[ "$DEPLOYMENT_MODE" == standalone ]]; then
    if [[ "$DOCKER_SWARM" == 1 ]]; then
        deploy_application
        wait_for_application
    else
        compose pull
        deploy_application
    fi
fi
