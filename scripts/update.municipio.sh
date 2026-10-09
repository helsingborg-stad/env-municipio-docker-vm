#!/usr/bin/env bash
set -euo pipefail
# Installed by install/maintenance.sh; the repository copy is scripts/lib/common.sh.
# shellcheck disable=SC1091
source /usr/local/lib/municipio/common.sh
load_config

usage() {
    cat >&2 <<'EOF'
Usage: update.municipio.sh [municipio [VERSION]]

Updates the Municipio application container. VERSION defaults to latest; it may be
any published Municipio image tag, for example 1.2.3 or latest. The pulled tag is
resolved to an immutable digest before deployment.
EOF
    exit 2
}

image_repository='ghcr.io/municipio-se/municipio-deployment-docker'
target="${1:-municipio}"
version="${2:-latest}"
if (($# == 1)) && [[ "$1" =~ ^${image_repository}@sha256:[a-f0-9]{64}$ ]]; then
    # Compatibility with the previous, digest-only command form.
    target=municipio
    new_image="$1"
elif (($# > 2)); then
    usage
else
    case "$target" in
        municipio|app) ;;
        *) die "Unsupported container '$target'. Only municipio is updateable by this command." ;;
    esac
    [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'VERSION must be an image tag such as latest or 1.2.3'
    requested_image="${image_repository}:${version}"
    log "Pulling Municipio image ${requested_image}"
    docker pull -q "$requested_image"
    new_image="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$requested_image" | \
        awk -v repository="$image_repository" '$0 ~ "^" repository "@sha256:[a-f0-9]{64}$" { print; exit }')"
    [[ "$new_image" =~ ^${image_repository}@sha256:[a-f0-9]{64}$ ]] || \
        die "Could not resolve ${requested_image} to an immutable digest"
fi

exec 9>/run/lock/municipio-update.lock
flock -n 9 || die 'Another update is running'
log "Deploying Municipio image ${new_image}"
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
# Single-quoted to match the encoding the installer writes: the file is parsed both by
# bash and by Docker Compose, which disagree on backslash escapes.
sed "s|^MUNICIPIO_IMAGE=.*\$|MUNICIPIO_IMAGE='${new_image}'|" "$MUNICIPIO_ENV_FILE" > "$tmp_env"
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
        sed "s|^MUNICIPIO_IMAGE=.*\$|MUNICIPIO_IMAGE='${old_image}'|" "$MUNICIPIO_ENV_FILE" > "$tmp_env"
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

/scripts/refresh-sites.municipio.sh

if [[ "$DEPLOYMENT_MODE" == standalone ]]; then
    find "${DATA_ROOT:?}/cache" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
else
    log 'Shared cache was not cleared; clear it once after every node runs the same digest'
fi
if [[ "$DOCKER_SWARM" == 0 ]]; then
    /scripts/maintenance.municipio.sh off
fi
echo "updated=${new_image}"
