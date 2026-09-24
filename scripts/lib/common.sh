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

# Every service runs from an immutable release. A tag would let two nodes run different
# code with the same configuration, which Galera and the shared cache cannot tolerate.
require_digest() {
    local name="$1"
    [[ "${!name}" =~ ^[A-Za-z0-9._/-]+@sha256:[a-f0-9]{64}$ ]] || \
        die "$name must be pinned to an exact sha256 digest"
}

validate_config() {
    : "${DEPLOYMENT_MODE:=standalone}"
    : "${DOCKER_SWARM:=0}"
    : "${NODE_ROLE:=data}"
    : "${INSTALL_ROOT:=/opt/municipio}"
    : "${CONFIG_ROOT:=/etc/municipio}"
    : "${DATA_ROOT:=/srv/municipio/data}"
    : "${GLUSTER_BRICK:=/srv/municipio/gluster-brick}"
    : "${BACKUP_ROOT:=/var/backups/municipio}"
    : "${HEALTH_ROOT:=/var/lib/municipio/health}"
    : "${DB_DATA_ROOT:=/var/lib/municipio/mysql}"
    : "${DB_SOCKET_DIR:=/var/lib/municipio/mysqld-socket}"
    : "${DB_SOCKET_UID:=999}"
    : "${DB_SOCKET_GID:=999}"
    export DEPLOYMENT_MODE DOCKER_SWARM NODE_ROLE INSTALL_ROOT CONFIG_ROOT DATA_ROOT \
        GLUSTER_BRICK BACKUP_ROOT HEALTH_ROOT DB_DATA_ROOT DB_SOCKET_DIR \
        DB_SOCKET_UID DB_SOCKET_GID
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
        required MARIADB_IMAGE
        required CADDY_IMAGE
        required SITE_ADDRESS
        required DB_NAME
        required DB_USER
        required DB_PASSWORD
        required DB_ROOT_PASSWORD
        required DATA_ROOT
        required DB_DATA_ROOT
        required DB_SOCKET_DIR
        [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "DB_NAME may contain only letters, digits and underscore"
        [[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || die "DB_USER may contain only letters, digits and underscore"
        [[ "$DB_SOCKET_UID" =~ ^[0-9]+$ && "$DB_SOCKET_GID" =~ ^[0-9]+$ ]] || \
            die "DB_SOCKET_UID and DB_SOCKET_GID must be numeric"
        for path_name in DATA_ROOT DB_DATA_ROOT DB_SOCKET_DIR; do
            [[ "${!path_name}" == /* && "${!path_name}" != / ]] || \
                die "$path_name must be an absolute, non-root path"
        done
        # The database directory must stay on this VM's own disk. On a cluster node
        # DATA_ROOT is the replicated Gluster view, and a MariaDB data directory on a
        # replicated filesystem corrupts silently.
        for forbidden in "$DATA_ROOT" "$GLUSTER_BRICK"; do
            [[ "$DB_DATA_ROOT" != "$forbidden" && "$DB_DATA_ROOT" != "$forbidden"/* ]] || \
                die "DB_DATA_ROOT must not be inside $forbidden; the MariaDB data directory must never be placed on replicated storage"
        done
        [[ "$MUNICIPIO_IMAGE" =~ ^ghcr\.io/municipio-se/municipio-deployment-docker@sha256:[a-f0-9]{64}$ ]] || \
            die "MUNICIPIO_IMAGE must use the approved repository and an exact sha256 digest"
        require_digest MARIADB_IMAGE
        require_digest CADDY_IMAGE
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

# -p is explicit: Compose would otherwise derive the project name from the file's
# directory, and the maintenance scripts run from whatever directory the operator
# happens to be in. A different name would resolve no containers on a healthy node.
compose() {
    docker compose -p municipio --env-file "$MUNICIPIO_ENV_FILE" \
        -f "${INSTALL_ROOT:-/opt/municipio}/compose.yaml" "$@"
}

# Same project, plus the overlay that makes MariaDB form a new Galera primary component.
compose_galera_bootstrap() {
    docker compose -p municipio --env-file "$MUNICIPIO_ENV_FILE" \
        -f "${INSTALL_ROOT:-/opt/municipio}/compose.yaml" \
        -f "${INSTALL_ROOT:-/opt/municipio}/compose.galera-bootstrap.yaml" "$@"
}

galera_bootstrap_marker() { printf '%s/galera-bootstrap-active' "${CONFIG_ROOT:-/etc/municipio}"; }

swarm_service_name() { printf 'municipio_municipio'; }

swarm_is_manager() {
    [[ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)" == true ]]
}

# Resolves the local MariaDB container once, so that "the database is not running" and
# "the database answered something unexpected" never share an exit path. Callers such as
# health.municipio.sh depend on that distinction.
db_container() {
    local id
    id="$(compose ps -q db 2>/dev/null || true)"
    [[ -n "$id" ]] || return 1
    # Compose versions differ on whether `ps -q` lists stopped containers. Without this,
    # a stopped container would reach `docker exec` and fail with its own error instead
    # of the distinct message callers rely on.
    [[ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null)" == true ]] || return 1
    printf '%s' "$id"
}

container_running() {
    local id
    id="$(compose ps -q "$1" 2>/dev/null || true)"
    [[ -n "$id" ]] || return 1
    [[ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null)" == true ]]
}

db_exec() {
    local id
    id="$(db_container)" || die 'MariaDB container is not running (Compose service: db)'
    docker exec -i "$id" "$@"
}

# Administrative access. The password is passed through the exec environment rather than
# the command line so that it never appears in the container's process list.
db_root() {
    local id
    id="$(db_container)" || die 'MariaDB container is not running (Compose service: db)'
    docker exec -i -e MYSQL_PWD="$DB_ROOT_PASSWORD" "$id" "$@"
}

db_root_sql() { db_root mariadb -uroot; }

db_status_value() {
    db_root mariadb -uroot --batch --skip-column-names \
        -e "SHOW STATUS LIKE '$1'" | awk '{print $2}'
}

start_database() { compose up -d --no-deps db; }
start_proxy() { compose up -d --no-deps caddy; }

# The same probe as the db healthcheck in compose.yaml. It logs in as root rather than
# running the image's healthcheck.sh, whose 'healthcheck' account has a password each
# container generates for itself: a Galera state transfer replaces the joiner's privilege
# tables with the donor's but keeps the joiner's credential file, so that probe fails
# forever on every node that joined. DB_ROOT_PASSWORD is identical on both data VMs.
database_ready() {
    [[ "$(docker exec -e MYSQL_PWD="$DB_ROOT_PASSWORD" "$1" mariadb -uroot --batch --skip-column-names \
        -e "SELECT 1 FROM information_schema.ENGINES WHERE engine='InnoDB' AND support IN ('YES','DEFAULT')" 2>/dev/null)" == 1 ]]
}

# Standalone starts in under a minute. A cluster joiner may need a full state transfer
# from the donor first, which is why the caller chooses the timeout.
wait_for_database() {
    local timeout="${1:-180}"
    local deadline=$((SECONDS + timeout)) id
    while true; do
        id="$(db_container 2>/dev/null || true)"
        if [[ -n "$id" ]] && database_ready "$id"; then
            return 0
        fi
        if ((SECONDS >= deadline)); then
            log "Timed out after ${timeout}s waiting for MariaDB to accept connections"
            return 1
        fi
        sleep 3
    done
}

deploy_application() {
    if [[ "$DOCKER_SWARM" == 1 ]]; then
        swarm_is_manager || die 'Deploy from the Swarm manager'
        docker stack deploy --with-registry-auth \
            -c "${INSTALL_ROOT:-/opt/municipio}/compose.swarm.yaml" municipio
    else
        # --no-deps keeps an application deployment from recreating the database
        # container, which would drop a Galera bootstrap flag or interrupt replication.
        compose up -d --no-deps --wait municipio
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

# The socket and data directories are created on the host before the container exists,
# so their ownership is a guess until the image can be asked. A mismatch leaves MariaDB
# unable to create its socket, which would surface much later as a database-less site.
verify_socket_ownership() {
    local image_uid image_gid
    image_uid="$(db_exec id -u mysql | tr -d '\r')"
    image_gid="$(db_exec id -g mysql | tr -d '\r')"
    [[ "$image_uid" == "$DB_SOCKET_UID" && "$image_gid" == "$DB_SOCKET_GID" ]] || \
        die "MARIADB_IMAGE runs MariaDB as ${image_uid}:${image_gid}, but DB_SOCKET_UID/DB_SOCKET_GID are ${DB_SOCKET_UID}:${DB_SOCKET_GID}. Correct them and reinstall."
    [[ -S "$DB_SOCKET_DIR/mysqld.sock" ]] || \
        die "MariaDB did not create a socket in $DB_SOCKET_DIR; the application cannot reach the database"
}

provision_database() {
    local escaped_name escaped_user escaped_password
    escaped_name="$(sql_escape "$DB_NAME")"
    escaped_user="$(sql_escape "$DB_USER")"
    escaped_password="$(sql_escape "$DB_PASSWORD")"
    # The application connects through the shared Unix socket, so its grants stay
    # scoped to 'localhost'. No database account is reachable over the network.
    db_root_sql <<SQL
CREATE DATABASE IF NOT EXISTS \`${escaped_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${escaped_user}'@'localhost' IDENTIFIED BY '${escaped_password}';
ALTER USER '${escaped_user}'@'localhost' IDENTIFIED BY '${escaped_password}';
GRANT ALL PRIVILEGES ON \`${escaped_name}\`.* TO '${escaped_user}'@'localhost';
FLUSH PRIVILEGES;
SQL
}
