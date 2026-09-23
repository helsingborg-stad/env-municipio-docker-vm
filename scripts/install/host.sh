#!/usr/bin/env bash
set -euo pipefail
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/common.sh"
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/platform.sh"
load_config
detect_platform

if [[ "${INSTALL_PACKAGES:-true}" == true ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    if [[ "$NODE_ROLE" == data ]]; then
        # Docker Engine is the only service runtime a data VM needs. MariaDB and Caddy
        # are container images, so no database or web server package is installed here.
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
            apt-get update
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        fi
    fi

    packages=(gzip tar util-linux)
    if [[ "$DEPLOYMENT_MODE" != standalone ]]; then
        # GlusterFS is a kernel/FUSE storage layer rather than an application service,
        # so it stays on the host. See docs/components/storage.md.
        packages+=(glusterfs-server glusterfs-client rsync)
        # The arbitrator is a quorum-only witness host that stores no data and runs no
        # container; garbd is not part of the MariaDB image.
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
fi

install -d -m 0750 "$CONFIG_ROOT" "${INSTALL_ROOT:-/opt/municipio}" "${BACKUP_ROOT:-/var/backups/municipio}"
if [[ "$NODE_ROLE" == data ]]; then
    # The Compose project has to exist before install/database.sh can start MariaDB.
    for file in compose.yaml compose.swarm.yaml compose.galera-bootstrap.yaml; do
        install -m 0644 "$MUNICIPIO_REPO_ROOT/$file" "$INSTALL_ROOT/$file"
    done
fi
if [[ "$(readlink -f "$MUNICIPIO_ENV_FILE")" != "$CONFIG_ROOT/municipio.env" ]]; then
    install -m 0600 "$MUNICIPIO_ENV_FILE" "$CONFIG_ROOT/municipio.env"
else
    chmod 0600 "$CONFIG_ROOT/municipio.env"
fi
log "Host prerequisites installed"
