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

if command -v php >/dev/null 2>&1; then
    php -l runtime/config/content.php
else
    echo 'SKIP: php is not installed'
fi

if docker compose version >/dev/null 2>&1; then
    docker compose --env-file .env.example -f compose.yaml config >/dev/null
    set -a
    # shellcheck disable=SC1091
    source .env.example
    set +a
    docker stack config -c compose.swarm.yaml | grep -q 'mode: global'
    docker stack config -c compose.swarm.yaml | grep -q 'node.labels.municipio.data == true'
else
    echo 'SKIP: docker compose is not installed'
fi

MUNICIPIO_ENV_FILE="$ROOT_DIR/.env.example" bash -c \
    'source scripts/lib/common.sh; load_config; [[ "$DEPLOYMENT_MODE" == standalone ]]'

bad_env="$(mktemp)"
trap 'rm -f "$bad_env"' EXIT
sed 's|^MUNICIPIO_IMAGE=.*$|MUNICIPIO_IMAGE=ghcr.io/municipio-se/municipio-deployment-docker:latest|' \
    .env.example > "$bad_env"
if MUNICIPIO_ENV_FILE="$bad_env" bash -c 'source scripts/lib/common.sh; load_config' >/dev/null 2>&1; then
    echo 'ERROR: mutable image tag passed validation' >&2
    exit 1
fi

echo 'Static checks passed'
