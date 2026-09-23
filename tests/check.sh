#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

while IFS= read -r file; do
    bash -n "$file"
done < <(find bin scripts tests -type f -name '*.sh' -print)
sh -n installer.sh

if command -v shellcheck >/dev/null 2>&1; then
    find bin scripts tests -type f -name '*.sh' -print0 | xargs -0 shellcheck
    shellcheck -s sh installer.sh
else
    echo 'SKIP: shellcheck is not installed'
fi

if docker compose version >/dev/null 2>&1; then
    docker compose --env-file .env.example -f compose.yaml config >/dev/null
    # The Galera bootstrap overlay must merge onto the same project.
    docker compose --env-file .env.example \
        -f compose.yaml -f compose.galera-bootstrap.yaml config | grep -q -- '--wsrep-new-cluster'
    # Every long-running service is a container; nothing is left for the host to install.
    for service in db caddy municipio; do
        docker compose --env-file .env.example -f compose.yaml config --services | grep -qx "$service"
    done
    # `docker stack config` interpolates from the environment, so the example values are
    # sourced inside a subshell. Leaking them into this script would let the negative
    # configuration tests below inherit a value the fixture deliberately removed.
    (
        set -a
        # shellcheck disable=SC1091
        source .env.example
        set +a
        docker stack config -c compose.swarm.yaml | grep -q 'mode: global'
        docker stack config -c compose.swarm.yaml | grep -q 'node.labels.municipio.data == true'
        # Swarm manages the application only; MariaDB and Caddy stay per-VM Compose services.
        if docker stack config -c compose.swarm.yaml | grep -qE '^  (db|caddy):'; then
            echo 'ERROR: compose.swarm.yaml must contain the application service only' >&2
            exit 1
        fi
    )
else
    echo 'SKIP: docker compose is not installed'
fi

# The configuration file is read by bash `source` and by Compose's dotenv parser. A
# password that the two decode differently would create the database account with one
# string and hand the container another, locking the site out of its own database.
if docker compose version >/dev/null 2>&1; then
    quoting_env="$(mktemp)"
    quoting_yaml="$(mktemp -d)/compose.yaml"
    tricky='pa$$w0rd \back #hash;semi&pipe| "dq" a b'
    printf "TRICKY='%s'\n" "$tricky" > "$quoting_env"
    cat > "$quoting_yaml" <<'YML'
services:
  probe:
    image: alpine
    environment:
      VALUE: ${TRICKY}
    command: ["sh", "-c", "printf '%s' \"$$VALUE\""]
YML
    from_bash="$(set -a; # shellcheck disable=SC1090
        source "$quoting_env"; set +a; printf '%s' "$TRICKY")"
    from_compose="$(docker compose --env-file "$quoting_env" -f "$quoting_yaml" run --rm -q probe)"
    rm -f "$quoting_env"
    if [[ "$from_bash" != "$tricky" || "$from_compose" != "$tricky" ]]; then
        echo 'ERROR: bash and Docker Compose disagree on the dotenv encoding' >&2
        printf '  expected: [%s]\n  bash:     [%s]\n  compose:  [%s]\n' \
            "$tricky" "$from_bash" "$from_compose" >&2
        exit 1
    fi
    grep -q "printf \"%s='%s'" bin/interactive-install.sh || {
        echo 'ERROR: the installer no longer single-quotes generated values' >&2
        exit 1
    }
fi

# No component may reintroduce a host-installed database or web server.
if grep -nE 'apt-get install[^|]*\b(mariadb-server|mariadb-client|mariadb-backup|caddy)\b' \
    scripts/install/*.sh; then
    echo 'ERROR: a host database or web server package is being installed' >&2
    exit 1
fi
# Application deployments must never recreate the database container.
if grep -nE 'compose up [^|]*municipio' scripts/*.sh scripts/lib/*.sh | grep -v -- '--no-deps'; then
    echo 'ERROR: an application compose up is missing --no-deps' >&2
    exit 1
fi

MUNICIPIO_ENV_FILE="$ROOT_DIR/.env.example" bash -c \
    'source scripts/lib/common.sh; load_config; [[ "$DEPLOYMENT_MODE" == standalone ]]'

source scripts/lib/platform.sh
for release in 'ubuntu 22.04 jammy' 'ubuntu 24.04 noble' 'ubuntu 26.04 resolute' \
    'debian 12 bookworm' 'debian 13 trixie'; do
    read -r distro version codename <<< "$release"
    platform_supported "$distro" "$version" "$codename" amd64
done
if platform_supported ubuntu 20.04 focal amd64 || \
    platform_supported ubuntu 24.04 noble arm64 || \
    platform_supported debian 13 bookworm amd64; then
    echo 'ERROR: unsupported platform passed validation' >&2
    exit 1
fi
(
    platform_fixture="$(mktemp)"
    trap 'rm -f "$platform_fixture"' EXIT
    printf 'ID=debian\nVERSION_ID=13\nVERSION_CODENAME=trixie\n' > "$platform_fixture"
    detect_platform "$platform_fixture" amd64
    [[ "$PLATFORM_ID" == debian && "$PLATFORM_CODENAME" == trixie && "$PLATFORM_ARCH" == amd64 ]]
)

bad_env="$(mktemp)"
trap 'rm -f "$bad_env"' EXIT

reject_config() {
    local description="$1"
    shift
    "$@" .env.example > "$bad_env"
    if MUNICIPIO_ENV_FILE="$bad_env" bash -c 'source scripts/lib/common.sh; load_config' >/dev/null 2>&1; then
        echo "ERROR: $description passed validation" >&2
        exit 1
    fi
}

reject_config 'a mutable application image tag' \
    sed 's|^MUNICIPIO_IMAGE=.*$|MUNICIPIO_IMAGE=ghcr.io/municipio-se/municipio-deployment-docker:latest|'
reject_config 'a mutable MariaDB image tag' sed 's|^MARIADB_IMAGE=.*$|MARIADB_IMAGE=mariadb:11.4|'
reject_config 'a mutable Caddy image tag' sed 's|^CADDY_IMAGE=.*$|CADDY_IMAGE=caddy:2|'
# The MariaDB data directory on replicated storage corrupts silently, so refuse it early.
reject_config 'a database directory inside DATA_ROOT' \
    sed 's|^DB_DATA_ROOT=.*$|DB_DATA_ROOT=/srv/municipio/data/mysql|'
reject_config 'a database directory inside GLUSTER_BRICK' \
    sed 's|^DB_DATA_ROOT=.*$|DB_DATA_ROOT=/srv/municipio/gluster-brick/mysql|'
reject_config 'a missing database root password' sed 's|^DB_ROOT_PASSWORD=.*$||'

echo 'Static checks passed'
