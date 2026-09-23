#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/platform.sh"
[[ $EUID -eq 0 ]] || { echo 'Run as root: sudo bash bin/interactive-install.sh' >&2; exit 1; }
[[ -r /dev/tty ]] || { echo 'An interactive terminal is required' >&2; exit 1; }
exec 3</dev/tty

ask() {
    local label="$1" default="${2:-}" answer
    while true; do
        if [[ -n "$default" ]]; then
            printf '%s [%s]: ' "$label" "$default" >&2
        else
            printf '%s: ' "$label" >&2
        fi
        IFS= read -r -u 3 answer || exit 1
        answer="${answer:-$default}"
        if [[ -n "$answer" ]]; then
            REPLY="$answer"
            return
        fi
        echo 'A value is required.' >&2
    done
}

choice() {
    local label="$1" default="$2" allowed="$3"
    while true; do
        ask "$label ($allowed)" "$default"
        case " $allowed " in
            *" $REPLY "*) return ;;
        esac
        echo 'Choose one of the listed values.' >&2
    done
}

secret() {
    local label="$1" optional="${2:-false}" answer
    while true; do
        printf '%s%s: ' "$label" "$([[ "$optional" == true ]] && printf ' (Enter to generate)' || true)" >&2
        IFS= read -r -s -u 3 answer || exit 1
        printf '\n' >&2
        if contains_single_quote "$answer"; then
            echo "A single quote (') cannot be stored in the configuration file." >&2
            continue
        fi
        if [[ -n "$answer" || "$optional" == true ]]; then
            REPLY="$answer"
            return
        fi
        echo 'A value is required.' >&2
    done
}

random_secret() { openssl rand -hex 24; }

# The generated file is read twice with different parsers: bash `source` in the
# maintenance scripts, and Docker Compose's dotenv reader for container environments.
# Single quoting is the only encoding the two agree on for every shell metacharacter.
# `printf %q` is not: it escapes with backslashes that bash decodes and Compose does not,
# so a password containing $, \ or a space would reach the database and the container as
# two different strings.
contains_single_quote() { case "$1" in *\'*) return 0 ;; *) return 1 ;; esac; }

write_value() {
    if contains_single_quote "$2"; then
        echo "Value for $1 must not contain a single quote." >&2
        exit 1
    fi
    printf "%s='%s'\n" "$1" "$2" >> "$config_file"
}

if [[ -e /etc/municipio/municipio.env ]]; then
    echo 'Existing Municipio configuration found at /etc/municipio/municipio.env.'
    choice 'Resume installation using that configuration?' no 'yes no'
    [[ "$REPLY" == yes ]] || exit 0
    bash "$ROOT_DIR/bin/install.sh" --env-file /etc/municipio/municipio.env
    /scripts/status.municipio.sh
    exit 0
fi

detect_platform
command -v openssl >/dev/null 2>&1 || {
    echo 'openssl is required to generate credentials.' >&2; exit 1;
}

printf 'Municipio setup for %s %s (%s)\n' "$PLATFORM_ID" "$PLATFORM_VERSION" "$PLATFORM_CODENAME"
echo 'Press Enter to accept defaults. Passwords will not be displayed.'
choice 'Deployment' standalone 'standalone cluster-manual cluster-arbitrator'
deployment_mode="$REPLY"
node_role=data
if [[ "$deployment_mode" != standalone ]]; then
    choice 'This VM is a' primary 'primary secondary arbiter'
    selected_role="$REPLY"
    if [[ "$selected_role" == arbiter ]]; then
        [[ "$deployment_mode" == cluster-arbitrator ]] || {
            echo 'An arbitrator is available only in cluster-arbitrator mode.' >&2; exit 1;
        }
        node_role=arbiter
    fi
else
    selected_role=primary
fi
runtime=none docker_swarm=0
if [[ "$node_role" == data ]]; then
    choice 'Container runtime' compose 'compose swarm'
    runtime="$REPLY"
    [[ "$runtime" == swarm ]] && docker_swarm=1
fi

ask 'This VM hostname' "$(hostname -s)"
node_name="$REPLY"
ask 'This VM cluster IP address' "$(hostname -I | awk '{print $1}')"
node_address="$REPLY"

primary_name="$node_name" primary_address="$node_address"
secondary_name= secondary_address= arbiter_name= arbiter_address=
if [[ "$deployment_mode" != standalone ]]; then
    if [[ "$selected_role" == primary ]]; then
        ask 'Secondary VM hostname'; secondary_name="$REPLY"
        ask 'Secondary VM cluster IP address'; secondary_address="$REPLY"
    elif [[ "$selected_role" == secondary ]]; then
        secondary_name="$node_name" secondary_address="$node_address"
        ask 'Primary VM hostname'; primary_name="$REPLY"
        ask 'Primary VM cluster IP address'; primary_address="$REPLY"
    else
        ask 'Primary VM hostname'; primary_name="$REPLY"
        ask 'Primary VM cluster IP address'; primary_address="$REPLY"
        ask 'Secondary VM hostname'; secondary_name="$REPLY"
        ask 'Secondary VM cluster IP address'; secondary_address="$REPLY"
    fi
    if [[ "$deployment_mode" == cluster-arbitrator ]]; then
        if [[ "$node_role" == arbiter ]]; then
            arbiter_name="$node_name" arbiter_address="$node_address"
        else
            ask 'Arbitrator hostname'; arbiter_name="$REPLY"
            ask 'Arbitrator cluster IP address'; arbiter_address="$REPLY"
        fi
    fi
fi

site_address= caddy_address= db_name= db_user= db_password= db_root_password=
wp_admin_user= wp_admin_password= wp_admin_email=
if [[ "$node_role" == data ]]; then
    ask 'Public website hostname (without https://)' ; site_address="$REPLY"
    choice 'Where does HTTPS terminate?' caddy 'caddy upstream'
    tls_mode="$REPLY"
    caddy_address="$site_address"
    [[ "$tls_mode" == upstream ]] && caddy_address=:80
    # In a cluster the state transfer replicates the privilege tables, so both data VMs
    # must be given the same database passwords. Generated values cannot match, which is
    # why they are only offered for standalone.
    secrets_optional=true
    if [[ "$deployment_mode" != standalone ]]; then
        secrets_optional=false
        echo 'Both data VMs must be installed with identical database passwords.' >&2
    fi
    ask 'Database name' municipio; db_name="$REPLY"
    ask 'Database user' municipio; db_user="$REPLY"
    secret 'Database password' "$secrets_optional"
    db_password="${REPLY:-$(random_secret)}"
    secret 'Database root password' "$secrets_optional"
    db_root_password="${REPLY:-$(random_secret)}"
    ask 'WordPress admin user' admin; wp_admin_user="$REPLY"
    secret 'WordPress admin password' "$secrets_optional"
    wp_admin_password="${REPLY:-$(random_secret)}"
    ask 'WordPress admin email'; wp_admin_email="$REPLY"
fi

printf '\nReview: %s, %s, %s (%s)\n' "$deployment_mode" "$runtime" "$node_name" "$node_address" >&2
if [[ "$node_role" == data ]]; then
    printf 'Website: %s; Caddy listener: %s\n' "$site_address" "$caddy_address" >&2
fi
choice 'Install now?' yes 'yes no'
[[ "$REPLY" == yes ]] || { echo 'Cancelled.' >&2; exit 0; }

config_file="$(mktemp)"
chmod 0600 "$config_file"
trap 'rm -f -- "$config_file"' EXIT
# The reviewed digests and path defaults ship with the source bundle.
default_value() { sed -n "s/^$1=//p" "$ROOT_DIR/.env.example"; }
# Settings the wizard does not ask about but must still write out verbatim. Kept on one
# assignment so that tests/check.sh can read the list without parsing shell control flow.
COPIED_DEFAULT_NAMES='CONFIG_ROOT INSTALL_ROOT DATA_ROOT DB_DATA_ROOT DB_SOCKET_DIR DB_SOCKET_UID DB_SOCKET_GID GLUSTER_BRICK BACKUP_ROOT HEALTH_ROOT DB_HOST DB_TABLE_PREFIX APP_BIND_ADDRESS APP_BIND_PORT WP_SITE_TITLE WP_DEBUG WP_REDIS_DISABLED'
image="$(default_value MUNICIPIO_IMAGE)"
mariadb_image="$(default_value MARIADB_IMAGE)"
caddy_image="$(default_value CADDY_IMAGE)"
write_value DEPLOYMENT_MODE "$deployment_mode"
write_value DOCKER_SWARM "$docker_swarm"
write_value NODE_ROLE "$node_role"
write_value NODE_NAME "$node_name"
write_value NODE_ADDRESS "$node_address"
write_value PRIMARY_NODE_NAME "$primary_name"
write_value PRIMARY_NODE_ADDRESS "$primary_address"
write_value SECONDARY_NODE_NAME "$secondary_name"
write_value SECONDARY_NODE_ADDRESS "$secondary_address"
write_value ARBITRATOR_NODE_NAME "$arbiter_name"
write_value ARBITRATOR_NODE_ADDRESS "$arbiter_address"
write_value MUNICIPIO_IMAGE "$image"
write_value MARIADB_IMAGE "$mariadb_image"
write_value CADDY_IMAGE "$caddy_image"
write_value SITE_ADDRESS "$site_address"
write_value CADDY_SITE_ADDRESS "$caddy_address"
write_value DB_NAME "$db_name"
write_value DB_USER "$db_user"
write_value DB_PASSWORD "$db_password"
write_value DB_ROOT_PASSWORD "$db_root_password"
write_value WP_ADMIN_USER "$wp_admin_user"
write_value WP_ADMIN_PASSWORD "$wp_admin_password"
write_value WP_ADMIN_EMAIL "$wp_admin_email"

# The generated file has to be self-contained. Docker Compose reads it directly and
# applies none of the defaults that validate_config fills in for the shell, so an
# unwritten DB_DATA_ROOT or DATA_ROOT becomes an empty bind-mount source. It is also the
# copy captured into every backup, and DB_DATA_ROOT is what decides where the database
# lives. tests/check.sh reads this list to rebuild a wizard-shaped file and validate it.
for name in $COPIED_DEFAULT_NAMES; do
    write_value "$name" "$(default_value "$name")"
done

MUNICIPIO_ENV_FILE="$config_file" bash -c 'source "$1/scripts/lib/common.sh"; load_config' _ "$ROOT_DIR"
bash "$ROOT_DIR/bin/install.sh" --env-file "$config_file"

if [[ "$deployment_mode" == standalone ]]; then
    echo 'Installation complete. Services are running.'
    /scripts/status.municipio.sh
    echo "Open https://${site_address}/ (or use your upstream HTTPS endpoint)."
    echo 'Configuration: /etc/municipio/municipio.env (root only).'
else
    echo 'Cluster services are installed. Activation requires the peer VM to be prepared.'
    if [[ "$selected_role" == primary ]]; then
        choice 'Is the secondary prepared and should this VM bootstrap the cluster now?' no 'yes no'
        [[ "$REPLY" == no ]] || /scripts/cluster.municipio.sh bootstrap
    elif [[ "$selected_role" == secondary ]]; then
        choice 'Has the primary bootstrapped, and should this VM join now?' no 'yes no'
        if [[ "$REPLY" == yes ]]; then
            if [[ "$docker_swarm" == 1 ]]; then
                secret 'Swarm worker join token from the primary manager'
                printf '%s\n' "$REPLY" | /scripts/cluster.municipio.sh join --token-stdin
                echo 'On the manager, run: sudo /scripts/cluster.municipio.sh enable-node SECONDARY_HOSTNAME'
            else
                /scripts/cluster.municipio.sh join
            fi
        fi
    else
        choice 'Are both data VMs active, and should this arbitrator start now?' no 'yes no'
        [[ "$REPLY" == no ]] || /scripts/cluster.municipio.sh start-arbitrator
    fi
    echo 'Check /scripts/status.municipio.sh and docs/runbook.md before adding HTTP traffic.'
fi
