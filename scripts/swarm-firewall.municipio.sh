#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/municipio/common.sh
load_config
[[ "$DOCKER_SWARM" == 1 ]] || exit 0

port="${APP_BIND_PORT:-8080}"
rule=(-p tcp --dport "$port" ! -i lo -j DROP)
iptables -C DOCKER-USER "${rule[@]}" 2>/dev/null || iptables -I DOCKER-USER 1 "${rule[@]}"
if ip6tables -nL DOCKER-USER >/dev/null 2>&1; then
    ip6tables -C DOCKER-USER "${rule[@]}" 2>/dev/null || ip6tables -I DOCKER-USER 1 "${rule[@]}"
fi
