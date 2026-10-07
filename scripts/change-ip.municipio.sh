#!/usr/bin/env bash
set -euo pipefail
# Installed by install/maintenance.sh; the repository copy is scripts/lib/common.sh.
# shellcheck disable=SC1091
source /usr/local/lib/municipio/common.sh

# Moves a cluster-manual data node to new IP addresses after the provider has already
# changed them. Run it on both data VMs, in either order. Each run stops this node,
# rewrites every place the addresses are stored (municipio.env, the Galera config,
# fstab and Gluster's own metadata) and brings the node back. The primary bootstraps
# Galera; the secondary waits for the primary and joins it.
#
# Gluster created the volume with bricks named by IP, and database.sh refuses to
# regenerate the Galera config of an initialized cluster, so neither heals itself.
#
# Progress is saved after every stage. Re-running the script resumes where it stopped.

usage() {
    cat >&2 <<EOF
Usage: $0 NEW_IP [PEER_NEW_IP]

  NEW_IP       This server's new IP address. It must already be configured here.
  PEER_NEW_IP  The other data VM's new IP address. Asked for when omitted.

Run it on both data VMs, primary first. Without arguments it resumes an
interrupted run.
EOF
    exit 2
}
[[ "${1:-}" != -h && "${1:-}" != --help && $# -le 2 ]] || usage
ARG_SELF="${1:-}" ARG_PEER="${2:-}"

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0 $*"
load_config

[[ "$NODE_ROLE" == data ]] || die 'Run this on the data VMs only'
[[ "$DEPLOYMENT_MODE" == cluster-manual ]] || \
    die "Only cluster-manual is supported (this node is $DEPLOYMENT_MODE)"
[[ "$DOCKER_SWARM" == 0 ]] || \
    die 'Swarm nodes keep their advertise address; moving them means leaving and re-forming the Swarm, which this script does not do'
# The VMs may run scripts from an older release than this one.
for fn in compose compose_galera_bootstrap galera_bootstrap_marker db_container db_status_value \
    wait_for_database start_database deploy_application; do
    declare -F "$fn" >/dev/null || \
        die "/usr/local/lib/municipio/common.sh has no $fn; install the scripts from the same release as this one"
done
[[ -t 0 ]] || die 'Run this script interactively'

STATE="$CONFIG_ROOT/ip-change.state"
GLUSTERD_DIR=/var/lib/glusterd
STAGES=(confirmed stopped rewritten storage database application finished)
exec > >(tee -a /var/log/municipio-ip-change.log) 2>&1

valid_ipv4() {
    local IFS=. octet
    # shellcheck disable=SC2206
    local -a parts=($1)
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    for octet in "${parts[@]}"; do ((10#$octet <= 255)) || return 1; done
}

# Global addresses on real interfaces; container bridges never carry the node address.
local_ipv4s() {
    ip -o -4 addr show scope global | \
        awk '$2 !~ /^(docker|br-|veth|virbr|cni|flannel|cali|vxlan)/ {split($4, a, "/"); print a[1]}' | sort -u
}

has_local_ip() { ip -o -4 addr show | awk '{split($4, a, "/"); print a[1]}' | grep -qxF "$1"; }

tcp_open() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

# Matches an address only as a whole, so 10.0.0.1 never matches inside 10.0.0.11.
ip_regex() {
    local alternatives=() ip
    for ip in "$@"; do alternatives+=("${ip//./\\.}"); done
    local IFS='|'
    printf '(^|[^0-9])(%s)([^0-9]|$)' "${alternatives[*]}"
}

# Rewrites through placeholders, so two nodes that swap addresses are handled correctly.
# shellcheck disable=SC2016 # Perl reads the addresses from the environment.
TO_PLACEHOLDER='s/(?<![0-9])\Q$ENV{OLD_PRIMARY}\E(?![0-9])/__MUNICIPIO_PRIMARY__/g;
                s/(?<![0-9])\Q$ENV{OLD_SECONDARY}\E(?![0-9])/__MUNICIPIO_SECONDARY__/g;'
# shellcheck disable=SC2016
FROM_PLACEHOLDER='s/__MUNICIPIO_PRIMARY__/$ENV{NEW_PRIMARY}/g;
                  s/__MUNICIPIO_SECONDARY__/$ENV{NEW_SECONDARY}/g;'
REIP="$TO_PLACEHOLDER$FROM_PLACEHOLDER"

# Renames in two passes for the same reason: renaming straight to a swapped address
# would overwrite the other node's file.
rename_paths() {
    local path name new_name
    while IFS= read -r -d '' path; do
        name="${path##*/}"
        new_name="$(printf '%s' "$name" | perl -pe "$1")"
        [[ "$new_name" != "$name" ]] || continue
        [[ ! -e "${path%/*}/$new_name" ]] || die "Refusing to overwrite ${path%/*}/$new_name"
        mv -- "$path" "${path%/*}/$new_name"
    done < <(find "$GLUSTERD_DIR" -mindepth 1 -depth -print0)
}

save_stage() {
    STAGE="$1"
    cat > "$STATE" <<EOF
OLD_PRIMARY=$OLD_PRIMARY
OLD_SECONDARY=$OLD_SECONDARY
NEW_PRIMARY=$NEW_PRIMARY
NEW_SECONDARY=$NEW_SECONDARY
BACKUP=${BACKUP:-}
FORCE_BOOTSTRAP=$FORCE_BOOTSTRAP
STAGE=$STAGE
EOF
    chmod 0600 "$STATE"
}

# True once STAGE is at or past the given stage.
reached() {
    local stage seen=false
    for stage in "${STAGES[@]}"; do
        [[ "$stage" == "$1" ]] && seen=true
        if [[ "$stage" == "$STAGE" ]]; then [[ "$seen" == true ]]; return; fi
    done
    return 1
}

# Usage: wait_until MESSAGE SECONDS COMMAND...  (0 seconds waits until interrupted)
wait_until() {
    local message="$1" limit="$2" start="$SECONDS" next=0
    shift 2
    until "$@"; do
        ((limit == 0 || SECONDS - start < limit)) || return 1
        if ((SECONDS >= next)); then log "$message"; next=$((SECONDS + 30)); fi
        sleep 5
    done
}

brick_online() {
    timeout 15 gluster volume status municipio --xml 2>/dev/null | awk -v want="$1:$GLUSTER_BRICK" '
        /<node>/ {h = ""; p = ""; s = ""}
        /<hostname>/ {gsub(/.*<hostname>|<\/hostname>.*/, ""); h = $0}
        /<path>/ {gsub(/.*<path>|<\/path>.*/, ""); p = $0}
        /<status>/ {gsub(/.*<status>|<\/status>.*/, ""); s = $0}
        /<\/node>/ {if (h ":" p == want && s == 1) found = 1}
        END {exit !found}'
}

db_value() { db_container >/dev/null 2>&1 && db_status_value "$1" 2>/dev/null; }
db_primary() { [[ "$(db_value wsrep_cluster_status)" == Primary ]]; }
db_synced() { db_primary && [[ "$(db_value wsrep_local_state_comment)" == Synced ]]; }
peer_connected() { timeout 10 gluster peer status 2>/dev/null | grep -q 'Peer in Cluster (Connected)'; }
cluster_size_two() { local size; size="$(db_value wsrep_cluster_size)"; [[ "$size" =~ ^[0-9]+$ && "$size" -ge 2 ]]; }

# Older installs lack some timers and helper scripts, so only the present ones are used.
TIMERS=()
for unit in municipio-sites.timer municipio-health.timer; do
    systemctl cat "$unit" >/dev/null 2>&1 && TIMERS+=("$unit")
done

start_proxy_any() {
    if [[ -x /scripts/refresh-sites.municipio.sh ]]; then
        /scripts/refresh-sites.municipio.sh
    elif systemctl cat municipio-caddy.service >/dev/null 2>&1; then
        systemctl restart municipio-caddy.service
    else
        compose up -d --no-deps caddy
    fi
}

# The secondary leaves this on the shared volume once it is Synced. Until then the
# primary must not restart MariaDB: a joiner cut off mid state transfer leaves two
# nodes that each lack a complete copy, and neither can form the Primary component.
peer_synced_signal() { printf '%s/.ip-change-%s-synced' "$DATA_ROOT" "$1"; }

mark_safe_to_bootstrap() {
    local grastate="$DB_DATA_ROOT/grastate.dat" owner
    owner="$(stat -c %u:%g "$grastate")"
    perl -pi -e 's/^safe_to_bootstrap:\s*0\s*$/safe_to_bootstrap: 1\n/' "$grastate"
    chown "$owner" "$grastate"
}

bootstrap_primary() {
    rm -f "$(peer_synced_signal "$PEER_NAME")"
    touch "$(galera_bootstrap_marker)"
    compose_galera_bootstrap up -d --no-deps --force-recreate db
    wait_for_database 600 || die 'MariaDB did not start'
    db_primary || die 'MariaDB did not reach the Primary component'
}

stop_gluster() {
    if mountpoint -q "$DATA_ROOT"; then
        # A client cut off from its bricks can hang a normal unmount.
        timeout 30 umount "$DATA_ROOT" || umount -l "$DATA_ROOT"
    fi
    systemctl stop glusterd
    # Stopping glusterd leaves the brick and self-heal processes running.
    pkill -x glusterfsd || true
    pkill -x glusterfs || true
    if ! wait_until 'Waiting for Gluster processes to exit' 30 bash -c '! pgrep -x "gluster(d|fs|fsd)" >/dev/null'; then
        pkill -9 -x 'gluster(d|fs|fsd)' || true
        sleep 2
    fi
    ! pgrep -x 'gluster(d|fs|fsd)' >/dev/null || die 'Gluster processes are still running'
}

FORCE_BOOTSTRAP=0
if [[ "$NODE_NAME" == "$PRIMARY_NODE_NAME" ]]; then
    IS_PRIMARY=true ROLE=primary PEER_NAME="$SECONDARY_NODE_NAME"
else
    IS_PRIMARY=false ROLE=secondary PEER_NAME="$PRIMARY_NODE_NAME"
fi

if [[ -f "$STATE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE"
    for ip in "$OLD_PRIMARY" "$OLD_SECONDARY" "$NEW_PRIMARY" "$NEW_SECONDARY"; do
        valid_ipv4 "$ip" || die "$STATE is damaged; inspect it, and remove it to start over"
    done
    if [[ -n "$ARG_SELF" || -n "$ARG_PEER" ]]; then
        if [[ "$NODE_NAME" == "$PRIMARY_NODE_NAME" ]]; then
            saved_self="$NEW_PRIMARY" saved_peer="$NEW_SECONDARY"
        else
            saved_self="$NEW_SECONDARY" saved_peer="$NEW_PRIMARY"
        fi
        [[ "${ARG_SELF:-$saved_self}" == "$saved_self" && "${ARG_PEER:-$saved_peer}" == "$saved_peer" ]] || \
            die "An unfinished change to $saved_self (peer $saved_peer) is in progress. Run $0 without arguments to resume it."
    fi
    log "Resuming an IP change after stage '$STAGE' ($STATE)."
    log "  $PRIMARY_NODE_NAME: $OLD_PRIMARY -> $NEW_PRIMARY"
    log "  $SECONDARY_NODE_NAME: $OLD_SECONDARY -> $NEW_SECONDARY"
else
    STAGE=none
    OLD_PRIMARY="$PRIMARY_NODE_ADDRESS" OLD_SECONDARY="$SECONDARY_NODE_ADDRESS"
    { valid_ipv4 "$OLD_PRIMARY" && valid_ipv4 "$OLD_SECONDARY"; } || \
        die 'The configured node addresses are not IPv4 addresses; this script handles IPv4 only'
    [[ -f "$GLUSTERD_DIR/vols/municipio/info" ]] || die 'Gluster volume municipio does not exist on this node'
    [[ "$IS_PRIMARY" == true || ! -f "$(galera_bootstrap_marker)" ]] || \
        die 'This secondary was promoted (Galera bootstrap flag is set), so the primary is not authoritative. Recover the cluster first; see docs/failover.md.'
    if [[ "$IS_PRIMARY" == true ]]; then
        old_self="$OLD_PRIMARY" old_peer="$OLD_SECONDARY"
    else
        old_self="$OLD_SECONDARY" old_peer="$OLD_PRIMARY"
    fi

    if [[ -z "$ARG_SELF" ]]; then
        echo "This server is $NODE_NAME ($ROLE), configured as $old_self." >&2
        echo "Addresses on this server: $(local_ipv4s | tr '\n' ' ')" >&2
        usage
    fi
    new_self="$ARG_SELF"
    valid_ipv4 "$new_self" || die "Not an IPv4 address: $new_self"
    has_local_ip "$new_self" || \
        die "$new_self is not configured on this server (it has: $(local_ipv4s | tr '\n' ' ')). Move the address at the provider first; this script only repairs the cluster afterwards."
    echo
    echo "This server is $NODE_NAME ($ROLE), configured as $old_self."

    new_peer="$ARG_PEER"
    if [[ -z "$new_peer" ]]; then
        read -r -p "New IP address of $PEER_NAME [${old_peer}]: " new_peer
        new_peer="${new_peer:-$old_peer}"
    fi
    valid_ipv4 "$new_peer" || die "Not an IPv4 address: $new_peer"
    [[ "$new_peer" != "$new_self" ]] || die 'The two servers need different addresses'
    ! has_local_ip "$new_peer" || die "$new_peer is an address of this server, not of $PEER_NAME"

    if [[ "$IS_PRIMARY" == true ]]; then
        NEW_PRIMARY="$new_self" NEW_SECONDARY="$new_peer"
    else
        NEW_PRIMARY="$new_peer" NEW_SECONDARY="$new_self"
    fi
    if [[ "$NEW_PRIMARY" == "$OLD_PRIMARY" && "$NEW_SECONDARY" == "$OLD_SECONDARY" ]]; then
        log 'Both addresses are unchanged; nothing to do.'
        exit 0
    fi

    echo
    echo "Planned change:"
    echo "  $PRIMARY_NODE_NAME (primary):     $OLD_PRIMARY -> $NEW_PRIMARY"
    echo "  $SECONDARY_NODE_NAME (secondary): $OLD_SECONDARY -> $NEW_SECONDARY"
    if [[ "$new_self" != "$old_self" ]] && has_local_ip "$old_self"; then
        echo "  WARNING: $old_self is still configured on this server; the provider move may be incomplete."
    fi
    if command -v ping >/dev/null 2>&1 && ! ping -c 1 -W 2 "$new_peer" >/dev/null 2>&1; then
        echo "  WARNING: $new_peer does not answer ping. That is fine if ICMP is filtered; check the address."
    fi
    if [[ "$IS_PRIMARY" == true ]] && ! db_primary; then
        # Typical after a reboot: MariaDB restart-loops against the old addresses, and a
        # node that stops outside the Primary component is not marked safe to bootstrap.
        echo
        echo "MariaDB on $NODE_NAME is not in the Galera Primary component. grastate.dat:"
        sed 's/^/  /' "$DB_DATA_ROOT/grastate.dat" 2>/dev/null || echo '  (missing)'
        echo "$NODE_NAME has the larger Galera weight, so $PEER_NAME cannot have committed anything"
        echo "alone unless it was promoted with failover.municipio.sh. Check on $PEER_NAME that"
        echo "this file does NOT exist: $(galera_bootstrap_marker)"
        read -r -p "Type yes if $PEER_NAME was not promoted, to bootstrap Galera from $NODE_NAME: " answer
        [[ "$answer" == yes ]] || die 'Cancelled; nothing was changed'
        FORCE_BOOTSTRAP=1
    fi
    echo
    echo "This takes $NODE_NAME offline: the site, MariaDB and Gluster stop, the addresses are"
    echo "rewritten, and the node is started again. Run the same script on $PEER_NAME too."
    read -r -p 'Type yes to continue: ' answer
    [[ "$answer" == yes ]] || die 'Cancelled; nothing was changed'
    save_stage confirmed
fi
export OLD_PRIMARY OLD_SECONDARY NEW_PRIMARY NEW_SECONDARY
if [[ "$IS_PRIMARY" == true ]]; then
    NEW_SELF="$NEW_PRIMARY" NEW_PEER="$NEW_SECONDARY"
else
    NEW_SELF="$NEW_SECONDARY" NEW_PEER="$NEW_PRIMARY"
fi
# Addresses that no node uses any more; none of them may remain after the rewrite.
retired=()
for ip in "$OLD_PRIMARY" "$OLD_SECONDARY"; do
    [[ "$ip" == "$NEW_PRIMARY" || "$ip" == "$NEW_SECONDARY" ]] || retired+=("$ip")
done

if ! reached stopped; then
    log 'Stopping the site, MariaDB and Gluster on this node'
    /scripts/maintenance.municipio.sh on >/dev/null || true
    # The sites timer would start Caddy again within a minute.
    ((${#TIMERS[@]} == 0)) || systemctl stop "${TIMERS[@]}"
    compose stop caddy municipio
    compose stop -t 120 db
    stop_gluster
    install -d -m 0700 "$BACKUP_ROOT"
    BACKUP="$BACKUP_ROOT/ip-change-$(date +%Y%m%d-%H%M%S).tgz"
    saved=("${CONFIG_ROOT#/}" etc/fstab "${GLUSTERD_DIR#/}")
    [[ ! -f "$DB_DATA_ROOT/grastate.dat" ]] || saved+=("${DB_DATA_ROOT#/}/grastate.dat")
    tar -czf "$BACKUP" -C / "${saved[@]}"
    chmod 0600 "$BACKUP"
    log "Saved the previous configuration to $BACKUP"
    save_stage stopped
fi

if ! reached rewritten; then
    if pgrep -x 'gluster(d|fs|fsd)' >/dev/null || mountpoint -q "$DATA_ROOT"; then
        log 'Gluster is running again (was the server restarted?); stopping it before the rewrite'
        /scripts/maintenance.municipio.sh on >/dev/null || true
        stop_gluster
    fi
    log 'Rewriting the addresses'
    for file in "$MUNICIPIO_ENV_FILE" "$CONFIG_ROOT/mariadb/60-municipio.cnf" /etc/fstab; do
        perl -pi -e "$REIP" "$file"
    done
    while IFS= read -r -d '' file; do
        perl -pi -e "$REIP" "$file"
    done < <(grep -rlE --null "$(ip_regex "$OLD_PRIMARY" "$OLD_SECONDARY")" "$GLUSTERD_DIR" || true)
    # Brick files, brick volfiles and pid files carry the address in their names.
    # -depth renames a directory's contents before the directory itself.
    rename_paths "$TO_PLACEHOLDER"
    rename_paths "$FROM_PLACEHOLDER"
    if ((${#retired[@]})); then
        pattern="$(ip_regex "${retired[@]}")"
        leftovers="$(grep -rlE "$pattern" "$MUNICIPIO_ENV_FILE" "$CONFIG_ROOT/mariadb" /etc/fstab "$GLUSTERD_DIR" || true)"
        leftovers+="$(find "$GLUSTERD_DIR" -print | grep -E "$pattern" || true)"
        [[ -z "$leftovers" ]] || die "Old addresses remain in: $leftovers (backup: $BACKUP)"
    fi
    load_config
    [[ "$NODE_ADDRESS" == "$NEW_SELF" ]] || die "municipio.env has NODE_ADDRESS=$NODE_ADDRESS, expected $NEW_SELF (backup: $BACKUP)"
    save_stage rewritten
fi

if ! reached storage; then
    log 'Starting Gluster'
    systemctl enable --now glusterd
    if ! wait_until "Waiting for the local brick $NEW_SELF:$GLUSTER_BRICK" 60 brick_online "$NEW_SELF"; then
        # Starts only bricks that are down; running bricks and data are untouched.
        gluster volume start municipio force
        wait_until "Waiting for the local brick $NEW_SELF:$GLUSTER_BRICK" 60 brick_online "$NEW_SELF" || \
            die 'The local Gluster brick did not come online; see journalctl -u glusterd'
    fi
    # Client quorum lets the secondary write only while the primary brick is up.
    if [[ "$IS_PRIMARY" == false ]]; then
        next=0
        until brick_online "$NEW_PEER"; do
            if ((SECONDS >= next)); then
                if timeout 10 gluster peer status 2>/dev/null | grep -q Rejected; then
                    log "Gluster on $PEER_NAME rejects this node. Once this script has passed 'Starting Gluster' on both servers, run on both: systemctl restart glusterd"
                else
                    log "Waiting for the brick on $PEER_NAME ($NEW_PEER). Run this script on $PEER_NAME if you have not yet."
                fi
                next=$((SECONDS + 30))
            fi
            sleep 5
        done
    fi
    mountpoint -q "$DATA_ROOT" || mount "$DATA_ROOT"
    [[ "$(findmnt -no FSTYPE --target "$DATA_ROOT")" == fuse.glusterfs ]] || die "$DATA_ROOT is not a Gluster mount"
    touch "$DATA_ROOT/.ip-change-write-test" || die "$DATA_ROOT is not writable"
    rm -f "$DATA_ROOT/.ip-change-write-test"
    save_stage storage
fi

if ! reached database; then
    if [[ "$IS_PRIMARY" == true ]]; then
        if db_primary; then
            log 'MariaDB is already running in the Primary component'
        else
            grastate="$DB_DATA_ROOT/grastate.dat"
            [[ -f "$grastate" ]] || die "$grastate is missing"
            # The primary carries the larger Galera weight, so it kept quorum while the
            # secondary was cut off and is the last node to have left the cluster.
            if [[ "$(awk '$1 == "safe_to_bootstrap:" {print $2}' "$grastate")" != 1 ]]; then
                if [[ "$FORCE_BOOTSTRAP" != 1 ]]; then
                    cat "$grastate"
                    die "MariaDB on $NODE_NAME did not stop as the last cluster member. If $PEER_NAME was not promoted (no $(galera_bootstrap_marker) there), $NODE_NAME is authoritative: set 'safe_to_bootstrap: 1' in $grastate and run this script again. It resumes here."
                fi
                log 'Marking grastate.dat safe to bootstrap, as confirmed at the start'
                mark_safe_to_bootstrap
            fi
            log 'Bootstrapping Galera on the primary'
            bootstrap_primary
        fi
    else
        if db_synced; then
            log 'MariaDB is already synced with the cluster'
        else
            wait_until "Waiting for Galera on $PEER_NAME ($NEW_PEER:4567). Run this script on $PEER_NAME if you have not yet." \
                0 tcp_open "$NEW_PEER" 4567
            log "Joining Galera on $PEER_NAME"
            start_database
            # A joiner may need a full state transfer before it answers.
            wait_for_database 3600 || die 'MariaDB did not complete its state transfer'
            wait_until 'Waiting for MariaDB to reach Synced' 600 db_synced || die 'MariaDB did not reach Synced'
        fi
        touch "$(peer_synced_signal "$NODE_NAME")"
    fi
    save_stage database
fi

if ! reached application; then
    log 'Starting the site'
    deploy_application
    start_proxy_any
    ((${#TIMERS[@]} == 0)) || systemctl start "${TIMERS[@]}"
    /scripts/maintenance.municipio.sh off
    save_stage application
fi

if [[ "$IS_PRIMARY" == true && -f "$(galera_bootstrap_marker)" ]]; then
    signal="$(peer_synced_signal "$PEER_NAME")"
    if ! wait_until 'Checking that MariaDB is in the Primary component' 60 db_primary; then
        # The bootstrap flag is still set and the secondary never reported Synced, so
        # this node still holds the only complete copy and may bootstrap again.
        [[ ! -f "$signal" ]] || \
            die "MariaDB is not Primary, but $PEER_NAME already reported Synced. Compare both nodes before bootstrapping; see docs/failover.md."
        log "MariaDB lost the Primary component before $PEER_NAME finished joining; bootstrapping again from $NODE_NAME"
        compose stop -t 120 db
        mark_safe_to_bootstrap
        bootstrap_primary
    fi
    log "The site is up on $NODE_NAME. If you stop waiting (Ctrl-C), run this script again later to finish."
    peer_finished_joining() {
        [[ -f "$signal" ]] && cluster_size_two && [[ "$(db_value wsrep_local_state_comment)" == Synced ]]
    }
    wait_until "Waiting for $PEER_NAME to finish joining Galera. Run this script on $PEER_NAME if you have not yet." \
        0 peer_finished_joining
    /scripts/cluster.municipio.sh clear-bootstrap-flag
    rm -f "$signal"
fi
if ! wait_until "Waiting for Gluster to show $PEER_NAME as connected" 60 peer_connected; then
    log "WARNING: Gluster does not show $PEER_NAME as connected. Run on both servers: systemctl restart glusterd; then check gluster peer status"
fi
save_stage finished
rm -f "$STATE"

log "Done. $NODE_NAME now uses $NEW_SELF."
if ((${#retired[@]})); then
    pattern="$(ip_regex "${retired[@]}")"
    mapfile -t stale < <(grep -rlsE "$pattern" /etc 2>/dev/null || true)
    if iptables-save 2>/dev/null | grep -qE "$pattern"; then stale+=('iptables rules'); fi
    if nft list ruleset 2>/dev/null | grep -qE "$pattern"; then stale+=('nftables rules'); fi
    if ((${#stale[@]})); then
        log 'These still mention an old address. This script does not change them; check each one:'
        printf '  %s\n' "${stale[@]}"
    fi
fi
log 'Also update any provider firewall rules, load balancer targets and DNS records that use the old addresses.'
log 'Check the result with: /scripts/monitor.municipio.sh and /scripts/status.municipio.sh'
