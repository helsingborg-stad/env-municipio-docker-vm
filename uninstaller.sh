#!/usr/bin/env bash
# Publish this file next to installer.sh. It is self-contained: it removes everything
# the installer set up, without the source bundle. DESTROYS the database, uploads and backups.
# `sudo sh uninstaller.sh` starts it under dash; re-run it under bash before any bash syntax.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -uo pipefail
# Also removes Docker Engine and its data, even if Docker was on the VM before the install,
# and the MariaDB and Caddy packages the earlier host-installed layout put on the VM.
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 [--yes]" >&2; exit 1; }

if [[ "${1:-}" != --yes ]]; then
    echo 'This permanently deletes Municipio, its database, uploads, backups and Docker Engine.'
    echo 'Any MariaDB or Caddy installed directly on this server is removed too, with its data.'
    read -r -p 'Type "yes" to continue: ' answer
    [[ "$answer" == yes ]] || { echo 'Aborted'; exit 1; }
fi

ENV=/etc/municipio/municipio.env
# Read only the path keys; the env file may hold values that are not valid shell.
get() { [[ -r $ENV ]] && sed -n "s/^$1=//p" "$ENV" | tail -1 | tr -d "\"'"; }
for k in INSTALL_ROOT CONFIG_ROOT DATA_ROOT GLUSTER_BRICK BACKUP_ROOT APP_BIND_PORT; do
    v="$(get $k)"; [[ -n $v ]] && printf -v "$k" '%s' "$v"
done
INSTALL_ROOT="${INSTALL_ROOT:-/opt/municipio}"
CONFIG_ROOT="${CONFIG_ROOT:-/etc/municipio}"
DATA_ROOT="${DATA_ROOT:-/srv/municipio/data}"
GLUSTER_BRICK="${GLUSTER_BRICK:-/srv/municipio/gluster-brick}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/municipio}"
PORT="${APP_BIND_PORT:-8080}"

echo '>> Stopping Municipio systemd units'
systemctl disable --now municipio-health.timer municipio-health.service municipio-swarm-firewall.service garb 2>/dev/null
rm -f /etc/systemd/system/municipio-health.{service,timer} /etc/systemd/system/municipio-swarm-firewall.service
systemctl daemon-reload

if command -v docker >/dev/null 2>&1; then
    echo '>> Removing containers, stack, volumes and Swarm'
    docker stack rm municipio 2>/dev/null
    docker rm -f municipio-db municipio-caddy municipio-app 2>/dev/null
    docker swarm leave --force 2>/dev/null
fi

echo '>> Removing Swarm firewall rules'
fwd=(! -i lo -p tcp -m conntrack --ctorigdstport "$PORT" -j DROP)
inp=(! -i lo -p tcp --dport "$PORT" -j DROP)
for ipt in iptables ip6tables; do
    command -v $ipt >/dev/null || continue
    while $ipt -D DOCKER-USER "${fwd[@]}" 2>/dev/null; do :; done
    while $ipt -D INPUT "${inp[@]}" 2>/dev/null; do :; done
done

if command -v gluster >/dev/null 2>&1; then
    echo '>> Removing GlusterFS volume and mount'
    umount -l "$DATA_ROOT" 2>/dev/null
    sed -i "\#[[:space:]]${DATA_ROOT}[[:space:]].*glusterfs#d" /etc/fstab
    gluster --mode=script volume stop municipio force 2>/dev/null
    gluster --mode=script volume delete municipio 2>/dev/null
    systemctl disable --now glusterd 2>/dev/null
fi

# The host-installed layout ran MariaDB and Caddy as distribution services. Left behind,
# they hold ports 3306 and 80/443, which the containers need, and keep the old database.
echo '>> Stopping host-installed MariaDB and Caddy'
systemctl disable --now mariadb caddy 2>/dev/null

echo '>> Removing files and directories'
rm -rf /scripts /usr/local/lib/municipio "$INSTALL_ROOT" "$CONFIG_ROOT" /var/lib/municipio \
    "$DATA_ROOT" "$GLUSTER_BRICK" /srv/municipio "$BACKUP_ROOT" /etc/default/garb /var/log/garb.log
rmdir /srv 2>/dev/null

echo '>> Purging packages (Docker, GlusterFS, Galera, host-installed MariaDB and Caddy)'
export DEBIAN_FRONTEND=noninteractive
# Only installed packages are named: apt-get refuses the whole purge when one name is
# unknown, which caddy is once its repository has been removed.
installed=()
for pkg in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    docker-ce-rootless-extras glusterfs-server glusterfs-client galera-arbitrator-4 \
    mariadb-server mariadb-client mariadb-backup galera-4 caddy; do
    dpkg-query -W -f '${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed' && installed+=("$pkg")
done
((${#installed[@]} == 0)) || apt-get purge -y "${installed[@]}"
rm -rf /var/lib/docker /var/lib/containerd /etc/docker /var/lib/glusterd /etc/glusterfs /var/log/glusterfs
# A noninteractive purge of mariadb-server keeps the databases, so remove them explicitly.
rm -rf /var/lib/mysql /etc/mysql /var/log/mysql /etc/caddy /var/lib/caddy
rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc \
    /etc/apt/sources.list.d/caddy-stable.list /usr/share/keyrings/caddy-stable-archive-keyring.gpg
getent group docker >/dev/null && groupdel docker
apt-get autoremove --purge -y
apt-get update

echo '>> Done. Reboot recommended: sudo reboot'
