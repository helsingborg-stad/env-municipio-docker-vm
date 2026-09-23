#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/platform.sh"
[[ $EUID -eq 0 ]] || { echo 'Run as root: sudo bash bin/interactive-install.sh' >&2; exit 1; }
[[ -r /dev/tty ]] || { echo 'An interactive terminal is required' >&2; exit 1; }
[[ ! -e /etc/municipio/municipio.env ]] || {
    echo 'Municipio is already configured. Review /etc/municipio/municipio.env before reinstalling.' >&2
    exit 1
}
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
        if [[ -n "$answer" || "$optional" == true ]]; then
            REPLY="$answer"
            return
        fi
        echo 'A value is required.' >&2
    done
}

random_secret() { openssl rand -hex 24; }
write_value() { printf '%s=%q\n' "$1" "$2" >> "$config_file"; }

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

site_address= caddy_address= db_name= db_user= db_password=
wp_admin_user= wp_admin_password= wp_admin_email=
if [[ "$node_role" == data ]]; then
    ask 'Public website hostname (without https://)' ; site_address="$REPLY"
    choice 'Where does HTTPS terminate?' caddy 'caddy upstream'
    tls_mode="$REPLY"
    caddy_address="$site_address"
    [[ "$tls_mode" == upstream ]] && caddy_address=:80
    ask 'Database name' municipio; db_name="$REPLY"
    ask 'Database user' municipio; db_user="$REPLY"
    secret 'Database password' "$([[ "$deployment_mode" == standalone ]] && echo true || echo false)"
    db_password="${REPLY:-$(random_secret)}"
    ask 'WordPress admin user' admin; wp_admin_user="$REPLY"
    secret 'WordPress admin password' "$([[ "$deployment_mode" == standalone ]] && echo true || echo false)"
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
image="$(sed -n 's/^MUNICIPIO_IMAGE=//p' "$ROOT_DIR/.env.example")"
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
write_value SITE_ADDRESS "$site_address"
write_value CADDY_SITE_ADDRESS "$caddy_address"
write_value DB_NAME "$db_name"
write_value DB_USER "$db_user"
write_value DB_PASSWORD "$db_password"
write_value WP_ADMIN_USER "$wp_admin_user"
write_value WP_ADMIN_PASSWORD "$wp_admin_password"
write_value WP_ADMIN_EMAIL "$wp_admin_email"

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
