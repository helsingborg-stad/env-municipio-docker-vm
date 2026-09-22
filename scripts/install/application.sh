#!/usr/bin/env bash
set -euo pipefail
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/common.sh"
load_config
[[ "$NODE_ROLE" == data ]] || exit 0

install -d -m 0755 "$INSTALL_ROOT"
install -d -m 0755 "$INSTALL_ROOT/runtime/config"
install -m 0644 "$MUNICIPIO_REPO_ROOT/compose.yaml" "$INSTALL_ROOT/compose.yaml"
install -m 0644 "$MUNICIPIO_REPO_ROOT/compose.swarm.yaml" "$INSTALL_ROOT/compose.swarm.yaml"
install -m 0644 "$MUNICIPIO_REPO_ROOT/runtime/config/content.php" "$INSTALL_ROOT/runtime/config/content.php"
if [[ "$DOCKER_SWARM" == 1 ]]; then
    swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}')"
    if [[ "$swarm_state" == inactive ]]; then
        docker swarm init --advertise-addr "$NODE_ADDRESS"
    fi
    [[ "$(docker info --format '{{.Swarm.ControlAvailable}}')" == true ]] || \
        die 'DOCKER_SWARM=1 requires this VM to be its own Swarm manager'
    [[ "$(docker node ls -q | wc -l | tr -d ' ')" == 1 ]] || \
        die 'This mode supports one independent single-node Swarm per VM only'
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
