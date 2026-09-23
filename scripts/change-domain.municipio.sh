#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/municipio/common.sh
load_config
[[ "$NODE_ROLE" == data ]] || die 'Domain changes run on data VMs only'
[[ "$MUNICIPIO_ENV_FILE" == /etc/municipio/municipio.env ]] || die 'Use the installed /etc/municipio/municipio.env configuration'
[[ "${WP_REDIS_DISABLED:-true}" == true ]] || die 'External Redis cache is enabled; plan and flush it separately before a domain migration'

state_dir=/var/lib/municipio/domain-change
state_file="$state_dir/domain-migration.state"
exec 9>/run/lock/municipio-domain.lock
flock -n 9 || die 'Another domain operation is running on this VM'

validate_new_domain() {
    local domain="$1"
    local label
    local -a labels
    [[ "$domain" == *.* && "$domain" != .* && "$domain" != *. && "$domain" != *..* && ${#domain} -le 253 ]] || \
        die 'Provide a DNS hostname without scheme, path, or port'
    IFS=. read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || \
            die "Invalid DNS label in $domain"
    done
    [[ "$domain" != "$SITE_ADDRESS" ]] || die 'The new domain is already configured on this VM'
    [[ "${CADDY_SITE_ADDRESS:-$SITE_ADDRESS}" == "$SITE_ADDRESS" || "${CADDY_SITE_ADDRESS:-$SITE_ADDRESS}" == :80 ]] || \
        die 'Custom CADDY_SITE_ADDRESS needs a reviewed manual migration'
}

local_container() {
    if [[ "$DOCKER_SWARM" == 1 ]]; then
        docker ps -q --filter "label=com.docker.swarm.service.name=$(swarm_service_name)" --filter status=running | head -n 1
    else
        docker inspect -f '{{if .State.Running}}{{.Id}}{{end}}' municipio-app 2>/dev/null || true
    fi
}

wp_cli() {
    docker exec --workdir /var/www/vhosts/localhost/html "$container" \
        wp --allow-root --skip-plugins --skip-themes "$@"
}

preflight() {
    local new_domain="$1"
    [[ ! -e "$state_file" ]] || die "Unfinished migration exists: $state_file"
    validate_new_domain "$new_domain"
    container="$(local_container)"
    [[ -n "$container" ]] || die 'No local Municipio container is running'
    wp_cli --info >/dev/null || die 'WP-CLI is not available in the pinned Municipio image; no changes were made'
    [[ "$(wp_cli eval 'echo is_multisite() ? "yes" : "no";')" == no ]] || \
        die 'Multisite needs a separate migration plan; no changes were made'
    echo "Previewing stored URL changes from $SITE_ADDRESS to $new_domain:"
    wp_cli search-replace "https://${SITE_ADDRESS}" "https://${new_domain}" \
        --all-tables-with-prefix --skip-columns=guid --precise --dry-run
    wp_cli search-replace "http://${SITE_ADDRESS}" "https://${new_domain}" \
        --all-tables-with-prefix --skip-columns=guid --precise --dry-run
}

write_state() {
    local phase="$1" backup_path="${2:-}" tmp
    install -d -m 0700 "$state_dir"
    tmp="$(mktemp "$state_dir/.domain-migration.XXXXXX")"
    printf 'OLD_DOMAIN=%q\nNEW_DOMAIN=%q\nBACKUP_PATH=%q\nPHASE=%q\n' \
        "$old_domain" "$new_domain" "$backup_path" "$phase" > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$state_file"
}

update_local_config() {
    local temp_config caddy_address
    caddy_address="${CADDY_SITE_ADDRESS:-$SITE_ADDRESS}"
    [[ "$caddy_address" == :80 ]] || caddy_address="$new_domain"
    grep -q '^SITE_ADDRESS=' "$MUNICIPIO_ENV_FILE" || die 'SITE_ADDRESS line missing from installed configuration'
    temp_config="$(mktemp /etc/municipio/.domain-env.XXXXXX)"
    sed -e "s|^SITE_ADDRESS=.*$|SITE_ADDRESS=${new_domain}|" \
        -e "s|^CADDY_SITE_ADDRESS=.*$|CADDY_SITE_ADDRESS=${caddy_address}|" \
        "$MUNICIPIO_ENV_FILE" > "$temp_config"
    if ! grep -q '^CADDY_SITE_ADDRESS=' "$temp_config"; then
        printf 'CADDY_SITE_ADDRESS=%s\n' "$caddy_address" >> "$temp_config"
    fi
    chmod 0600 "$temp_config"
    mv -f "$temp_config" "$MUNICIPIO_ENV_FILE"
    export SITE_ADDRESS="$new_domain" CADDY_SITE_ADDRESS="$caddy_address"
}

prepare_local_traffic() {
    /scripts/maintenance.municipio.sh on
    if [[ "$(systemctl is-enabled caddy.service 2>/dev/null || true)" != masked ]]; then
        systemctl disable --now caddy.service
        systemctl mask caddy.service
    fi
    ! systemctl --quiet is-active caddy.service || die 'Caddy is still serving traffic'
}

verify_backup() {
    [[ -s "$backup_path/database.sql.gz" && -s "$backup_path/files.tar.gz" && -s "$backup_path/municipio.env" ]] || \
        die "Backup is incomplete: $backup_path"
    gzip -t "$backup_path/database.sql.gz" || die "Database backup is corrupt: $backup_path"
    tar -tzf "$backup_path/files.tar.gz" >/dev/null || die "File backup is corrupt: $backup_path"
}

finish_local_config() {
    deploy_application
    wait_for_application
    wait_for_local_domain
    /scripts/configure-proxy.municipio.sh --no-start
    if [[ "$DEPLOYMENT_MODE" != standalone && "$NODE_NAME" == "$PRIMARY_NODE_NAME" ]]; then
        local marker_tmp
        mountpoint -q "$DATA_ROOT" || die 'Cluster data mount is unavailable'
        marker_tmp="$(mktemp "$DATA_ROOT/.municipio-domain-ready.XXXXXX")"
        printf '%s\n' "$new_domain" > "$marker_tmp"
        chmod 0600 "$marker_tmp"
        mv -f "$marker_tmp" "$DATA_ROOT/.municipio-domain-ready"
    fi
    write_state ready "$backup_path"
    log 'Local migration is prepared. Caddy remains stopped; use resume after every VM is ready.'
}

wait_for_local_domain() {
    local deadline=$((SECONDS + 180)) running_container
    until {
        running_container="$(local_container)"
        [[ -n "$running_container" ]] && \
            docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$running_container" | \
                grep -Fqx "WP_CONF_WP_HOME=https://${new_domain}"
    }; do
        ((SECONDS < deadline)) || die 'Local application task did not receive the new domain'
        sleep 3
    done
}

action="${1:-}"
case "$action" in
    preflight)
        [[ $# -eq 2 ]] || die 'Usage: change-domain.municipio.sh preflight NEW_DOMAIN'
        preflight "$2"
        ;;
    migrate)
        [[ $# -ge 2 ]] || die 'Usage: change-domain.municipio.sh migrate NEW_DOMAIN [--all-nodes-offline]'
        new_domain="$2" old_domain="$SITE_ADDRESS"
        if [[ "$DEPLOYMENT_MODE" != standalone ]]; then
            [[ $# -eq 3 ]] || die 'Cluster migration requires NEW_DOMAIN --all-nodes-offline'
            [[ "$NODE_NAME" == "$PRIMARY_NODE_NAME" ]] || die 'Run the database migration on the primary data VM'
            [[ "${3:-}" == --all-nodes-offline ]] || die 'First stop Caddy and enable maintenance on every other data VM; then pass --all-nodes-offline'
        else
            [[ $# -eq 2 ]] || die 'Standalone migration takes NEW_DOMAIN only'
        fi
        preflight "$new_domain"
        prepare_local_traffic
        write_state started
        backup_path="$(/scripts/backup.municipio.sh pre-domain-change)"
        verify_backup
        write_state backed-up "$backup_path"
        wp_cli search-replace "https://${old_domain}" "https://${new_domain}" \
            --all-tables-with-prefix --skip-columns=guid --precise
        wp_cli search-replace "http://${old_domain}" "https://${new_domain}" \
            --all-tables-with-prefix --skip-columns=guid --precise
        write_state database-changed "$backup_path"
        if [[ "$DEPLOYMENT_MODE" == standalone ]]; then
            find "${DATA_ROOT:?}/cache" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        else
            /scripts/cluster.municipio.sh clear-cache --all-nodes-drained
        fi
        update_local_config
        finish_local_config
        ;;
    sync-node)
        [[ $# -eq 2 ]] || die 'Usage: change-domain.municipio.sh sync-node NEW_DOMAIN'
        [[ "$DEPLOYMENT_MODE" != standalone && "$NODE_NAME" == "$SECONDARY_NODE_NAME" ]] || \
            die 'sync-node runs on the secondary data VM only'
        new_domain="$2" old_domain="$SITE_ADDRESS"
        [[ ! -e "$state_file" ]] || die "Unfinished migration exists: $state_file"
        validate_new_domain "$new_domain"
        [[ "$(cat "$DATA_ROOT/.municipio-domain-ready" 2>/dev/null || true)" == "$new_domain" ]] || \
            die 'Primary has not published a completed migration on the shared data volume'
        prepare_local_traffic
        write_state started
        backup_path="$(/scripts/backup.municipio.sh pre-domain-sync)"
        verify_backup
        write_state backed-up "$backup_path"
        if [[ "$DOCKER_SWARM" == 1 ]]; then
            wait_for_local_domain
        fi
        update_local_config
        if [[ "$DOCKER_SWARM" == 1 ]]; then
            /scripts/configure-proxy.municipio.sh --no-start
            write_state ready "$backup_path"
        else
            finish_local_config
        fi
        log 'Secondary is prepared. Leave Caddy stopped until both VMs are ready.'
        ;;
    resume)
        [[ $# -eq 1 ]] || die 'Usage: change-domain.municipio.sh resume'
        [[ -f "$state_file" ]] || die 'No domain migration is pending'
        PHASE= NEW_DOMAIN=
        # This file is created by this root-only script, never by the application.
        # shellcheck disable=SC1090
        source "$state_file"
        [[ "$PHASE" == ready && "$SITE_ADDRESS" == "$NEW_DOMAIN" ]] || \
            die 'Migration is incomplete; keep Caddy stopped and inspect the backup/state file'
        systemctl unmask caddy.service
        systemctl enable --now caddy.service
        if ! /scripts/maintenance.municipio.sh off; then
            /scripts/maintenance.municipio.sh on || true
            systemctl disable --now caddy.service || true
            systemctl mask caddy.service || true
            die 'Local health failed; Caddy was stopped again'
        fi
        rm -f "$state_file"
        log "Local traffic resumed on $NEW_DOMAIN; verify public HTTPS and /healthz"
        ;;
    status)
        [[ $# -eq 1 ]] || die 'Usage: change-domain.municipio.sh status'
        if [[ -f "$state_file" ]]; then
            echo "migration_state=$state_file"
            sed -n '/^\(OLD_DOMAIN\|NEW_DOMAIN\|BACKUP_PATH\|PHASE\)=/p' "$state_file"
        else
            echo 'migration_state=none'
        fi
        ;;
    *) die 'Usage: change-domain.municipio.sh preflight NEW_DOMAIN | migrate NEW_DOMAIN [--all-nodes-offline] | sync-node NEW_DOMAIN | resume | status' ;;
esac
