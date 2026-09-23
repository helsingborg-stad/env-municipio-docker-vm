#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/municipio/common.sh
load_config

new_image="${1:-$MUNICIPIO_IMAGE}"
[[ "$new_image" =~ ^ghcr\.io/municipio-se/municipio-deployment-docker@sha256:[a-f0-9]{64}$ ]] || {
    echo 'Update requires a digest-pinned ghcr.io Municipio image' >&2
    exit 2
}

exec 9>/run/lock/municipio-update.lock
flock -n 9 || die 'Another update is running'
if [[ "$DOCKER_SWARM" == 1 ]]; then
    swarm_is_manager || die 'Run the Swarm update on the manager'
else
    /scripts/maintenance.municipio.sh on
fi
/scripts/backup.municipio.sh pre-update

if [[ "$DOCKER_SWARM" == 1 ]]; then
    old_image="$(docker service inspect -f '{{.Spec.TaskTemplate.ContainerSpec.Image}}' "$(swarm_service_name)" 2>/dev/null || true)"
else
    old_image="$(docker inspect -f '{{.Config.Image}}' municipio-app 2>/dev/null || true)"
fi
tmp_env="$(mktemp)"
trap 'rm -f "$tmp_env"' EXIT
sed "s|^MUNICIPIO_IMAGE=.*$|MUNICIPIO_IMAGE=${new_image}|" "$MUNICIPIO_ENV_FILE" > "$tmp_env"
install -m 0600 "$tmp_env" "$MUNICIPIO_ENV_FILE"
export MUNICIPIO_IMAGE="$new_image"

update_ok=true
if [[ "$DOCKER_SWARM" == 1 ]]; then
    deploy_application || update_ok=false
    [[ "$update_ok" == false ]] || wait_for_application || update_ok=false
else
    compose pull municipio || update_ok=false
    [[ "$update_ok" == false ]] || compose up -d --no-deps --wait municipio || update_ok=false
fi

if [[ "$update_ok" == false ]]; then
    if [[ -n "$old_image" ]]; then
        sed "s|^MUNICIPIO_IMAGE=.*$|MUNICIPIO_IMAGE=${old_image}|" "$MUNICIPIO_ENV_FILE" > "$tmp_env"
        install -m 0600 "$tmp_env" "$MUNICIPIO_ENV_FILE"
        export MUNICIPIO_IMAGE="$old_image"
        if [[ "$DOCKER_SWARM" == 1 ]]; then
            deploy_application || true
        else
            compose up -d --no-deps municipio || true
        fi
    fi
    die 'Update failed; previous image was restored where possible'
fi

if [[ "$DEPLOYMENT_MODE" == standalone ]]; then
    find "${DATA_ROOT:?}/cache" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
else
    log 'Shared cache was not cleared; clear it once after every node runs the same digest'
fi
if [[ "$DOCKER_SWARM" == 0 ]]; then
    /scripts/maintenance.municipio.sh off
fi
echo "updated=${new_image}"
