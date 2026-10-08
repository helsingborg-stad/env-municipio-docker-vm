#!/usr/bin/env bash
set -euo pipefail
# Installed by install/maintenance.sh; the repository copy is scripts/lib/common.sh.
# shellcheck disable=SC1091
source /usr/local/lib/municipio/common.sh

# Moves the setup site to a new hostname. Site discovery refuses a SITE_ADDRESS that
# WordPress does not report, so the hostname has to change in WordPress itself, not only
# in municipio.env. Run it on the primary first and then on the secondary.
#
# The primary takes a backup and rewrites the database: the multisite domain records,
# and stored URLs via WP-CLI search-replace. Galera replicates that to the secondary. Both
# nodes then update municipio.env, recreate their application container so that
# WP_HOME/WP_SITEURL follow the new SITE_ADDRESS, and refresh Caddy.

usage() {
    cat >&2 <<EOF
Usage: $0 NEW_HOSTNAME [--from OLD_HOSTNAME]

  NEW_HOSTNAME  The new setup hostname, e.g. kris.helsingborg.se
  --from        The hostname to replace. Detected from WordPress when omitted.

Run it on the primary data VM first, then on the secondary.
EOF
    exit 2
}
NEW_HOST='' OLD_HOST=''
while (($#)); do
    case "$1" in
        -h|--help) usage ;;
        --from) [[ $# -ge 2 && -n "$2" ]] || usage; OLD_HOST="$2"; shift 2 ;;
        -*) usage ;;
        *) [[ -z "$NEW_HOST" ]] || usage; NEW_HOST="$1"; shift ;;
    esac
done
[[ -n "$NEW_HOST" ]] || usage
NEW_HOST="$(printf '%s' "${NEW_HOST%.}" | tr '[:upper:]' '[:lower:]')"
[[ "$NEW_HOST" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || \
    die "Not an ASCII hostname: $NEW_HOST"

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0 $NEW_HOST"
load_config
[[ "$NODE_ROLE" == data ]] || die 'Run this on the data VMs only'
[[ "$DOCKER_SWARM" == 0 ]] || \
    die 'Swarm deployments are not supported; the application must be redeployed from the manager'
[[ -t 0 ]] || die 'Run this script interactively'
# The VMs may run scripts from an older release than this one.
for dep in /scripts/refresh-sites.municipio.sh /scripts/backup.municipio.sh /usr/local/lib/municipio/build-caddy-sites.sh; do
    [[ -x "$dep" || ( "$dep" == *.sh && -f "$dep" ) ]] || \
        die "$dep is missing; re-run installer.sh on this VM to install the current scripts first"
done

confirm() {
    local answer
    read -r -p "$1 [y/N] " answer
    [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]]
}

is_primary=true
[[ "$DEPLOYMENT_MODE" == standalone || "$NODE_NAME" == "$PRIMARY_NODE_NAME" ]] || is_primary=false

app_container() {
    local id
    id="$(compose ps -q municipio 2>/dev/null || true)"
    [[ -n "$id" && "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null)" == true ]] || \
        die 'The local Municipio container is not running'
    printf '%s' "$id"
}

# OLD and NEW reach PHP through the environment, never through the command text.
wp_cli() {
    docker exec -e OLD="$OLD_HOST" -e NEW="$NEW_HOST" \
        --workdir /var/www/vhosts/localhost/html "$(app_container)" \
        wp --allow-root --skip-plugins --skip-themes "$@"
}

host_of() { local u="${1#*://}"; u="${u%%/*}"; u="${u%%:*}"; printf '%s' "$u" | tr '[:upper:]' '[:lower:]'; }

mode="$(wp_cli eval 'echo is_multisite() ? "multisite" : "single";')" || \
    die 'WP-CLI could not determine the installation mode'
prefix="$(wp_cli db prefix)"
log "WordPress is $mode with table prefix '$prefix'"

# The stored hostname, not home_url(): WP_HOME from the container environment overrides
# the database value, so home_url() still reports the old SITE_ADDRESS.
if [[ "$mode" == multisite ]]; then
    wp_cli site list --fields=blog_id,domain,path
    stored="$(wp_cli eval 'echo get_site(get_main_site_id())->domain;')"
else
    # shellcheck disable=SC2016
    stored="$(host_of "$(wp_cli eval 'global $wpdb; echo $wpdb->get_var("SELECT option_value FROM {$wpdb->options} WHERE option_name = '"'home'"'");')")"
    log "Stored home URL hostname: $stored"
fi
[[ -n "$OLD_HOST" ]] || OLD_HOST="$stored"
OLD_HOST="$(printf '%s' "${OLD_HOST%.}" | tr '[:upper:]' '[:lower:]')"

if [[ "$stored" == "$NEW_HOST" ]]; then
    log "WordPress already uses $NEW_HOST; skipping the database change"
elif [[ "$is_primary" == false ]]; then
    die "WordPress still reports $stored. Run this script on the primary ($PRIMARY_NODE_NAME) first and wait for Galera to replicate"
else
    [[ "$OLD_HOST" != "$NEW_HOST" ]] || die 'The old and new hostnames are the same'
    echo
    echo "Database change:  $OLD_HOST  ->  $NEW_HOST"
    confirm 'Is that mapping correct?' || die 'Aborted; nothing was changed'

    log 'Taking a backup before the database change'
    /scripts/backup.municipio.sh pre-domain-change

    sr_args=(--precise --skip-columns=guid --report-changed-only)
    [[ "$mode" == multisite ]] && sr_args+=(--network)
    log 'Dry run of the stored-URL replacement:'
    wp_cli search-replace "//$OLD_HOST" "//$NEW_HOST" "${sr_args[@]}" --dry-run
    wp_cli search-replace "\\/\\/$OLD_HOST" "\\/\\/$NEW_HOST" "${sr_args[@]}" --dry-run
    if [[ "$mode" == multisite ]]; then
        echo 'Multisite: the replacement is required, because each site stores its home/siteurl.'
    fi
    if confirm 'Apply the replacement?'; then
        wp_cli search-replace "//$OLD_HOST" "//$NEW_HOST" "${sr_args[@]}"
        wp_cli search-replace "\\/\\/$OLD_HOST" "\\/\\/$NEW_HOST" "${sr_args[@]}"
    elif [[ "$mode" == multisite ]]; then
        die 'Aborted before changing any domain records; the backup above is untouched'
    fi

    if [[ "$mode" == multisite ]]; then
        # shellcheck disable=SC2016
        wp_cli eval '
            global $wpdb;
            $b = $wpdb->update($wpdb->blogs, ["domain" => getenv("NEW")], ["domain" => getenv("OLD")]);
            $s = $wpdb->update($wpdb->site, ["domain" => getenv("NEW")], ["domain" => getenv("OLD")]);
            if ($b === false || $s === false) { fwrite(STDERR, $wpdb->last_error . "\n"); exit(1); }
            echo "Updated $b site record(s) and $s network record(s)\n";'
    fi
    wp_cli cache flush || true
fi

if [[ "$mode" == multisite ]]; then
    dcs="$(wp_cli eval 'echo defined("DOMAIN_CURRENT_SITE") ? DOMAIN_CURRENT_SITE : "";')"
    if [[ -n "$dcs" && "$dcs" != "$NEW_HOST" ]]; then
        log "WARNING: DOMAIN_CURRENT_SITE is still '$dcs' in wp-config; it must also become $NEW_HOST"
    fi
fi

# municipio.env: CADDY_SITE_ADDRESS only follows when it is a hostname, not :80.
env_file="$MUNICIPIO_ENV_FILE"
if [[ "$SITE_ADDRESS" != "$NEW_HOST" || ( -n "${CADDY_SITE_ADDRESS:-}" && "$CADDY_SITE_ADDRESS" != :80 && "$CADDY_SITE_ADDRESS" != "$NEW_HOST" ) ]]; then
    backup="$env_file.$(date -u +%Y%m%dT%H%M%SZ).bak"
    install -m 0600 "$env_file" "$backup"
    sed -i "s|^SITE_ADDRESS=.*|SITE_ADDRESS=$NEW_HOST|" "$env_file"
    if [[ -n "${CADDY_SITE_ADDRESS:-}" && "$CADDY_SITE_ADDRESS" != :80 ]]; then
        sed -i "s|^CADDY_SITE_ADDRESS=.*|CADDY_SITE_ADDRESS=$NEW_HOST|" "$env_file"
    fi
    log "Updated $env_file (previous copy: $backup)"
    load_config
else
    log "$env_file already uses $NEW_HOST"
fi
[[ "$SITE_ADDRESS" == "$NEW_HOST" ]] || die "SITE_ADDRESS in $env_file is still $SITE_ADDRESS"

log 'Recreating the application container with the new WP_HOME/WP_SITEURL'
compose up -d --no-deps --force-recreate --wait municipio

if ! getent hosts "$NEW_HOST" >/dev/null; then
    log "WARNING: $NEW_HOST does not resolve yet; Caddy cannot obtain its certificate until DNS points here"
fi

log 'Refreshing Caddy site routes'
/scripts/refresh-sites.municipio.sh --bootstrap-if-unavailable
grep -E '^[^[:space:]#].* [{]$' "$CONFIG_ROOT/caddy/municipio-sites.caddy"

if [[ "$DEPLOYMENT_MODE" != standalone && "$is_primary" == true ]]; then
    log "Done on $NODE_NAME. Now run on $SECONDARY_NODE_NAME: sudo $0 $NEW_HOST"
else
    log "Done on $NODE_NAME"
fi
