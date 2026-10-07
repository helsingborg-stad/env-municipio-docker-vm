#!/usr/bin/env bash
set -euo pipefail
# Installed by install/maintenance.sh; the repository copy is scripts/lib/common.sh.
# shellcheck disable=SC1091
source /usr/local/lib/municipio/common.sh
load_config
[[ "$NODE_ROLE" == data ]] || exit 0
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --bootstrap-if-unavailable ) ]] || \
    die 'Usage: refresh-sites.municipio.sh [--bootstrap-if-unavailable]'

exec 9>/run/lock/municipio-sites.lock
flock -n 9 || die 'Another site refresh is running'

# A bind mount opened before Gluster is mounted remains attached to the underlying
# local directory. Never start or refresh cluster Caddy until the shared mount is ready.
if [[ "$DEPLOYMENT_MODE" != standalone ]]; then
    if ! mountpoint -q "$DATA_ROOT"; then
        if [[ "${1:-}" == --bootstrap-if-unavailable ]]; then
            log 'Gluster is not mounted; deferring Caddy until cluster activation'
            exit 0
        fi
        die 'Gluster is not mounted; Caddy storage cannot be refreshed'
    fi
    [[ "$(findmnt -no FSTYPE --target "$DATA_ROOT")" == fuse.glusterfs ]] || \
        die 'DATA_ROOT is not a Gluster mount; Caddy storage cannot be refreshed'
    findmnt -no OPTIONS --target "$DATA_ROOT" | tr ',' '\n' | grep -qx rw || \
        die 'Gluster mount is read-only; Caddy storage cannot be refreshed'
fi
install -d -m 0700 "$DATA_ROOT/caddy"
[[ -w "$DATA_ROOT/caddy" ]] || die 'Caddy data directory is not writable'

if [[ "$DOCKER_SWARM" == 1 ]]; then
    container="$(docker ps -q --filter "label=com.docker.swarm.service.name=$(swarm_service_name)" --filter status=running | head -n 1)"
else
    container="$(compose ps -q municipio 2>/dev/null || true)"
    [[ -z "$container" || "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" == true ]] || container=
fi

caddy_dir="$CONFIG_ROOT/caddy"
install -d -m 0755 "$HEALTH_ROOT" "$caddy_dir"
sites_file="$caddy_dir/municipio-sites.caddy"
main_file="$caddy_dir/Caddyfile"

if [[ -z "$container" ]]; then
    if [[ "${1:-}" == --bootstrap-if-unavailable && ! -f "$sites_file" ]]; then
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
    [[ -n "$sites" ]] || die 'WordPress returned no site hostnames; the existing Caddy site list was retained'
fi

staging="$(mktemp -d)"
previous="$(mktemp -d)"
trap 'rm -rf -- "$staging" "$previous"' EXIT
if [[ -n "$sites" ]]; then
    generator_args=(--require-host "$SITE_ADDRESS")
    [[ "${CADDY_SITE_ADDRESS:-$SITE_ADDRESS}" == :80 ]] && generator_args+=(--http-only)
    [[ "$ACME_DNS_PROVIDER" != none ]] && generator_args+=(--dns-challenge)
    printf '%s\n' "$sites" | bash /usr/local/lib/municipio/build-caddy-sites.sh \
        "${generator_args[@]}" > "$staging/municipio-sites.caddy"
else
    cp "$sites_file" "$staging/municipio-sites.caddy"
fi

if [[ "${CADDY_SITE_ADDRESS:-$SITE_ADDRESS}" == :80 ]]; then
    proxy_block="reverse_proxy ${APP_BIND_ADDRESS:-127.0.0.1}:${APP_BIND_PORT:-8080} {
        header_up X-Forwarded-Proto https
    }"
else
    proxy_block="reverse_proxy ${APP_BIND_ADDRESS:-127.0.0.1}:${APP_BIND_PORT:-8080}"
fi
tls_snippet=
if [[ "$ACME_DNS_PROVIDER" != none ]]; then
    override_domain=
    if [[ -n "$ACME_DNS_CHALLENGE_DOMAIN" ]]; then
        override_domain="            dns_challenge_override_domain $ACME_DNS_CHALLENGE_DOMAIN"
    fi
    case "$ACME_DNS_PROVIDER" in
        loopia)
            tls_snippet="(municipio_tls) {
    tls {
        issuer acme {
$override_domain
            propagation_timeout 15m
            dns loopia {
                username {\$ACME_DNS_LOOPIA_USERNAME}
                password {\$ACME_DNS_LOOPIA_PASSWORD}
            }
        }
    }
}"
            module='dns.providers.loopia'
            ;;
        namedotcom)
            tls_snippet="(municipio_tls) {
    tls {
        issuer acme {
$override_domain
            dns namedotcom {
                user {\$ACME_DNS_NAMEDOTCOM_USER}
                token {\$ACME_DNS_NAMEDOTCOM_TOKEN}
                server {\$ACME_DNS_NAMEDOTCOM_SERVER}
            }
        }
    }
}"
            module='dns.providers.namedotcom'
            ;;
    esac
fi
cat > "$staging/Caddyfile" <<EOF_CADDY
{
    storage file_system /data/caddy
}

(municipio_proxy) {
    handle /healthz {
        root * /var/lib/municipio/health
        try_files /healthz /missing
        file_server
    }
    $(printf '%b' "$proxy_block")
}
$tls_snippet
import /etc/caddy/municipio-sites.caddy
EOF_CADDY
chmod 0644 "$staging/Caddyfile" "$staging/municipio-sites.caddy"
# The Caddy image is pinned by digest. Both files are validated together through the
# same path that the running container sees.
docker image inspect "$CADDY_IMAGE" >/dev/null 2>&1 || docker pull -q "$CADDY_IMAGE" >/dev/null
if [[ "$ACME_DNS_PROVIDER" != none ]]; then
    docker run --rm "$CADDY_IMAGE" caddy list-modules | grep -Fxq "$module" || \
        die "CADDY_IMAGE does not include $module; select a digest-pinned Caddy image built with the $ACME_DNS_PROVIDER DNS module"
fi
caddy_environment=()
if [[ "$ACME_DNS_PROVIDER" == loopia ]]; then
    caddy_environment=(-e ACME_DNS_LOOPIA_USERNAME -e ACME_DNS_LOOPIA_PASSWORD)
elif [[ "$ACME_DNS_PROVIDER" == namedotcom ]]; then
    caddy_environment=(-e ACME_DNS_NAMEDOTCOM_USER -e ACME_DNS_NAMEDOTCOM_TOKEN -e ACME_DNS_NAMEDOTCOM_SERVER)
fi
docker run --rm "${caddy_environment[@]}" -v "$staging:/etc/caddy:ro" "$CADDY_IMAGE" \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

if cmp -s "$staging/Caddyfile" "$main_file" && \
    cmp -s "$staging/municipio-sites.caddy" "$sites_file"; then
    # Compose also applies a changed image or mount definition when the generated
    # Caddyfile itself has not changed.
    start_proxy
    exit 0
fi

[[ ! -f "$main_file" ]] || cp -p "$main_file" "$previous/Caddyfile"
[[ ! -f "$sites_file" ]] || cp -p "$sites_file" "$previous/municipio-sites.caddy"
install -m 0644 "$staging/municipio-sites.caddy" "$sites_file"
install -m 0644 "$staging/Caddyfile" "$main_file"
# Compose applies any changed image or mount definition before reloading Caddy.
activated=false
if start_proxy && compose exec -T caddy caddy reload \
    --config /etc/caddy/Caddyfile --adapter caddyfile; then
    activated=true
fi
if [[ "$activated" == false ]]; then
    for name in Caddyfile municipio-sites.caddy; do
        if [[ -f "$previous/$name" ]]; then
            install -m 0644 "$previous/$name" "$caddy_dir/$name"
        else
            rm -f "$caddy_dir/$name"
        fi
    done
    if container_running caddy; then
        compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || true
    elif [[ -f "$main_file" && -f "$sites_file" ]]; then
        start_proxy || true
    fi
    die 'Caddy activation failed; the previous configuration was restored'
fi
log "Refreshed Caddy site list: $sites_file"
