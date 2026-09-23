#!/usr/bin/env bash

log() { printf '[municipio] %s\n' "$*"; }
die() { printf '[municipio] ERROR: %s\n' "$*" >&2; exit 1; }

load_config() {
    local file="${MUNICIPIO_ENV_FILE:-/etc/municipio/municipio.env}"
    [[ -f "$file" ]] || die "Configuration file not found: $file"
    # The file is root-controlled and intentionally uses shell-compatible dotenv syntax.
    set -a
    # shellcheck disable=SC1090
    source "$file"
    set +a
    export MUNICIPIO_ENV_FILE="$file"
    validate_config
}

required() {
    local name="$1"
    [[ -n "${!name:-}" ]] || die "$name is required"
}

validate_config() {
    : "${DEPLOYMENT_MODE:=standalone}"
    : "${DOCKER_SWARM:=0}"
    : "${NODE_ROLE:=data}"
    : "${INSTALL_ROOT:=/opt/municipio}"
    : "${DATA_ROOT:=/srv/municipio/data}"
    : "${GLUSTER_BRICK:=/srv/municipio/gluster-brick}"
    : "${BACKUP_ROOT:=/var/backups/municipio}"
    : "${HEALTH_ROOT:=/var/lib/municipio/health}"
    export DEPLOYMENT_MODE DOCKER_SWARM NODE_ROLE INSTALL_ROOT DATA_ROOT GLUSTER_BRICK BACKUP_ROOT HEALTH_ROOT
    [[ "$DOCKER_SWARM" == 0 || "$DOCKER_SWARM" == 1 ]] || die "DOCKER_SWARM must be 0 or 1"
    case "$DEPLOYMENT_MODE" in
        standalone|cluster-manual|cluster-arbitrator) ;;
        *) die "DEPLOYMENT_MODE must be standalone, cluster-manual or cluster-arbitrator" ;;
    esac
    case "$NODE_ROLE" in data|arbiter) ;; *) die "NODE_ROLE must be data or arbiter" ;; esac
    required NODE_NAME
    required NODE_ADDRESS
    [[ "$NODE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "NODE_NAME contains unsupported characters"
    [[ "$NODE_ADDRESS" =~ ^[A-Za-z0-9.:-]+$ ]] || die "NODE_ADDRESS contains unsupported characters"
    if [[ "$NODE_ROLE" == data ]]; then
        required MUNICIPIO_IMAGE
        required SITE_ADDRESS
        required DB_NAME
        required DB_USER
        required DB_PASSWORD
        required DATA_ROOT
        [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "DB_NAME may contain only letters, digits and underscore"
        [[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || die "DB_USER may contain only letters, digits and underscore"
        [[ "$DATA_ROOT" == /* && "$DATA_ROOT" != / ]] || die "DATA_ROOT must be an absolute, non-root path"
        [[ "$MUNICIPIO_IMAGE" =~ ^ghcr\.io/municipio-se/municipio-deployment-docker@sha256:[a-f0-9]{64}$ ]] || \
            die "MUNICIPIO_IMAGE must use the approved repository and an exact sha256 digest"
        [[ "$SITE_ADDRESS" =~ ^[A-Za-z0-9.:-]+$ ]] || die "SITE_ADDRESS contains unsupported characters"
        [[ "${CADDY_SITE_ADDRESS:-$SITE_ADDRESS}" =~ ^[A-Za-z0-9.:-]+$ ]] || die "CADDY_SITE_ADDRESS contains unsupported characters"
    fi
    if [[ "$DEPLOYMENT_MODE" != standalone ]]; then
        required GLUSTER_BRICK
        required PRIMARY_NODE_NAME
        required PRIMARY_NODE_ADDRESS
        required SECONDARY_NODE_NAME
        required SECONDARY_NODE_ADDRESS
        for value in "$PRIMARY_NODE_NAME" "$PRIMARY_NODE_ADDRESS" "$SECONDARY_NODE_NAME" "$SECONDARY_NODE_ADDRESS"; do
            [[ "$value" =~ ^[A-Za-z0-9._:-]+$ ]] || die "Cluster node values contain unsupported characters"
        done
    fi
    if [[ "$DEPLOYMENT_MODE" == cluster-arbitrator ]]; then
        required ARBITRATOR_NODE_NAME
        required ARBITRATOR_NODE_ADDRESS
        [[ "$ARBITRATOR_NODE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "ARBITRATOR_NODE_NAME contains unsupported characters"
        [[ "$ARBITRATOR_NODE_ADDRESS" =~ ^[A-Za-z0-9.:-]+$ ]] || die "ARBITRATOR_NODE_ADDRESS contains unsupported characters"
    fi
}

compose() {
    docker compose --env-file "$MUNICIPIO_ENV_FILE" \
        -f "${INSTALL_ROOT:-/opt/municipio}/compose.yaml" "$@"
}

swarm_service_name() { printf 'municipio_municipio'; }

swarm_is_manager() {
    [[ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)" == true ]]
}

deploy_application() {
    if [[ "$DOCKER_SWARM" == 1 ]]; then
        swarm_is_manager || die 'Deploy from the Swarm manager'
        docker stack deploy --with-registry-auth \
            -c "${INSTALL_ROOT:-/opt/municipio}/compose.swarm.yaml" municipio
    else
        compose up -d --wait municipio
    fi
}

wait_for_application() {
    local deadline=$((SECONDS + 180)) service expected running
    if [[ "$DOCKER_SWARM" == 1 ]]; then
        swarm_is_manager || die 'Check the service from the Swarm manager'
        service="$(swarm_service_name)"
        until {
            expected="$(docker node ls --filter node.label=municipio.data=true --format '{{.ID}}' 2>/dev/null | wc -l | tr -d ' ')"
            running="$(docker service ps --filter desired-state=running --format '{{.CurrentState}}' "$service" 2>/dev/null | grep -c '^Running' || true)"
            [[ "$expected" -gt 0 && "$running" -eq "$expected" ]] \
                && [[ "$(docker service inspect -f '{{.Spec.TaskTemplate.ContainerSpec.Image}}' "$service" 2>/dev/null || true)" == "$MUNICIPIO_IMAGE" ]] \
                && curl -fsS -o /dev/null "http://127.0.0.1:${APP_BIND_PORT:-8080}/"
        }; do
            if ((SECONDS >= deadline)); then
                log "Timed out waiting for Swarm service $service"
                return 1
            fi
            sleep 3
        done
    fi
}

sql_escape() {
    local value="${1//\\/\\\\}"
    printf '%s' "${value//\'/\'\'}"
}
