#!/usr/bin/env bash
set -euo pipefail
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/common.sh"
load_config

install -d -m 0755 /scripts
for script in update status maintenance backup health cluster failover swarm-firewall refresh-sites; do
install -m 0750 "$MUNICIPIO_REPO_ROOT/scripts/${script}.municipio.sh" "/scripts/${script}.municipio.sh"
done
# These installer-owned commands belonged to the previous single-domain workflow.
rm -f /scripts/change-domain.municipio.sh /scripts/configure-proxy.municipio.sh
install -d -m 0755 /usr/local/lib/municipio
install -m 0644 "$MUNICIPIO_REPO_ROOT/scripts/lib/common.sh" /usr/local/lib/municipio/common.sh
install -m 0644 "$MUNICIPIO_REPO_ROOT/scripts/lib/build-caddy-sites.sh" /usr/local/lib/municipio/build-caddy-sites.sh
rm -f /usr/local/lib/municipio/build-caddy-sites.py

[[ "$NODE_ROLE" == data ]] || exit 0
if [[ "$DOCKER_SWARM" == 1 ]]; then
    install -m 0644 "$MUNICIPIO_REPO_ROOT/systemd/municipio-swarm-firewall.service" /etc/systemd/system/
fi
install -m 0644 "$MUNICIPIO_REPO_ROOT/systemd/municipio-health.service" /etc/systemd/system/
install -m 0644 "$MUNICIPIO_REPO_ROOT/systemd/municipio-health.timer" /etc/systemd/system/
install -m 0644 "$MUNICIPIO_REPO_ROOT/systemd/municipio-sites.service" /etc/systemd/system/
install -m 0644 "$MUNICIPIO_REPO_ROOT/systemd/municipio-sites.timer" /etc/systemd/system/
systemctl daemon-reload
if [[ "$DOCKER_SWARM" == 1 ]]; then
    systemctl enable --now municipio-swarm-firewall.service
fi
systemctl enable --now municipio-health.timer
systemctl enable --now municipio-sites.timer
