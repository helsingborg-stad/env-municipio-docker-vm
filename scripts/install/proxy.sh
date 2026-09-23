#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/municipio/common.sh
load_config
[[ "$NODE_ROLE" == data ]] || exit 0
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --no-start ) ]] || die 'Usage: configure-proxy.municipio.sh [--no-start]'
start_service=true
[[ "${1:-}" == --no-start ]] && start_service=false
if [[ "$start_service" == false ]] && systemctl --quiet is-active caddy.service; then
    die 'Stop caddy.service before staging a proxy configuration without starting it'
fi

install -d -o caddy -g caddy -m 0755 "${HEALTH_ROOT}"
if [[ "${CADDY_SITE_ADDRESS:-$SITE_ADDRESS}" == :80 ]]; then
    proxy_block="reverse_proxy ${APP_BIND_ADDRESS:-127.0.0.1}:${APP_BIND_PORT:-8080} {\n        header_up X-Forwarded-Proto https\n    }"
else
    proxy_block="reverse_proxy ${APP_BIND_ADDRESS:-127.0.0.1}:${APP_BIND_PORT:-8080}"
fi
tmp_caddy="$(mktemp)"
trap 'rm -f "$tmp_caddy"' EXIT
cat > "$tmp_caddy" <<EOF
${CADDY_SITE_ADDRESS:-$SITE_ADDRESS} {
    handle /healthz {
        root * ${HEALTH_ROOT}
        try_files /healthz /missing
        file_server
    }
    $(printf '%b' "$proxy_block")
}
EOF
caddy validate --config "$tmp_caddy" --adapter caddyfile
if [[ ! -f /etc/caddy/Caddyfile ]] || ! cmp -s "$tmp_caddy" /etc/caddy/Caddyfile; then
    install -o root -g caddy -m 0644 "$tmp_caddy" /etc/caddy/Caddyfile
fi
if [[ "$start_service" == true ]]; then
    systemctl enable caddy
    systemctl reload caddy 2>/dev/null || systemctl restart caddy
fi
