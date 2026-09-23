#!/usr/bin/env bash
set -euo pipefail
source "${MUNICIPIO_REPO_ROOT}/scripts/lib/common.sh"
load_config
[[ "$NODE_ROLE" == data ]] || exit 0

# Root-owned and world-readable: the Caddy container reads it through a read-only bind
# mount, and there is no longer a `caddy` user account on the host.
install -d -m 0755 "$HEALTH_ROOT"
# Caddy's config directory is mounted as a directory, not as a single file. Replacing a
# bind-mounted file in place swaps its inode and detaches the mount.
caddy_dir="$CONFIG_ROOT/caddy"
install -d -m 0755 "$caddy_dir"

if [[ "${CADDY_SITE_ADDRESS:-$SITE_ADDRESS}" == :80 ]]; then
    proxy_block="reverse_proxy ${APP_BIND_ADDRESS:-127.0.0.1}:${APP_BIND_PORT:-8080} {\n        header_up X-Forwarded-Proto https\n    }"
else
    proxy_block="reverse_proxy ${APP_BIND_ADDRESS:-127.0.0.1}:${APP_BIND_PORT:-8080}"
fi
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cat > "$staging/Caddyfile" <<EOF
${CADDY_SITE_ADDRESS:-$SITE_ADDRESS} {
    handle /healthz {
        root * /var/lib/municipio/health
        try_files /healthz /missing
        file_server
    }
    $(printf '%b' "$proxy_block")
}
EOF
chmod 0644 "$staging/Caddyfile"
docker pull -q "$CADDY_IMAGE" >/dev/null
# Validate before installing, so a broken configuration never reaches the running proxy.
docker run --rm -v "$staging:/etc/caddy:ro" "$CADDY_IMAGE" \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

if [[ -f "$caddy_dir/Caddyfile" ]] && cmp -s "$staging/Caddyfile" "$caddy_dir/Caddyfile"; then
    start_proxy
else
    install -m 0644 "$staging/Caddyfile" "$caddy_dir/Caddyfile"
    if [[ -n "$(compose ps -q caddy 2>/dev/null || true)" ]]; then
        compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    else
        start_proxy
    fi
fi
