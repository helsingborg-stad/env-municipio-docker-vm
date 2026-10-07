#!/usr/bin/env bash
set -euo pipefail
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/common.sh"
load_config

install -d -m 0755 /scripts
if [[ "$NODE_ROLE" == arbiter ]]; then
    scripts=(status monitor cluster)
else
    scripts=(update status monitor maintenance backup health cluster failover swarm-firewall refresh-sites change-ip)
fi
for script in "${scripts[@]}"; do
    install -m 0750 "$MUNICIPIO_REPO_ROOT/scripts/${script}.municipio.sh" "/scripts/${script}.municipio.sh"
done
install -d -m 0755 /usr/local/lib/municipio
install -m 0644 "$MUNICIPIO_REPO_ROOT/scripts/lib/common.sh" /usr/local/lib/municipio/common.sh
install -m 0644 "$MUNICIPIO_REPO_ROOT/scripts/lib/build-caddy-sites.sh" /usr/local/lib/municipio/build-caddy-sites.sh

[[ "$NODE_ROLE" == data ]] || exit 0
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
