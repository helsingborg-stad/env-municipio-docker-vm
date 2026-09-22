#!/usr/bin/env bash
set -euo pipefail
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/common.sh"
load_config

source /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || \
    die 'This version supports Ubuntu Server 24.04 LTS only'
[[ "$(dpkg --print-architecture)" == amd64 ]] || \
    die 'The selected Municipio image requires amd64'

if [[ "${INSTALL_PACKAGES:-true}" == true ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg debian-keyring debian-archive-keyring apt-transport-https

    if [[ "$NODE_ROLE" == data ]]; then
        data_packages=()
        if ! command -v docker >/dev/null 2>&1; then
            conflicts=()
            for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
                dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' && conflicts+=("$package")
            done
            ((${#conflicts[@]} == 0)) || die "Remove conflicting Docker packages first: ${conflicts[*]}"
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
            cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
            data_packages+=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
        fi

        if ! command -v caddy >/dev/null 2>&1; then
            curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | \
                gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
                -o /etc/apt/sources.list.d/caddy-stable.list
            chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
            data_packages+=(caddy)
        fi
        if ((${#data_packages[@]})); then
            apt-get update
            apt-get install -y "${data_packages[@]}"
        fi
    fi
    packages=(rsync mariadb-client gzip tar util-linux)
    if [[ "$DEPLOYMENT_MODE" != standalone ]]; then
        packages+=(glusterfs-server glusterfs-client)
        [[ "$NODE_ROLE" == arbiter ]] && packages+=(galera-arbitrator-4)
    fi
    apt-get install -y "${packages[@]}"
fi

if [[ "$NODE_ROLE" == data ]]; then
    command -v docker >/dev/null 2>&1 || die 'docker is required'
    docker compose version >/dev/null 2>&1 || die 'Docker Compose plugin is required'
    command -v caddy >/dev/null 2>&1 || die 'caddy is required'
fi

install -d -m 0750 /etc/municipio "${INSTALL_ROOT:-/opt/municipio}" "${BACKUP_ROOT:-/var/backups/municipio}"
if [[ "$(readlink -f "$MUNICIPIO_ENV_FILE")" != /etc/municipio/municipio.env ]]; then
    install -m 0600 "$MUNICIPIO_ENV_FILE" /etc/municipio/municipio.env
else
    chmod 0600 /etc/municipio/municipio.env
fi
log "Host prerequisites installed"
