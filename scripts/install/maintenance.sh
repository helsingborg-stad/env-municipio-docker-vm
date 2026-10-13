#!/usr/bin/env bash
set -euo pipefail
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/common.sh"
load_config

install -d -m 0755 /scripts
if [[ "$NODE_ROLE" == arbiter ]]; then
    scripts=(status monitor cluster)
else
    scripts=(update status monitor maintenance backup health cluster failover swarm-firewall refresh-sites change-ip change-domain wait-for-gluster-brick)
fi
for script in "${scripts[@]}"; do
    install -m 0750 "$MUNICIPIO_REPO_ROOT/scripts/${script}.municipio.sh" "/scripts/${script}.municipio.sh"
done
install -d -m 0755 /usr/local/lib/municipio
install -m 0644 "$MUNICIPIO_REPO_ROOT/scripts/lib/common.sh" /usr/local/lib/municipio/common.sh
install -m 0644 "$MUNICIPIO_REPO_ROOT/scripts/lib/build-caddy-sites.sh" /usr/local/lib/municipio/build-caddy-sites.sh

[[ "$NODE_ROLE" == data ]] || exit 0
if [[ "$DEPLOYMENT_MODE" != standalone ]]; then
    install -m 0644 "$MUNICIPIO_REPO_ROOT/systemd/municipio-gluster-brick.service" /etc/systemd/system/
    install -d -m 0755 /etc/systemd/system/docker.service.d
    data_mount_unit="$(systemd-escape --path --suffix=mount "$DATA_ROOT")"
    docker_mount_dropin="$(<"$MUNICIPIO_REPO_ROOT/systemd/docker-municipio-data-mount.conf.in")"
    docker_mount_dropin="${docker_mount_dropin//@DATA_MOUNT_UNIT@/$data_mount_unit}"
    printf '%s\n' "$docker_mount_dropin" > /etc/systemd/system/docker.service.d/municipio-data-mount.conf
    chmod 0644 /etc/systemd/system/docker.service.d/municipio-data-mount.conf

    # Existing installations already have this fstab entry.  Rewrite it during
    # an installer update as well as in cluster.municipio.sh, otherwise the
    # new ordering only takes effect after somebody happens to re-run join.
    if [[ "$NODE_NAME" == "$PRIMARY_NODE_NAME" ]]; then
        backup_server="$SECONDARY_NODE_ADDRESS"
    else
        backup_server="$PRIMARY_NODE_ADDRESS"
    fi
    fstab_line="localhost:/municipio ${DATA_ROOT} glusterfs defaults,_netdev,backupvolfile-server=${backup_server},x-systemd.requires=municipio-gluster-brick.service 0 0"
    fstab_data_root="${DATA_ROOT//\//\\/}"
    if grep -qE "^[^#]+[[:space:]]+${fstab_data_root}[[:space:]].*glusterfs" /etc/fstab; then
        sed -i "\#^[^#].*[[:space:]]${fstab_data_root}[[:space:]].*glusterfs#c\\${fstab_line}" /etc/fstab
    fi
fi
if [[ "$DOCKER_SWARM" == 1 ]]; then
    install -m 0644 "$MUNICIPIO_REPO_ROOT/systemd/municipio-swarm-firewall.service" /etc/systemd/system/
fi
install -m 0644 "$MUNICIPIO_REPO_ROOT/systemd/municipio-health.service" /etc/systemd/system/
install -m 0644 "$MUNICIPIO_REPO_ROOT/systemd/municipio-health.timer" /etc/systemd/system/
install -m 0644 "$MUNICIPIO_REPO_ROOT/systemd/municipio-sites.service" /etc/systemd/system/
install -m 0644 "$MUNICIPIO_REPO_ROOT/systemd/municipio-sites.timer" /etc/systemd/system/
caddy_unit="$(<"$MUNICIPIO_REPO_ROOT/systemd/municipio-caddy.service.in")"
caddy_unit="${caddy_unit//@CADDY_DATA_ROOT@/$DATA_ROOT/caddy}"
printf '%s\n' "$caddy_unit" > /etc/systemd/system/municipio-caddy.service
chmod 0644 /etc/systemd/system/municipio-caddy.service
systemctl daemon-reload
if [[ "$DOCKER_SWARM" == 1 ]]; then
    systemctl enable --now municipio-swarm-firewall.service
fi
systemctl enable --now municipio-health.timer
systemctl enable --now municipio-sites.timer
systemctl enable municipio-caddy.service
