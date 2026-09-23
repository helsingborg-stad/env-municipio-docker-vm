#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/municipio/common.sh
load_config
[[ "$DOCKER_SWARM" == 1 ]] || exit 0

port="${APP_BIND_PORT:-8080}"
# Published-port DNAT can change the destination port before DOCKER-USER runs.
forward_rule=(! -i lo -p tcp -m conntrack --ctorigdstport "$port" -j DROP)
input_rule=(! -i lo -p tcp --dport "$port" -j DROP)
iptables -C DOCKER-USER "${forward_rule[@]}" 2>/dev/null || iptables -I DOCKER-USER 1 "${forward_rule[@]}"
iptables -C INPUT "${input_rule[@]}" 2>/dev/null || iptables -I INPUT 1 "${input_rule[@]}"
if ip6tables -nL DOCKER-USER >/dev/null 2>&1; then
    ip6tables -C DOCKER-USER "${forward_rule[@]}" 2>/dev/null || ip6tables -I DOCKER-USER 1 "${forward_rule[@]}"
fi
ip6tables -C INPUT "${input_rule[@]}" 2>/dev/null || ip6tables -I INPUT 1 "${input_rule[@]}"
