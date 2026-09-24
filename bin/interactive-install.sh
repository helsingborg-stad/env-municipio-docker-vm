#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/platform.sh"
[[ $EUID -eq 0 ]] || { echo 'Please run the installer as administrator: sudo bash bin/interactive-install.sh' >&2; exit 1; }
[[ -r /dev/tty ]] || { echo 'The installer asks questions, so it must be run from a terminal.' >&2; exit 1; }
exec 3</dev/tty

say() { printf '%s\n' "$*" >&2; }
heading() { printf '\n== %s ==\n' "$*" >&2; }
step_number=0
step() { step_number=$((step_number + 1)); heading "Step $step_number: $*"; }

# ask LABEL [DEFAULT] [PATTERN] [HINT]
# PATTERN is an extended regex the answer must match; HINT explains a rejection.
ask() {
    local label="$1" default="${2:-}" pattern="${3:-}" hint="${4:-}" answer
    while true; do
        if [[ -n "$default" ]]; then
            printf '%s [%s]: ' "$label" "$default" >&2
        else
            printf '%s: ' "$label" >&2
        fi
        IFS= read -r -u 3 answer || exit 1
        answer="${answer:-$default}"
        if [[ -z "$answer" ]]; then
            say 'An answer is required.'
            continue
        fi
        if [[ -n "$pattern" && ! "$answer" =~ $pattern ]]; then
            say "${hint:-That value is not valid.}"
            continue
        fi
        REPLY="$answer"
        return
    done
}

# menu LABEL DEFAULT_KEY KEY "DESCRIPTION" [KEY "DESCRIPTION"]...
# Prints a numbered list. The answer may be the number or the key; REPLY is the key.
menu() {
    local label="$1" default="$2" answer i
    shift 2
    local -a keys=() descriptions=()
    while (($#)); do keys+=("$1"); descriptions+=("$2"); shift 2; done
    say "$label"
    local default_number=
    for i in "${!keys[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${descriptions[$i]}" >&2
        [[ "${keys[$i]}" == "$default" ]] && default_number=$((i + 1))
    done
    while true; do
        ask 'Your choice' "$default_number"
        answer="$REPLY"
        for i in "${!keys[@]}"; do
            if [[ "$answer" == "$((i + 1))" || "$answer" == "${keys[$i]}" ]]; then
                REPLY="${keys[$i]}"
                return
            fi
        done
        say "Please type a number from 1 to ${#keys[@]}."
    done
}

yes_no() {
    local label="$1" default="$2" answer
    while true; do
        ask "$label (yes/no)" "$default"
        answer="$(printf '%s' "$REPLY" | tr '[:upper:]' '[:lower:]')"
        case "$answer" in
            y|yes) REPLY=yes; return ;;
            n|no) REPLY=no; return ;;
        esac
        say 'Please answer yes or no.'
    done
}

# secret LABEL [OPTIONAL] [MIN_LENGTH] [CONFIRM]
# OPTIONAL=true lets Enter return an empty value, which the caller replaces.
# CONFIRM=false skips the second entry, for pasted values rather than new passwords.
secret() {
    local label="$1" optional="${2:-false}" min_length="${3:-1}" confirm_entry="${4:-true}" answer confirm
    while true; do
        printf '%s%s: ' "$label" "$([[ "$optional" == true ]] && printf ' (press Enter to create one automatically)' || true)" >&2
        IFS= read -r -s -u 3 answer || exit 1
        printf '\n' >&2
        if [[ -z "$answer" ]]; then
            if [[ "$optional" == true ]]; then REPLY=; return; fi
            say 'A password is required.'
            continue
        fi
        if contains_single_quote "$answer"; then
            say "Passwords cannot contain a single quote ('). Please choose another."
            continue
        fi
        if ((${#answer} < min_length)); then
            say "Please use at least $min_length characters."
            continue
        fi
        if [[ "$confirm_entry" == false ]]; then REPLY="$answer"; return; fi
        printf 'Type it again to confirm: ' >&2
        IFS= read -r -s -u 3 confirm || exit 1
        printf '\n' >&2
        if [[ "$answer" != "$confirm" ]]; then
            say 'The two entries did not match. Please try again.'
            continue
        fi
        REPLY="$answer"
        return
    done
}

random_secret() { openssl rand -hex 24; }

# Both data servers of a cluster must hold identical database passwords, because the
# database copies its user accounts from one server to the other. Deriving them from one
# shared cluster password lets the operator type a single secret on each server, in any
# order. The output is hex, so it can never contain a single quote.
derive_secret() {
    printf 'municipio:%s:%s' "$1" "$2" | openssl dgst -sha256 -r | cut -c1-48
}

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

# The same character rules validate_config applies, checked while the answer is fresh.
NAME_PATTERN='^[A-Za-z0-9._-]+$'
NAME_HINT='Use only letters, digits, dots, dashes and underscores (for example: municipio-01).'
ADDRESS_PATTERN='^[A-Za-z0-9.:-]+$'
ADDRESS_HINT='Enter an IP address such as 10.20.0.11.'
EMAIL_PATTERN='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'

detected_address() {
    local address
    address="$(hostname -I 2>/dev/null | awk '{print $1}')"
    printf '%s' "${address:-127.0.0.1}"
}

# The steps after installing a cluster server. Shared by a fresh installation and by
# resuming one from saved settings, which would otherwise stop before the cluster starts.
# Reads deployment_mode, docker_swarm, selected_role, node_name and node_address.
cluster_next_steps() {
    # bootstrap and join write this marker once the local database is in the cluster.
    if [[ -f /etc/municipio/cluster-initialized ]]; then
        heading 'This server is already part of the cluster'
        if [[ -f /etc/municipio/galera-bootstrap-active ]]; then
            say 'Once website server 2 has connected, finish by running this on this server:'
            say '  sudo /scripts/cluster.municipio.sh clear-bootstrap-flag'
        fi
        say 'Check the servers with: sudo /scripts/status.municipio.sh'
        return 0
    fi
    heading 'This server is installed'
    say "When installing the other servers, enter this server as: $node_name ($node_address)"
    say 'The cluster starts once all servers are installed, in this order:'
    say '  1. Install every server (you can do this in any order).'
    say '  2. Start the cluster on website server 1.'
    say '  3. Connect website server 2.'
    say '  4. Confirm on website server 1 that server 2 has joined (clear-bootstrap-flag).'
    [[ "$deployment_mode" != cluster-arbitrator ]] || say '  5. Start the tie-breaker.'
    say 'You can answer "no" below and continue later. Every step is described in the runbook:'
    say '  https://github.com/helsingborg-stad/env-municipio-docker-vm/blob/main/docs/runbook.md'
    case "$selected_role" in
        primary)
            yes_no 'Is website server 2 installed, and should the cluster start now?' no
            if [[ "$REPLY" == yes ]]; then
                /scripts/cluster.municipio.sh bootstrap
                if [[ "$docker_swarm" == 1 ]]; then
                    say 'Website server 2 will ask for a join code. Show it here with:'
                    say '  sudo docker swarm join-token -q worker'
                fi
                say 'After website server 2 has connected, finish by running this on this server:'
                say '  sudo /scripts/cluster.municipio.sh clear-bootstrap-flag'
            else
                say 'Later, start it with: sudo /scripts/cluster.municipio.sh bootstrap'
            fi
            ;;
        secondary)
            yes_no 'Has the cluster been started on website server 1, and should this server connect now?' no
            if [[ "$REPLY" == yes ]]; then
                if [[ "$docker_swarm" == 1 ]]; then
                    say 'On website server 1, run: sudo docker swarm join-token -q worker'
                    secret 'Paste the join code it prints' false 1 false
                    printf '%s\n' "$REPLY" | /scripts/cluster.municipio.sh join --token-stdin
                    say 'Then, on website server 1, run:'
                    say "  sudo /scripts/cluster.municipio.sh enable-node $node_name"
                    say '  sudo /scripts/cluster.municipio.sh clear-bootstrap-flag'
                else
                    /scripts/cluster.municipio.sh join
                    say 'Connected. Finish by running this on website server 1:'
                    say '  sudo /scripts/cluster.municipio.sh clear-bootstrap-flag'
                fi
            else
                say 'Later, connect it with: sudo /scripts/cluster.municipio.sh join'
            fi
            ;;
        arbiter)
            yes_no 'Are both website servers connected, and should the tie-breaker start now?' no
            if [[ "$REPLY" == yes ]]; then
                /scripts/cluster.municipio.sh start-arbitrator
            else
                say 'Later, start it with: sudo /scripts/cluster.municipio.sh start-arbitrator'
            fi
            ;;
    esac
    say 'Check the servers with: sudo /scripts/status.municipio.sh'
}

if [[ -e /etc/municipio/municipio.env ]]; then
    # A file written by an older installer version, or cut short, cannot be resumed. Say so
    # before offering to continue, instead of failing on the first missing setting after.
    if ! saved_problem="$(MUNICIPIO_ENV_FILE=/etc/municipio/municipio.env \
        bash -c 'source "$1/scripts/lib/common.sh"; load_config' _ "$ROOT_DIR" 2>&1 >/dev/null)"; then
        say 'This server already has saved Municipio settings (/etc/municipio/municipio.env),'
        say 'but they cannot be used to continue. They were probably written by an older'
        say 'version of the installer, or by an installation that stopped part-way.'
        say "Reason: ${saved_problem#\[municipio\] ERROR: }"
        say ''
        say 'Start again on a fresh server. Alternatively, remove the earlier installation first'
        say 'with the uninstaller and run this installer again:'
        say '  https://github.com/helsingborg-stad/env-municipio-docker-vm/blob/main/README.md#uninstalling'
        say 'Nothing was changed.'
        exit 1
    fi
    say 'This server already has saved Municipio settings (/etc/municipio/municipio.env),'
    say 'probably from an earlier installation that did not finish.'
    yes_no 'Continue that installation with the saved settings?' no
    [[ "$REPLY" == yes ]] || { say 'Nothing was changed. To start over, run the uninstaller first.'; exit 0; }
    bash "$ROOT_DIR/bin/install.sh" --env-file /etc/municipio/municipio.env
    { read -r deployment_mode; read -r docker_swarm; read -r saved_role; read -r node_name
      read -r node_address; read -r primary_name; } < <(MUNICIPIO_ENV_FILE=/etc/municipio/municipio.env bash -c \
        'source "$1/scripts/lib/common.sh"; load_config
         printf "%s\n" "$DEPLOYMENT_MODE" "$DOCKER_SWARM" "$NODE_ROLE" "$NODE_NAME" "$NODE_ADDRESS" "${PRIMARY_NODE_NAME:-}"' \
        _ "$ROOT_DIR")
    if [[ "$deployment_mode" == standalone ]]; then
        /scripts/status.municipio.sh
        exit 0
    fi
    # The wizard's own answer is not saved, but the settings it wrote determine it.
    if [[ "$saved_role" == arbiter ]]; then
        selected_role=arbiter
    elif [[ "$node_name" == "$primary_name" ]]; then
        selected_role=primary
    else
        selected_role=secondary
    fi
    cluster_next_steps
    exit 0
fi

detect_platform
command -v openssl >/dev/null 2>&1 || {
    echo 'The openssl program is required to create passwords. Install it with: sudo apt-get install openssl' >&2; exit 1;
}

printf 'Welcome to the Municipio installer (%s %s).\n' "$PLATFORM_ID" "$PLATFORM_VERSION" >&2
say 'You will be asked a few questions. The suggested answer is shown in [brackets];'
say 'press Enter to accept it. Passwords are not shown while you type.'

step 'How many servers?'
menu 'How will the website run?' standalone \
    standalone 'On this server only (recommended for most sites)' \
    cluster-manual 'On two servers working together (a "cluster") that keep each other up to date. If one fails, an administrator switches over by hand.' \
    cluster-arbitrator 'On a cluster of two servers plus a small third "tie-breaker" server, so the switch-over happens automatically.'
deployment_mode="$REPLY"

node_role=data selected_role=primary
if [[ "$deployment_mode" != standalone ]]; then
    say ''
    say 'Run this installer on every server. Each one needs to know which part it plays.'
    if [[ "$deployment_mode" == cluster-arbitrator ]]; then
        menu 'Which server is this?' primary \
            primary 'Website server 1 (the main one; it starts the cluster)' \
            secondary 'Website server 2 (joins server 1)' \
            arbiter 'The tie-breaker (stores no website data)'
    else
        menu 'Which server is this?' primary \
            primary 'Website server 1 (the main one; it starts the cluster)' \
            secondary 'Website server 2 (joins server 1)'
    fi
    selected_role="$REPLY"
    [[ "$selected_role" == arbiter ]] && node_role=arbiter
fi

# Standalone needs nothing from the network layout, so it is detected, not asked.
node_name="$(hostname -s)" node_address="$(detected_address)"
primary_name="$node_name" primary_address="$node_address"
secondary_name='' secondary_address='' arbiter_name='' arbiter_address=''
if [[ "$deployment_mode" != standalone ]]; then
    step 'How the servers find each other'
    say 'The servers talk to each other over your internal network. For each server, give'
    say "its short name (what the command 'hostname -s' prints on it) and its internal IP address."
    ask 'Name of this server' "$node_name" "$NAME_PATTERN" "$NAME_HINT"; node_name="$REPLY"
    ask 'Internal IP address of this server' "$node_address" "$ADDRESS_PATTERN" "$ADDRESS_HINT"; node_address="$REPLY"
    case "$selected_role" in
        primary)
            primary_name="$node_name" primary_address="$node_address"
            ask 'Name of website server 2' '' "$NAME_PATTERN" "$NAME_HINT"; secondary_name="$REPLY"
            ask 'Internal IP address of website server 2' '' "$ADDRESS_PATTERN" "$ADDRESS_HINT"; secondary_address="$REPLY"
            ;;
        secondary)
            secondary_name="$node_name" secondary_address="$node_address"
            ask 'Name of website server 1' '' "$NAME_PATTERN" "$NAME_HINT"; primary_name="$REPLY"
            ask 'Internal IP address of website server 1' '' "$ADDRESS_PATTERN" "$ADDRESS_HINT"; primary_address="$REPLY"
            ;;
        arbiter)
            ask 'Name of website server 1' '' "$NAME_PATTERN" "$NAME_HINT"; primary_name="$REPLY"
            ask 'Internal IP address of website server 1' '' "$ADDRESS_PATTERN" "$ADDRESS_HINT"; primary_address="$REPLY"
            ask 'Name of website server 2' '' "$NAME_PATTERN" "$NAME_HINT"; secondary_name="$REPLY"
            ask 'Internal IP address of website server 2' '' "$ADDRESS_PATTERN" "$ADDRESS_HINT"; secondary_address="$REPLY"
            ;;
    esac
    if [[ "$deployment_mode" == cluster-arbitrator ]]; then
        if [[ "$node_role" == arbiter ]]; then
            arbiter_name="$node_name" arbiter_address="$node_address"
        else
            ask 'Name of the tie-breaker server' '' "$NAME_PATTERN" "$NAME_HINT"; arbiter_name="$REPLY"
            ask 'Internal IP address of the tie-breaker server' '' "$ADDRESS_PATTERN" "$ADDRESS_HINT"; arbiter_address="$REPLY"
        fi
    fi
fi

runtime=compose docker_swarm=0
site_address='' caddy_address='' tls_mode=caddy
db_name=municipio db_user=municipio db_password='' db_root_password=''
wp_admin_user=admin wp_admin_password='' wp_admin_email=''
generated_admin_password=false
if [[ "$node_role" == data ]]; then
    step 'The website'
    [[ "$deployment_mode" == standalone ]] || say 'Give the same answers here on both website servers.'
    while true; do
        ask 'Web address of the site, for example www.example.se'
        # People paste what their browser shows; keep only the host name.
        site_address="${REPLY#http://}" site_address="${site_address#https://}"
        site_address="${site_address%%/*}"
        [[ "$site_address" =~ $ADDRESS_PATTERN ]] && break
        say 'Enter only the address, such as www.example.se (no spaces).'
    done
    menu 'Who takes care of the HTTPS certificate (the padlock in the browser)?' caddy \
        caddy 'This server gets and renews it automatically (choose this if unsure; the web address must already point to this server)' \
        upstream 'Another machine in front of this server (a load balancer or proxy that passes visitors on) already handles HTTPS'
    tls_mode="$REPLY"
    caddy_address="$site_address"
    [[ "$tls_mode" == upstream ]] && caddy_address=:80

    ask 'Email address of the WordPress administrator' '' "$EMAIL_PATTERN" \
        'Enter an email address such as webmaster@example.se.'
    wp_admin_email="$REPLY"

    step 'Passwords'
    if [[ "$deployment_mode" == standalone ]]; then
        say 'The database passwords are created automatically; you never need to type them.'
        secret 'Password for logging in to WordPress (at least 8 characters)' true 8
        wp_admin_password="$REPLY"
        [[ -n "$wp_admin_password" ]] || { wp_admin_password="$(random_secret)"; generated_admin_password=true; }
        db_password="$(random_secret)"
        db_root_password="$(random_secret)"
    else
        say 'Both website servers must use the same passwords. Choose them now and type exactly'
        say 'the same ones when you install the other website server.'
        say 'The cluster password protects the database; nobody logs in with it.'
        secret 'Cluster password (at least 16 characters)' false 16
        db_password="$(derive_secret db-password "$REPLY")"
        db_root_password="$(derive_secret db-root-password "$REPLY")"
        secret 'Password for logging in to WordPress (at least 8 characters)' false 8
        wp_admin_password="$REPLY"
    fi

    say ''
    yes_no 'Change advanced settings? Most people answer no' no
    if [[ "$REPLY" == yes ]]; then
        [[ "$deployment_mode" == standalone ]] || \
            say 'In a cluster, give both website servers the same advanced settings.'
        menu 'How should the containers be managed?' compose \
            compose 'Docker Compose: each server manages its own containers (recommended)' \
            swarm 'Docker Swarm: the servers are managed as one group'
        runtime="$REPLY"
        [[ "$runtime" == swarm ]] && docker_swarm=1
        ask 'WordPress administrator user name' "$wp_admin_user" "$NAME_PATTERN" "$NAME_HINT"
        wp_admin_user="$REPLY"
        ask 'Database name' "$db_name" '^[A-Za-z0-9_]+$' 'Use only letters, digits and underscores.'
        db_name="$REPLY"
        ask 'Database user name' "$db_user" '^[A-Za-z0-9_]+$' 'Use only letters, digits and underscores.'
        db_user="$REPLY"
        yes_no 'Type the database passwords yourself? Only needed to match a server installed earlier' no
        if [[ "$REPLY" == yes ]]; then
            secret 'Database password (DB_PASSWORD)'
            db_password="$REPLY"
            secret 'Database administrator password (DB_ROOT_PASSWORD)'
            db_root_password="$REPLY"
        fi
    fi
fi

heading 'Summary'
case "$deployment_mode" in
    standalone) say 'Setup:          one server' ;;
    cluster-manual) say 'Setup:          two website servers, manual switch-over' ;;
    cluster-arbitrator) say 'Setup:          two website servers and a tie-breaker, automatic switch-over' ;;
esac
case "$selected_role" in
    primary) [[ "$deployment_mode" == standalone ]] || say 'This server:    website server 1' ;;
    secondary) say 'This server:    website server 2' ;;
    arbiter) say 'This server:    the tie-breaker' ;;
esac
say "Name / address: $node_name ($node_address)"
if [[ "$deployment_mode" != standalone ]]; then
    say "Server 1:       $primary_name ($primary_address)"
    say "Server 2:       $secondary_name ($secondary_address)"
    [[ -z "$arbiter_name" ]] || say "Tie-breaker:    $arbiter_name ($arbiter_address)"
fi
if [[ "$node_role" == data ]]; then
    say "Website:        https://$site_address/"
    if [[ "$tls_mode" == upstream ]]; then
        say 'HTTPS:          handled by a load balancer in front of this server'
    else
        say 'HTTPS:          certificate obtained automatically by this server'
    fi
    say "Administrator:  $wp_admin_user <$wp_admin_email>"
    [[ "$runtime" == compose ]] || say 'Containers:     Docker Swarm'
fi
yes_no 'Install now?' yes
[[ "$REPLY" == yes ]] || { say 'Cancelled. Nothing was installed.'; exit 0; }

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

show_admin_password_hint() {
    [[ "$generated_admin_password" == true ]] || return 0
    say 'A WordPress password was created for you. Show it with:'
    say "  sudo grep WP_ADMIN_PASSWORD /etc/municipio/municipio.env"
}

if [[ "$deployment_mode" == standalone ]]; then
    heading 'Done'
    /scripts/status.municipio.sh
    say "Your site is ready at https://${site_address}/"
    say "Log in at https://${site_address}/wp-admin/ as \"$wp_admin_user\"."
    show_admin_password_hint
    say 'All settings are saved in /etc/municipio/municipio.env (readable by administrators only).'
    exit 0
fi

cluster_next_steps
