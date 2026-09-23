#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/municipio/common.sh
load_config
[[ "$NODE_ROLE" == data ]] || exit 0
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --bootstrap-if-unavailable ) ]] || \
    die 'Usage: refresh-sites.municipio.sh [--bootstrap-if-unavailable]'

install -d -m 0755 /etc/caddy
exec 9>/run/lock/municipio-sites.lock
flock -n 9 || die 'Another site refresh is running'

if [[ "$DOCKER_SWARM" == 1 ]]; then
    container="$(docker ps -q --filter "label=com.docker.swarm.service.name=$(swarm_service_name)" --filter status=running | head -n 1)"
else
    container="$(docker inspect -f '{{if .State.Running}}{{.Id}}{{end}}' municipio-app 2>/dev/null || true)"
fi

if [[ -z "$container" ]]; then
    if [[ "${1:-}" == --bootstrap-if-unavailable && ! -f /etc/caddy/municipio-sites.caddy ]]; then
        log 'Application is not running; seeding Caddy with SITE_ADDRESS until WordPress can be queried'
        sites="$SITE_ADDRESS"
    elif [[ "${1:-}" == --bootstrap-if-unavailable ]]; then
        log 'Application is not running; retaining the existing Caddy site list'
        sites=
    else
        die 'No local Municipio container is running; the existing Caddy site list was retained'
    fi
else
    wp_cli() {
        docker exec --workdir /var/www/vhosts/localhost/html "$container" \
            wp --allow-root --skip-plugins --skip-themes "$@"
    }
    mode="$(wp_cli eval 'echo is_multisite() ? "multisite" : "single";')" || \
        die 'WP-CLI could not determine the installation mode; the Caddy site list was retained'
    case "$mode" in
        multisite) sites="$(wp_cli site list --field=domain)" || die 'WP-CLI could not list multisite domains' ;;
        single) sites="$(wp_cli eval 'echo home_url();')" || die 'WP-CLI could not read the site URL' ;;
        *) die "Unexpected WP-CLI installation mode: $mode" ;;
    esac
fi

sites_file=/etc/caddy/municipio-sites.caddy
main_file=/etc/caddy/Caddyfile
candidate="$(mktemp /etc/caddy/.municipio-sites.XXXXXX)"
candidate_main="$(mktemp /etc/caddy/.Caddyfile.XXXXXX)"
old_sites="$(mktemp /etc/caddy/.municipio-sites-old.XXXXXX)"
old_main="$(mktemp /etc/caddy/.Caddyfile-old.XXXXXX)"
trap 'rm -f -- "$candidate" "$candidate_main" "$old_sites" "$old_main"' EXIT

if [[ -n "$sites" ]]; then
    generator_args=()
    [[ "${CADDY_SITE_ADDRESS:-$SITE_ADDRESS}" == :80 ]] && generator_args+=(--http-only)
    printf '%s\n' "$sites" | bash /usr/local/lib/municipio/build-caddy-sites.sh \
        "${generator_args[@]}" > "$candidate"
else
    cp "$sites_file" "$candidate"
fi

install -d -o caddy -g caddy -m 0755 "$HEALTH_ROOT"
if [[ "${CADDY_SITE_ADDRESS:-$SITE_ADDRESS}" == :80 ]]; then
    proxy_block="reverse_proxy ${APP_BIND_ADDRESS:-127.0.0.1}:${APP_BIND_PORT:-8080} {
        header_up X-Forwarded-Proto https
    }"
else
    proxy_block="reverse_proxy ${APP_BIND_ADDRESS:-127.0.0.1}:${APP_BIND_PORT:-8080}"
fi
cat > "$candidate_main" <<EOF
(municipio_proxy) {
    handle /healthz {
        root * ${HEALTH_ROOT}
        try_files /healthz /missing
        file_server
    }
    $(printf '%b' "$proxy_block")
}
import ${candidate}
EOF
caddy validate --config "$candidate_main" --adapter caddyfile

if [[ -f "$main_file" ]]; then cp -p "$main_file" "$old_main"; else : > "$old_main"; fi
if [[ -f "$sites_file" ]]; then cp -p "$sites_file" "$old_sites"; else : > "$old_sites"; fi
sed "s|${candidate}|${sites_file}|" "$candidate_main" > "${candidate_main}.final"
trap 'rm -f -- "$candidate" "$candidate_main" "${candidate_main}.final" "$old_sites" "$old_main"' EXIT
if ! cmp -s "$candidate" "$sites_file" || ! cmp -s "${candidate_main}.final" "$main_file"; then
    install -o root -g caddy -m 0644 "$candidate" "$sites_file"
    install -o root -g caddy -m 0644 "${candidate_main}.final" "$main_file"
    systemctl enable caddy
    if systemctl --quiet is-active caddy.service; then
        systemctl reload caddy && activated=true || activated=false
    else
        systemctl start caddy && activated=true || activated=false
    fi
    if [[ "$activated" == false ]]; then
        [[ -s "$old_sites" ]] && install -o root -g caddy -m 0644 "$old_sites" "$sites_file"
        [[ -s "$old_main" ]] && install -o root -g caddy -m 0644 "$old_main" "$main_file"
        systemctl restart caddy || true
        die 'Caddy reload failed; the previous configuration was restored where possible'
    fi
    log "Refreshed Caddy site list: $sites_file"
else
    systemctl enable --now caddy
fi
