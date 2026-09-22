#!/usr/bin/env bash
set -euo pipefail
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/common.sh"
load_config
[[ "$NODE_ROLE" == data ]] || exit 0

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
caddy validate --config "$tmp_caddy"
if [[ ! -f /etc/caddy/Caddyfile ]] || ! cmp -s "$tmp_caddy" /etc/caddy/Caddyfile; then
    install -o root -g caddy -m 0644 "$tmp_caddy" /etc/caddy/Caddyfile
    systemctl enable caddy
    systemctl reload caddy 2>/dev/null || systemctl restart caddy
else
    systemctl enable --now caddy
fi
