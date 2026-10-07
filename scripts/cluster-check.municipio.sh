#!/usr/bin/env bash
set -uo pipefail
# Installed by install/maintenance.sh; the repository copy is scripts/lib/common.sh.
# shellcheck disable=SC1091
source /usr/local/lib/municipio/common.sh

# Read-only cluster report for a cluster-manual data VM. It changes nothing: it collects
# the network, cloud-init, Galera, Gluster, health and firewall state into one log file
# and ends with a summary. Run it on both data VMs.

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }
load_config
[[ "$NODE_ROLE" == data && "$DEPLOYMENT_MODE" != standalone ]] || \
    die 'This script is for the data VMs of a cluster installation'

LOG="/var/log/municipio-cluster-check-$(hostname)-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee "$LOG") 2>&1

if [[ "$NODE_NAME" == "$PRIMARY_NODE_NAME" ]]; then
    SELF="$PRIMARY_NODE_ADDRESS" PEER="$SECONDARY_NODE_ADDRESS" PEER_NAME="$SECONDARY_NODE_NAME"
else
    SELF="$SECONDARY_NODE_ADDRESS" PEER="$PRIMARY_NODE_ADDRESS" PEER_NAME="$PRIMARY_NODE_NAME"
fi

SUMMARY=()
result() { SUMMARY+=("$(printf '%-5s %s' "$1" "$2")"); }
section() { printf '\n===== %s =====\n' "$*"; }
show() { printf '$ %s\n' "$*"; "$@" 2>&1; printf '(exit %s)\n' "$?"; }
db_value() { db_container >/dev/null 2>&1 && db_status_value "$1" 2>/dev/null; }
tcp_open() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

section "$NODE_NAME ($SELF), peer $PEER_NAME ($PEER), $(date -Is)"

section 'Network and cloud-init'
show ip -br -4 addr
show grep -rn -A1 'addresses:' /etc/netplan/
if grep -rqsF "$SELF" /etc/netplan/; then
    result OK "netplan configures $SELF"
else
    result FAIL "netplan does not mention $SELF"
fi
if grep -rqs 'config: disabled' /etc/cloud/cloud.cfg.d/; then
    result OK 'cloud-init network configuration disabled'
else
    result WARN 'cloud-init network configuration not disabled'
fi

section 'Galera'
status="$(db_value wsrep_cluster_status)" size="$(db_value wsrep_cluster_size)"
state="$(db_value wsrep_local_state_comment)"
echo "status=$status size=$size state=$state"
if [[ "$status" == Primary && "$size" == 2 && "$state" == Synced ]]; then
    result OK 'Galera Primary, size 2, Synced'
else
    result FAIL "Galera status=$status size=$size state=$state"
fi
if [[ -f "$(galera_bootstrap_marker)" ]]; then
    result WARN 'Galera bootstrap flag is still set'
else
    result OK 'Galera bootstrap flag cleared'
fi

section 'Gluster'
show timeout 10 gluster peer status
show timeout 15 gluster volume status municipio
show timeout 15 gluster volume heal municipio info summary
if timeout 10 gluster peer status 2>/dev/null | grep -q 'Peer in Cluster (Connected)'; then
    result OK "Gluster peer $PEER_NAME connected"
else
    result FAIL "Gluster peer $PEER_NAME not connected"
fi
bricks="$(timeout 15 gluster volume status municipio --xml 2>/dev/null | awk '
    /<node>/ {p = ""; s = ""}
    /<path>/ {gsub(/.*<path>|<\/path>.*/, ""); p = $0}
    /<status>/ {gsub(/.*<status>|<\/status>.*/, ""); s = $0}
    /<\/node>/ {if (p ~ /^\//) {n++; if (s == 1) up++}}
    END {print up + 0 "/" n + 0}')"
if [[ "$bricks" == 2/2 ]]; then
    result OK 'Gluster bricks online 2/2'
else
    result FAIL "Gluster bricks online $bricks"
fi
if findmnt -no OPTIONS --target "$DATA_ROOT" 2>/dev/null | tr ',' '\n' | grep -qx rw && mountpoint -q "$DATA_ROOT"; then
    result OK "$DATA_ROOT mounted read-write"
else
    result FAIL "$DATA_ROOT not mounted read-write"
fi

section 'Health'
show docker ps --format '{{.Names}} {{.Status}}'
show ls -l "$HEALTH_ROOT/healthz"
if [[ -f "$HEALTH_ROOT/healthz" ]]; then
    result OK 'health marker present'
else
    result FAIL 'health marker missing'
fi
denied="$(docker logs --since 60s municipio-db 2>&1 | grep -c 'Access denied')"
echo "Access denied lines in the last 60 s: $denied"
if [[ "$denied" == 0 ]]; then
    result OK 'no denied MariaDB logins'
else
    result WARN "$denied denied MariaDB logins in the last 60 s"
fi

section 'Cluster ports'
show sh -c "ss -ltnup | grep -E 'mariadbd|gluster'"
for port in 4567 24007; do
    if tcp_open "$PEER" "$port"; then
        result OK "peer $PEER_NAME reachable on $port"
    else
        result FAIL "peer $PEER_NAME not reachable on $port"
    fi
done
# Anything listening on all addresses is reachable on the public address unless a
# firewall in front of the VM blocks it.
public="$(ss -ltnH | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):(4444|4567|4568|2400[78]|49[0-9]{3}|5[0-9]{4}|60[0-9]{3})$' | sort -u | tr '\n' ' ')"
if [[ -n "$public" ]]; then
    result WARN "cluster ports listening on all addresses: $public"
fi

section 'Firewall'
show systemctl is-enabled nftables
show systemctl is-active nftables
show sh -c 'ls -l /etc/nftables.conf /etc/nftables.d 2>/dev/null'
show sh -c 'grep -rlsE "kriswebb" /etc 2>/dev/null'
show nft list ruleset
if nft list ruleset 2>/dev/null | grep -A20 'hook input' | grep -qE 'dport.*(4567|24007)'; then
    result OK 'host firewall filters cluster ports'
else
    result WARN 'no host firewall rule filters the cluster ports'
fi

section "SUMMARY $NODE_NAME"
printf '%s\n' "${SUMMARY[@]}"
echo
echo "Log: $LOG"
