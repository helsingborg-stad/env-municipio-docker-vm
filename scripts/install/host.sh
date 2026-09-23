#!/usr/bin/env bash
set -euo pipefail
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/common.sh"
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/platform.sh"
load_config
detect_platform

if [[ "${INSTALL_PACKAGES:-true}" == true ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg debian-keyring debian-archive-keyring apt-transport-https

    if [[ "$NODE_ROLE" == data ]]; then
        data_packages=()
        if ! command -v docker >/dev/null 2>&1 || ! systemctl cat docker.service >/dev/null 2>&1; then
            conflicts=()
            for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
                dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' && conflicts+=("$package")
            done
            ((${#conflicts[@]} == 0)) || die "Remove conflicting Docker packages first: ${conflicts[*]}"
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/${PLATFORM_ID}/gpg" -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
            cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${PLATFORM_ID}
Suites: ${PLATFORM_CODENAME}
Components: stable
Architectures: ${PLATFORM_ARCH}
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
    [[ "$NODE_ROLE" == data ]] && packages+=(idn2 psl)
    if [[ "$DEPLOYMENT_MODE" != standalone ]]; then
        packages+=(glusterfs-server glusterfs-client)
        [[ "$NODE_ROLE" == arbiter ]] && packages+=(galera-arbitrator-4)
    fi
    apt-get install -y "${packages[@]}"
fi

if [[ "$NODE_ROLE" == data ]]; then
    command -v docker >/dev/null 2>&1 || die 'docker is required'
    systemctl cat docker.service >/dev/null 2>&1 || die 'Docker Engine service is missing; the Docker CLI alone is not sufficient'
    systemctl enable --now docker.service || die 'Could not start docker.service; inspect systemctl status docker.service and journalctl -u docker.service'
    docker_ready=false
    for ((attempt = 1; attempt <= 15; attempt++)); do
        if docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
            docker_ready=true
            break
        fi
        sleep 2
    done
    [[ "$docker_ready" == true ]] || die 'Docker daemon is unavailable; inspect systemctl status docker.service and journalctl -u docker.service'
    docker compose version >/dev/null 2>&1 || die 'Docker Compose plugin is required'
    command -v caddy >/dev/null 2>&1 || die 'caddy is required'
    command -v idn2 >/dev/null 2>&1 || die 'idn2 is required for WordPress hostname discovery'
    command -v psl >/dev/null 2>&1 || die 'psl is required for apex-domain detection'
fi

install -d -m 0750 /etc/municipio "${INSTALL_ROOT:-/opt/municipio}" "${BACKUP_ROOT:-/var/backups/municipio}"
if [[ "$(readlink -f "$MUNICIPIO_ENV_FILE")" != /etc/municipio/municipio.env ]]; then
    install -m 0600 "$MUNICIPIO_ENV_FILE" /etc/municipio/municipio.env
else
    chmod 0600 /etc/municipio/municipio.env
fi
log "Host prerequisites installed"
