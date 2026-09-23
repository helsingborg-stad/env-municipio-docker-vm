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

grep -Fq 'packages+=(idn2 psl)' scripts/install/host.sh || {
    echo 'ERROR: host installer must auto-install idn2 and psl on data VMs' >&2
    exit 1
}

if command -v psl >/dev/null 2>&1; then
    if ! command -v idn2 >/dev/null 2>&1 || ! idn2 --version >/dev/null 2>&1; then
        # This macOS test host has an incompatible idn2 binary; Linux uses the real command.
        idn2() {
            local value="${*: -1}"
            case "$value" in
                bücher.se) printf 'xn--bcher-kva.se\n' ;;
                *) printf '%s\n' "$value" ;;
            esac
        }
        export -f idn2
    fi
    site_list="$(printf 'example.co.uk\nblog.example.co.uk\nbücher.se\n' | \
        bash scripts/lib/build-caddy-sites.sh --http-only)"
    [[ "$site_list" == *'http://www.example.co.uk {'* ]]
    [[ "$site_list" == *'http://www.xn--bcher-kva.se {'* ]]
    [[ "$site_list" != *'www.blog.example.co.uk'* ]]
    [[ "$(psl --print-reg-domain example.co.uk)" == 'example.co.uk: example.co.uk' ]]
    [[ "$(psl --print-reg-domain blog.example.co.uk)" == 'blog.example.co.uk: example.co.uk' ]]
    for invalid in 'https://example.com:444' 'foo.com {' '127.0.0.1' 'foo.com/bar'; do
        if printf '%s\n' "$invalid" | bash scripts/lib/build-caddy-sites.sh >/dev/null 2>&1; then
            echo "ERROR: accepted invalid hostname: $invalid" >&2
            exit 1
        fi
    done
    if declare -F idn2 >/dev/null; then unset -f idn2; fi
else
    echo 'SKIP: psl is not installed; Caddy host generation tests need psl'
fi

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
sed 's|^MUNICIPIO_IMAGE=.*$|MUNICIPIO_IMAGE=ghcr.io/municipio-se/municipio-deployment-docker:latest|' \
    .env.example > "$bad_env"
if MUNICIPIO_ENV_FILE="$bad_env" bash -c 'source scripts/lib/common.sh; load_config' >/dev/null 2>&1; then
    echo 'ERROR: mutable image tag passed validation' >&2
    exit 1
fi

echo 'Static checks passed'
