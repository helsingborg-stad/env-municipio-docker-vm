#!/usr/bin/env bash
# Read-only status board for this node and for what it can see of its peers.
#
#   sudo /scripts/monitor.municipio.sh              one snapshot
#   sudo /scripts/monitor.municipio.sh --watch 5    redraw every 5 seconds
#   /scripts/monitor.municipio.sh --demo cluster    sample screen, touches nothing
#
# Exit status: 0 all OK, 1 at least one warning, 2 at least one failure.
#
# It never changes state. In particular it does not run health.municipio.sh, which
# deletes the health marker before re-evaluating it and would briefly take the node out
# of rotation. There is no SSH to peers: a peer is judged by its /healthz, its open
# replication ports and what Galera, Gluster and Swarm report about it from here.
#
# Deliberately no `set -e`: a failing probe is a result to display, not a reason to
# stop. The screen is most needed exactly when things fail. Nothing here calls the
# die-on-error helpers from common.sh for the same reason.
set -uo pipefail

usage() {
    echo "Usage: $0 [--watch [SECONDS]] [--no-color] [--demo standalone|cluster|arbiter]" >&2
    exit 2
}

WATCH=0
INTERVAL=5
COLOR=auto
DEMO=
while (($#)); do
    case "$1" in
        --watch)
            WATCH=1
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then INTERVAL="$2"; shift; fi
            ;;
        --no-color) COLOR=never ;;
        --demo) DEMO="${2:-cluster}"; [[ $# -gt 1 ]] && shift ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
    shift
done

if [[ "$COLOR" == auto && -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_OK=$'\033[32m' C_WARN=$'\033[33m' C_FAIL=$'\033[1;31m' C_DIM=$'\033[2m' C_B=$'\033[1m' C_0=$'\033[0m'
else
    C_OK='' C_WARN='' C_FAIL='' C_DIM='' C_B='' C_0=''
fi

# ---------------------------------------------------------------------------------------
# Result store. Every check appends one row. Each row also folds into a per-component
# status (S_<component>) and detail (D_<component>): the worst row wins, so a box in the
# diagram always shows the most important problem of its component.
# Plain indexed arrays keep this runnable by the bash 3.2 that macOS ships, for --demo.
# ---------------------------------------------------------------------------------------
R_COMP=() R_STATUS=() R_CHECK=() R_DETAIL=() R_HINT=()
ROWS=0

rank() {
    case "$1" in FAIL) echo 4 ;; WARN) echo 3 ;; OK) echo 2 ;; INFO) echo 1 ;; *) echo 0 ;; esac
}

# record COMPONENT STATUS CHECK DETAIL [HINT]; STATUS is OK, WARN, FAIL, INFO or NA.
record() {
    R_COMP[ROWS]="$1" R_STATUS[ROWS]="$2" R_CHECK[ROWS]="$3" R_DETAIL[ROWS]="$4" R_HINT[ROWS]="${5:-}"
    ROWS=$((ROWS + 1))
    local var="S_$1"
    if [[ -z "${!var:-}" ]] || (($(rank "$2") > $(rank "${!var}"))); then
        printf -v "S_$1" '%s' "$2"
        # A problem is shown with the name of the check that found it.
        if [[ "$2" == FAIL || "$2" == WARN ]]; then
            printf -v "D_$1" '%s: %s' "$3" "$4"
        else
            printf -v "D_$1" '%s' "$4"
        fi
    fi
}

comp_status() { local v="S_$1"; printf '%s' "${!v:-NA}"; }
comp_detail() { local v="D_$1"; printf '%s' "${!v:-not checked}"; }

tag() {
    case "$1" in
        OK) printf '%s[ OK ]%s' "$C_OK" "$C_0" ;;
        WARN) printf '%s[WARN]%s' "$C_WARN" "$C_0" ;;
        FAIL) printf '%s[FAIL]%s' "$C_FAIL" "$C_0" ;;
        INFO) printf '%s[INFO]%s' "$C_DIM" "$C_0" ;;
        *) printf '%s[ -- ]%s' "$C_DIM" "$C_0" ;;
    esac
}

# Cut TEXT to at most WIDTH columns, marking a cut with "~". No padding.
clip() {
    if ((${#1} > $2)); then printf '%s~' "${1:0:$2-1}"; else printf '%s' "$1"; fi
}

# Fit TEXT into exactly WIDTH columns, marking a cut with "~".
fit() {
    local text="$1" width="$2"
    if ((${#text} > width)); then
        printf '%s~' "${text:0:width-1}"
    else
        printf '%-*s' "$width" "$text"
    fi
}

short_digest() { local d="${1##*@sha256:}"; printf '%s' "${d:0:12}"; }

# ---------------------------------------------------------------------------------------
# Probes. Each one has its own timeout so that a hung peer or a stuck gluster command
# delays the screen by seconds, not forever.
# ---------------------------------------------------------------------------------------
unit_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

tcp_open() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

sql_root() {
    timeout 8 docker exec -e MYSQL_PWD="$DB_ROOT_PASSWORD" municipio-db \
        mariadb -uroot --batch --skip-column-names -e "$1" 2>/dev/null
}

# SITE_ADDRESS is required on data VMs only; an arbitrator may have it empty.
site_host() { local s="${CADDY_SITE_ADDRESS:-${SITE_ADDRESS:-}}"; printf '%s' "${s%%:*}"; }
behind_lb() { [[ "${CADDY_SITE_ADDRESS:-${SITE_ADDRESS:-}}" == :80 || -z "$(site_host)" ]]; }

# HTTP status of /healthz as served by the Caddy on ADDRESS. With automatic TLS Caddy
# redirects plain HTTP, so the request goes to 443 with the site name pinned to ADDRESS.
# Prints "CODE" or "CODE untrusted" when the certificate does not verify.
healthz_via_caddy() {
    local address="$1" code
    if behind_lb; then
        curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${address}/healthz" 2>/dev/null
        return
    fi
    local site; site="$(site_host)"
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' --resolve "${site}:443:${address}" \
        "https://${site}/healthz" 2>/dev/null)"
    if [[ "$code" == 000 ]]; then
        code="$(curl -sk -o /dev/null -m 5 -w '%{http_code}' --resolve "${site}:443:${address}" \
            "https://${site}/healthz" 2>/dev/null)"
        [[ "$code" == 000 ]] || code="$code untrusted"
    fi
    printf '%s' "$code"
}

peer_name() { [[ "$NODE_NAME" == "$PRIMARY_NODE_NAME" ]] && echo "$SECONDARY_NODE_NAME" || echo "$PRIMARY_NODE_NAME"; }
peer_address() { [[ "$NODE_NAME" == "$PRIMARY_NODE_NAME" ]] && echo "$SECONDARY_NODE_ADDRESS" || echo "$PRIMARY_NODE_ADDRESS"; }
node_label() {
    if [[ "$NODE_ROLE" == arbiter ]]; then echo arbitrator
    elif [[ "$DEPLOYMENT_MODE" == standalone ]]; then echo standalone
    elif [[ "$NODE_NAME" == "$PRIMARY_NODE_NAME" ]]; then echo primary
    else echo secondary
    fi
}


# ---------------------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------------------
check_config() {
    local err
    MUNICIPIO_ENV_FILE="${MUNICIPIO_ENV_FILE:-/etc/municipio/municipio.env}"
    # load_config exits on the first invalid value, so it is tried in a subshell first.
    if ! err="$( (load_config) 2>&1 >/dev/null)"; then
        err="${err##*ERROR: }"
        record config FAIL 'municipio.env' "${err:-invalid}" \
            "Correct $MUNICIPIO_ENV_FILE; every other check needs a valid configuration"
        return 1
    fi
    load_config
    record config OK 'municipio.env' "valid: $DEPLOYMENT_MODE, role=$NODE_ROLE, swarm=$DOCKER_SWARM"
    if [[ "$DEPLOYMENT_MODE" != standalone && "$NODE_ROLE" == data ]]; then
        # The settings that must be identical on both data VMs, hashed so the two screens
        # can be compared at a glance. Passwords are left out on purpose.
        local fp
        fp="$(printf '%s\n' "$DEPLOYMENT_MODE" "$DOCKER_SWARM" "$SITE_ADDRESS" \
            "${CADDY_SITE_ADDRESS:-}" "$MUNICIPIO_IMAGE" "$MARIADB_IMAGE" "$CADDY_IMAGE" \
            "$DB_NAME" "$DB_USER" "$PRIMARY_NODE_NAME" "$PRIMARY_NODE_ADDRESS" \
            "$SECONDARY_NODE_NAME" "$SECONDARY_NODE_ADDRESS" "${ARBITRATOR_NODE_ADDRESS:-}" \
            | sha256sum | cut -c1-8)"
        record config INFO 'shared settings' "fingerprint $fp - must match on the peer VM"
    fi
}

check_host() {
    local path used mount seen=' '
    if [[ "$NODE_ROLE" == data ]]; then
        if unit_active docker; then
            record host OK 'docker.service' 'active'
        else
            record host FAIL 'docker.service' 'not active' 'sudo systemctl status docker; sudo journalctl -u docker -n 50'
        fi
    fi
    for path in / "${DB_DATA_ROOT:-}" "${GLUSTER_BRICK:-}" "${BACKUP_ROOT:-}"; do
        [[ -n "$path" && -e "$path" ]] || continue
        read -r used mount < <(df -P "$path" 2>/dev/null | awk 'NR==2 {print $5+0, $6}')
        [[ -n "${mount:-}" && "$seen" != *" $mount "* ]] || continue
        seen="$seen$mount "
        if ((used >= 90)); then
            record host FAIL "disk $mount" "${used}% used" 'Free space; MariaDB and Gluster stop writing on a full disk'
        elif ((used >= 80)); then
            record host WARN "disk $mount" "${used}% used" 'Free space before it reaches 90%'
        else
            record host OK "disk $mount" "${used}% used"
        fi
    done
}

# check_container COMPONENT CONTAINER EXPECTED_IMAGE SERVICE
check_container() {
    local comp="$1" name="$2" expected="$3" service="$4" info state health image restarts
    local COMPOSE_HINT="sudo docker compose -p municipio --env-file $MUNICIPIO_ENV_FILE -f $INSTALL_ROOT/compose.yaml up -d --no-deps"
    info="$(timeout 5 docker inspect -f \
        '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.Config.Image}}|{{.RestartCount}}' \
        "$name" 2>/dev/null)"
    if [[ -z "$info" ]]; then
        record "$comp" FAIL container "$name does not exist" "$COMPOSE_HINT $service"
        return 1
    fi
    IFS='|' read -r state health image restarts <<< "$info"
    local detail="$state, $health"
    ((restarts > 0)) && detail="$detail, $restarts restarts"
    if [[ "$state" != running ]]; then
        record "$comp" FAIL container "$detail" "sudo docker logs --tail 50 $name; then: $COMPOSE_HINT $service"
    elif [[ "$health" == unhealthy ]]; then
        record "$comp" FAIL container "$detail" "sudo docker inspect -f '{{json .State.Health.Log}}' $name"
    elif [[ "$health" == starting ]]; then
        record "$comp" WARN container "$detail" 'Still inside its start period; wait and re-check'
    else
        record "$comp" OK container "$detail"
    fi
    # Every node must run exactly the pinned digest; drift means two nodes can run
    # different code against the same replicated database and files.
    if [[ "$image" != "$expected" ]]; then
        record "$comp" WARN image "runs $(short_digest "$image"), config pins $(short_digest "$expected")" \
            "Redeploy so the container matches municipio.env"
    else
        record "$comp" OK image "pinned $(short_digest "$image")"
    fi
}

check_proxy() {
    check_container caddy municipio-caddy "$CADDY_IMAGE" caddy
    local code
    code="$(healthz_via_caddy 127.0.0.1)"
    case "$code" in
        200) record caddy OK 'route /healthz' 'HTTP 200 through Caddy' ;;
        404) record caddy OK 'route /healthz' 'HTTP 404: Caddy answers, marker absent' ;;
        *untrusted*) record caddy WARN 'TLS certificate' "HTTP ${code% *} only without verification" \
            'sudo docker logs municipio-caddy 2>&1 | grep -i acme | tail' ;;
        *) record caddy FAIL 'route /healthz' "HTTP ${code:-000} from local Caddy" 'sudo docker logs --tail 50 municipio-caddy' ;;
    esac
    if ! behind_lb && command -v openssl >/dev/null 2>&1; then
        local end days
        end="$(timeout 5 openssl s_client -connect 127.0.0.1:443 -servername "$(site_host)" </dev/null 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
        if [[ -n "$end" ]]; then
            days=$((($(date -d "$end" +%s) - $(date +%s)) / 86400))
            # Caddy renews 30 days before expiry, so less than three weeks means renewal is failing.
            if ((days < 7)); then
                record caddy FAIL 'certificate expiry' "$days days left" 'sudo docker logs municipio-caddy 2>&1 | grep -i acme | tail'
            elif ((days < 21)); then
                record caddy WARN 'certificate expiry' "$days days left, renewal overdue" 'sudo docker logs municipio-caddy 2>&1 | grep -i acme | tail'
            else
                record caddy OK 'certificate expiry' "$days days left"
            fi
        fi
    fi
}

check_application() {
    if [[ "$DOCKER_SWARM" == 1 ]]; then
        local task
        task="$(timeout 5 docker ps -q --filter label=com.docker.swarm.service.name="$(swarm_service_name)" \
            --filter status=running 2>/dev/null | head -n 1)"
        if [[ -z "$task" ]]; then
            record app FAIL 'swarm task' 'no running task on this VM' \
                'On the manager: sudo docker service ps municipio_municipio --no-trunc'
        else
            check_container app "$task" "$MUNICIPIO_IMAGE" municipio
        fi
    else
        check_container app municipio-app "$MUNICIPIO_IMAGE" municipio
    fi
    local result code secs ms
    result="$(curl -s -o /dev/null -m 10 -w '%{http_code} %{time_total}' \
        "http://${APP_BIND_ADDRESS:-127.0.0.1}:${APP_BIND_PORT:-8080}/" 2>/dev/null)"
    read -r code secs <<< "${result:-000 0}"
    ms="$(awk -v s="$secs" 'BEGIN {printf "%d", s * 1000}')"
    if [[ "$code" == 000 ]]; then
        record app FAIL 'HTTP on loopback' "no answer on ${APP_BIND_ADDRESS:-127.0.0.1}:${APP_BIND_PORT:-8080}" \
            'sudo docker logs --tail 50 municipio-app'
    elif ((code >= 400)); then
        record app FAIL 'HTTP on loopback' "HTTP $code in ${ms} ms" 'sudo docker logs --tail 50 municipio-app'
    elif ((ms > 2000)); then
        record app WARN 'HTTP on loopback' "HTTP $code but slow: ${ms} ms"
    else
        record app OK 'HTTP on loopback' "HTTP $code in ${ms} ms"
    fi
}

check_database() {
    check_container db municipio-db "$MARIADB_IMAGE" db || return
    if [[ -S "${DB_SOCKET_DIR}/mysqld.sock" ]]; then
        record db OK 'socket on host' "${DB_SOCKET_DIR}/mysqld.sock"
    else
        record db FAIL 'socket on host' "missing in ${DB_SOCKET_DIR}" \
            'The application cannot reach MariaDB; check DB_SOCKET_UID/GID and: sudo docker logs municipio-db'
    fi
    local flags
    flags="$(sql_root 'SELECT @@skip_networking, @@read_only')"
    if [[ -z "$flags" ]]; then
        record db FAIL 'root login' 'no answer (starting, state transfer, or wrong DB_ROOT_PASSWORD)' \
            'sudo docker logs --tail 50 municipio-db'
        return
    fi
    local skip_net read_only
    read -r skip_net read_only <<< "$flags"
    if [[ "$skip_net" == 1 ]]; then
        record db WARN 'server phase' 'entrypoint init server, not the real server yet'
    fi
    if [[ "$read_only" == 1 ]]; then
        record db WARN 'read_only' 'database is read-only' 'sudo /scripts/maintenance.municipio.sh off'
    fi
    local tables
    tables="$(timeout 8 docker exec -e MYSQL_PWD="$DB_PASSWORD" municipio-db mariadb -u"$DB_USER" \
        --batch --skip-column-names \
        -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DB_NAME}'" 2>/dev/null)"
    if [[ -z "$tables" ]]; then
        record db FAIL 'application login' "$DB_USER cannot log in to $DB_NAME" \
            'sudo /scripts/failover.municipio.sh provision-database'
    elif ((tables == 0)); then
        record db WARN 'application login' "login ok, $DB_NAME has no tables yet"
    else
        record db OK 'application login' "login ok, $tables tables"
    fi
}

check_galera() {
    local status
    status="$(sql_root "SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_ready','wsrep_connected',
        'wsrep_cluster_status','wsrep_cluster_size','wsrep_local_state_comment',
        'wsrep_flow_control_paused','wsrep_cluster_state_uuid')")"
    gv() { printf '%s\n' "$status" | awk -v k="$1" '$1 == k {print $2}'; }
    local expected=2
    [[ "$DEPLOYMENT_MODE" == cluster-arbitrator ]] && expected=3

    if [[ -f "$(galera_bootstrap_marker)" ]]; then
        if [[ "$(gv wsrep_cluster_size)" -ge 2 ]] 2>/dev/null; then
            record galera FAIL 'bootstrap flag' 'ACTIVE and the peer has joined: a reboot forms a 2nd cluster' \
                'sudo /scripts/cluster.municipio.sh clear-bootstrap-flag'
        else
            record galera WARN 'bootstrap flag' 'ACTIVE, waiting for the peer to join' \
                'Join the peer, then: sudo /scripts/cluster.municipio.sh clear-bootstrap-flag'
        fi
    fi
    if [[ ! -f "$CONFIG_ROOT/cluster-initialized" ]]; then
        if [[ "$NODE_NAME" == "$PRIMARY_NODE_NAME" ]]; then
            record galera WARN 'cluster setup' 'this VM has not bootstrapped the cluster' 'sudo /scripts/cluster.municipio.sh bootstrap'
        else
            record galera WARN 'cluster setup' 'this VM has not joined the cluster' 'sudo /scripts/cluster.municipio.sh join'
        fi
    fi
    if [[ -z "$status" ]]; then
        record galera FAIL 'wsrep status' 'MariaDB does not answer' 'See the db rows above'
        return
    fi

    if [[ "$(gv wsrep_cluster_status)" == Primary ]]; then
        record galera OK 'component' 'Primary: accepts writes'
    else
        record galera FAIL 'component' "$(gv wsrep_cluster_status): refuses writes" \
            'Never bootstrap twice; see docs/failover.md before promoting'
    fi
    if [[ "$(gv wsrep_ready)" == ON && "$(gv wsrep_connected)" == ON ]]; then
        record galera OK 'ready/connected' 'ON/ON'
    else
        record galera FAIL 'ready/connected' "$(gv wsrep_ready)/$(gv wsrep_connected)" 'sudo docker logs --tail 80 municipio-db'
    fi
    local state; state="$(gv wsrep_local_state_comment)"
    case "$state" in
        Synced) record galera OK 'local state' 'Synced' ;;
        Donor*|Desynced) record galera WARN 'local state' "$state: sending a state transfer" 'Wait for it to finish' ;;
        Joining*|Joined) record galera WARN 'local state' "$state: receiving a state transfer" 'Wait for it to finish' ;;
        *) record galera FAIL 'local state' "${state:-unknown}" 'sudo docker logs --tail 80 municipio-db' ;;
    esac
    local size; size="$(gv wsrep_cluster_size)"
    if ((size >= expected)); then
        record galera OK 'members' "$size of $expected"
    else
        record galera WARN 'members' "$size of $expected: a member is missing" 'Check the peer panel below'
    fi
    local paused; paused="$(gv wsrep_flow_control_paused)"
    if awk -v p="${paused:-0}" 'BEGIN {exit !(p > 0.1)}'; then
        record galera WARN 'flow control' "paused ${paused}: a member cannot keep up"
    fi
    local uuid; uuid="$(gv wsrep_cluster_state_uuid)"
    # Two nodes that each bootstrapped have different UUIDs. Same UUID on both screens
    # is the proof that they are one cluster.
    record galera INFO 'cluster uuid' "${uuid:0:8} - must match on the peer VM"
    GALERA_SIZE="$size" GALERA_EXPECTED="$expected"
}

# Loads PEERS_CONNECTED (space separated addresses) and BRICKS ("address online" lines).
gluster_facts() {
    # A peer can be known by several names (the probed address plus "Other names"), and
    # only connected peers count.
    PEERS_CONNECTED=" $(timeout 10 gluster peer status 2>/dev/null | awk '
        function flush(n) { if (conn) for (n in names) print n; delete names; conn = 0; other = 0 }
        /^Hostname:/ {flush(); names[$2] = 1; next}
        /^State:.*\(Connected\)/ {conn = 1; other = 0; next}
        /^Other names:/ {other = 1; next}
        /^[A-Za-z]+:/ {other = 0; next}
        other && NF {names[$1] = 1}
        END {flush()}' | tr '\n' ' ')"
    BRICKS="$(timeout 10 gluster volume status municipio --xml 2>/dev/null | awk '
        /<node>/ {h = ""; p = ""; s = ""}
        /<hostname>/ {gsub(/.*<hostname>|<\/hostname>.*/, ""); h = $0}
        /<path>/ {gsub(/.*<path>|<\/path>.*/, ""); p = $0}
        /<status>/ {gsub(/.*<status>|<\/status>.*/, ""); s = $0}
        /<\/node>/ {if (p ~ /^\//) print h, s}')"
}

brick_online() { printf '%s\n' "$BRICKS" | awk -v h="$1" '$1 == h {print $2}'; }

check_gluster() {
    if unit_active glusterd; then
        record gluster OK 'glusterd' 'active'
    else
        record gluster FAIL 'glusterd' 'not active' 'sudo systemctl start glusterd; sudo journalctl -u glusterd -n 50'
        return
    fi
    gluster_facts
    local info; info="$(timeout 10 gluster volume info municipio 2>/dev/null)"
    if [[ -z "$info" ]]; then
        record gluster FAIL 'volume municipio' 'does not exist' 'sudo /scripts/cluster.municipio.sh bootstrap (primary VM)'
        return
    fi
    if grep -q '^Status: Started' <<< "$info"; then
        record gluster OK 'volume municipio' 'started'
    else
        record gluster FAIL 'volume municipio' 'not started' 'sudo gluster volume start municipio'
    fi
    local address online
    for address in "$PRIMARY_NODE_ADDRESS" "$SECONDARY_NODE_ADDRESS" ${ARBITRATOR_NODE_ADDRESS:+"$ARBITRATOR_NODE_ADDRESS"}; do
        [[ "$DEPLOYMENT_MODE" == cluster-arbitrator || "$address" != "${ARBITRATOR_NODE_ADDRESS:-}" ]] || continue
        online="$(brick_online "$address")"
        if [[ "$online" == 1 ]]; then
            record gluster OK "brick $address" 'online'
        else
            record gluster FAIL "brick $address" 'offline' "On $address: sudo systemctl restart glusterd"
        fi
    done
    local summary pending split
    summary="$(timeout 15 gluster volume heal municipio info summary 2>/dev/null)"
    pending="$(awk -F: '/heal pending/ {s += $2} END {print s + 0}' <<< "$summary")"
    split="$(awk -F: '/split-brain/ {s += $2} END {print s + 0}' <<< "$summary")"
    if ((split > 0)); then
        record gluster FAIL 'split-brain' "$split entries" 'sudo gluster volume heal municipio info split-brain'
    elif ((pending > 0)); then
        record gluster WARN 'self-heal' "$pending entries pending" 'Normal right after a peer returns; re-check in a few minutes'
    else
        record gluster OK 'self-heal' 'nothing pending'
    fi
}

check_files() {
    if [[ "$DEPLOYMENT_MODE" == standalone ]]; then
        if [[ -d "$DATA_ROOT/uploads" && -d "$DATA_ROOT/cache" ]]; then
            record files OK 'data directories' "$DATA_ROOT on local disk"
        else
            record files FAIL 'data directories' "uploads or cache missing in $DATA_ROOT" 'Re-run the installer'
        fi
        return
    fi
    # Both stat the FUSE mount, which blocks while Gluster is stuck.
    if ! timeout 5 mountpoint -q "$DATA_ROOT"; then
        record files FAIL 'gluster mount' "$DATA_ROOT is not mounted" "sudo mount $DATA_ROOT"
        return
    fi
    local fstype options
    fstype="$(timeout 5 findmnt -no FSTYPE --target "$DATA_ROOT")"
    options="$(timeout 5 findmnt -no OPTIONS --target "$DATA_ROOT")"
    if [[ ",$options," == *,rw,* ]]; then
        record files OK 'gluster mount' "$fstype, read/write"
    else
        record files FAIL 'gluster mount' "$fstype, read-only (quorum lost?)" 'Check the gluster rows and the peer'
    fi
}

check_health() {
    local marker="${HEALTH_ROOT}/healthz" maintenance=0
    [[ -e /run/municipio/maintenance ]] && maintenance=1
    if ((maintenance)); then
        record health WARN 'maintenance mode' 'ON: node is out of rotation on purpose' 'sudo /scripts/maintenance.municipio.sh off'
    fi
    if [[ -f "$marker" ]]; then
        local age=$(($(date +%s) - $(stat -c %Y "$marker")))
        if ((age > 60)); then
            record health WARN 'healthz marker' "present but ${age} s old" 'sudo systemctl status municipio-health.timer'
        else
            record health OK 'healthz marker' "ready, ${age} s old"
        fi
    elif ((maintenance)); then
        record health WARN 'healthz marker' 'absent because of maintenance mode'
    else
        # health.municipio.sh is silent by design; tracing it names the failing check.
        record health FAIL 'healthz marker' 'absent: load balancer skips this VM' \
            'sudo bash -x /scripts/health.municipio.sh 2>&1 | tail -5'
    fi
    if unit_active municipio-health.timer; then
        record health OK 'health timer' 'active, every 10 s'
    else
        record health FAIL 'health timer' 'not active: /healthz is frozen' 'sudo systemctl enable --now municipio-health.timer'
    fi
}

check_network() {
    local listeners; listeners="$(ss -Hltn 2>/dev/null | awk '{print $4}')"
    exposed() { grep -E "[:.]$1\$" <<< "$listeners" | grep -vE '^(127\.|\[?::1\]?:)' ; }
    local port="${APP_BIND_PORT:-8080}"
    if [[ "$DOCKER_SWARM" == 1 ]]; then
        # Swarm cannot bind a published port to loopback; the firewall unit restricts it.
        if unit_active municipio-swarm-firewall.service; then
            record net OK "port $port" 'Swarm port, restricted by firewall unit'
        else
            record net FAIL "port $port" 'Swarm port without the firewall unit' 'sudo systemctl start municipio-swarm-firewall.service'
        fi
    elif [[ -n "$(exposed "$port")" ]]; then
        record net FAIL "port $port" "listens on $(exposed "$port" | head -n1)" 'APP_BIND_ADDRESS must be 127.0.0.1'
    else
        record net OK "port $port" 'loopback only'
    fi
    if [[ -n "$(exposed 3306)" ]]; then
        record net FAIL 'port 3306' "listens on $(exposed 3306 | head -n1)" 'MariaDB must keep bind-address=127.0.0.1'
    else
        record net OK 'port 3306' 'loopback only'
    fi
    local p
    for p in 80 443; do
        [[ "$p" == 443 ]] && behind_lb && continue
        if grep -qE "[:.]$p\$" <<< "$listeners"; then
            record net OK "port $p" 'listening (Caddy)'
        else
            record net FAIL "port $p" 'nothing listening' 'See the caddy rows'
        fi
    done
}

check_swarm() {
    local info state manager
    info="$(timeout 5 docker info --format '{{.Swarm.LocalNodeState}}|{{.Swarm.ControlAvailable}}' 2>/dev/null)"
    IFS='|' read -r state manager <<< "$info"
    if [[ "$state" != active ]]; then
        record swarm FAIL 'membership' "${state:-unknown}" 'See docs/components/swarm.md'
        return
    fi
    if [[ "$manager" != true ]]; then
        record swarm OK 'membership' 'worker; service view only on the manager'
        return
    fi
    record swarm OK 'membership' 'manager'
    local replicas spec
    replicas="$(timeout 5 docker service ls --filter name="$(swarm_service_name)" --format '{{.Replicas}}' 2>/dev/null)"
    replicas="${replicas%% *}"
    if [[ -z "$replicas" ]]; then
        record swarm FAIL 'service' 'municipio_municipio not deployed' 'sudo /scripts/update.municipio.sh'
    elif [[ "${replicas%/*}" == "${replicas#*/}" ]]; then
        record swarm OK 'service tasks' "$replicas running"
    else
        record swarm WARN 'service tasks' "$replicas running" 'sudo docker service ps municipio_municipio --no-trunc'
    fi
    spec="$(timeout 5 docker service inspect -f '{{.Spec.TaskTemplate.ContainerSpec.Image}}' "$(swarm_service_name)" 2>/dev/null)"
    if [[ -n "$spec" && "$spec" != "$MUNICIPIO_IMAGE" ]]; then
        record swarm WARN 'service image' "$(short_digest "$spec"), config pins $(short_digest "$MUNICIPIO_IMAGE")" 'sudo /scripts/update.municipio.sh'
    fi
    local id line host nstate addr label
    for id in $(timeout 5 docker node ls -q 2>/dev/null); do
        line="$(timeout 5 docker node inspect -f \
            '{{.Description.Hostname}}|{{.Status.State}}|{{.Status.Addr}}|{{index .Spec.Labels "municipio.data"}}' "$id" 2>/dev/null)"
        IFS='|' read -r host nstate addr label <<< "$line"
        SWARM_NODE_STATE="$SWARM_NODE_STATE $addr=$nstate/$label"
        if [[ "$nstate" != ready ]]; then
            record swarm FAIL "node $host" "$nstate" "Check docker.service on $addr"
        elif [[ "$label" != true ]]; then
            record swarm WARN "node $host" 'ready, but no municipio.data label: no task' "sudo /scripts/cluster.municipio.sh enable-node $host"
        else
            record swarm OK "node $host" 'ready, runs a task'
        fi
    done
}

check_peer() {
    local name address
    name="$(peer_name)" address="$(peer_address)"
    PEER_TITLE="$name" PEER_ADDRESS="$address"
    local code; code="$(healthz_via_caddy "$address")"
    case "$code" in
        200*) record peer OK 'peer /healthz' 'HTTP 200' ;;
        404*) record peer FAIL 'peer /healthz' "HTTP 404: $name reports itself unhealthy" "Run this monitor on $name" ;;
        *) record peer FAIL 'peer /healthz' "HTTP ${code:-000}: $name unreachable on 80/443" "Check $name is up, and the firewall" ;;
    esac
    if [[ -n "${GALERA_SIZE:-}" ]]; then
        if ((GALERA_SIZE >= GALERA_EXPECTED)); then
            record peer OK 'peer in galera' "$GALERA_SIZE of $GALERA_EXPECTED members"
        else
            record peer FAIL 'peer in galera' "$GALERA_SIZE of $GALERA_EXPECTED members" \
                "On $name: sudo docker logs --tail 80 municipio-db"
        fi
    fi
    local port
    for port in 4567 24007; do
        if tcp_open "$address" "$port"; then
            record peer OK "peer port $port" 'open'
        else
            record peer FAIL "peer port $port" 'closed or filtered' "Allow $port between $NODE_ADDRESS and $address"
        fi
    done
    if [[ "$PEERS_CONNECTED" == *" $address "* ]]; then
        record peer OK 'peer in gluster' 'peer connected'
    else
        record peer FAIL 'peer in gluster' 'peer not connected' "On $name: sudo systemctl status glusterd"
    fi
    if [[ "$DOCKER_SWARM" == 1 && -n "$SWARM_NODE_STATE" ]]; then
        case "$SWARM_NODE_STATE" in
            *" $address=ready/true"*) record peer OK 'peer in swarm' 'ready, runs a task' ;;
            *" $address="*) record peer WARN 'peer in swarm' 'present but not running a task' ;;
            *) record peer FAIL 'peer in swarm' 'not a member' 'See docs/components/swarm.md' ;;
        esac
    fi
}

check_arbitrator_link() {
    [[ "$DEPLOYMENT_MODE" == cluster-arbitrator ]] || return 0
    if tcp_open "$ARBITRATOR_NODE_ADDRESS" 4567; then
        record arb OK 'arbitrator garbd' "port 4567 open on $ARBITRATOR_NODE_ADDRESS"
    else
        record arb FAIL 'arbitrator garbd' "port 4567 closed on $ARBITRATOR_NODE_ADDRESS" \
            'On the arbitrator: sudo /scripts/cluster.municipio.sh start-arbitrator'
    fi
    if [[ "$PEERS_CONNECTED" == *" $ARBITRATOR_NODE_ADDRESS "* ]]; then
        record arb OK 'arbitrator gluster' 'peer connected'
    else
        record arb FAIL 'arbitrator gluster' 'peer not connected' 'On the arbitrator: sudo systemctl status glusterd'
    fi
}

check_arbiter_host() {
    local unit
    for unit in garb glusterd; do
        if unit_active "$unit"; then
            record arb OK "$unit" 'active'
        else
            record arb FAIL "$unit" 'not active' 'sudo /scripts/cluster.municipio.sh start-arbitrator'
        fi
    done
    gluster_facts
    local address name
    for address in "$PRIMARY_NODE_ADDRESS" "$SECONDARY_NODE_ADDRESS"; do
        [[ "$address" == "$PRIMARY_NODE_ADDRESS" ]] && name="$PRIMARY_NODE_NAME" || name="$SECONDARY_NODE_NAME"
        local comp=peer1; [[ "$address" == "$SECONDARY_NODE_ADDRESS" ]] && comp=peer2
        local code; code="$(healthz_via_caddy "$address")"
        if [[ "$code" == 200* ]]; then
            record "$comp" OK '/healthz' 'HTTP 200'
        else
            record "$comp" FAIL '/healthz' "HTTP ${code:-000}: unreachable or unhealthy" "Run this monitor on $name"
        fi
        if tcp_open "$address" 4567; then
            record "$comp" OK 'galera port 4567' open
        else
            record "$comp" FAIL 'galera port 4567' closed "Allow 4567 from $NODE_ADDRESS to $address"
        fi
        if [[ "$PEERS_CONNECTED" == *" $address "* ]]; then
            record "$comp" OK 'gluster peer' connected
        else
            record "$comp" FAIL 'gluster peer' 'not connected' "On $name: sudo systemctl status glusterd"
        fi
        if [[ "$(brick_online "$address")" == 1 ]]; then
            record "$comp" OK 'gluster brick' online
        else
            record "$comp" FAIL 'gluster brick' offline "On $name: sudo systemctl restart glusterd"
        fi
    done
    if [[ "$(brick_online "$NODE_ADDRESS")" == 1 ]]; then
        record arb OK 'arbiter brick' online
    else
        record arb FAIL 'arbiter brick' offline 'sudo systemctl restart glusterd'
    fi
}

check_backups() {
    local latest age
    latest="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -n | tail -n 1)"
    if [[ -z "$latest" ]]; then
        record backup INFO 'latest backup' "none in $BACKUP_ROOT" 'sudo /scripts/backup.municipio.sh manual'
        return
    fi
    age=$((($(date +%s) - ${latest%%.*}) / 86400))
    # No backup timer is installed, so an old backup is information, not a fault.
    record backup INFO 'latest backup' "${latest#* }, $age days old (copy it off the VM)"
}

collect() {
    SWARM_NODE_STATE='' PEERS_CONNECTED=' ' BRICKS='' GALERA_SIZE='' GALERA_EXPECTED=2
    check_config || return 0
    check_host
    if [[ "$NODE_ROLE" == arbiter ]]; then
        check_arbiter_host
        return 0
    fi
    check_proxy
    check_application
    check_database
    check_files
    check_health
    check_network
    [[ "$DOCKER_SWARM" == 1 ]] && check_swarm
    if [[ "$DEPLOYMENT_MODE" != standalone ]]; then
        check_galera
        check_gluster
        check_peer
        check_arbitrator_link
    fi
    check_backups
}

# ---------------------------------------------------------------------------------------
# Rendering. The screen is 80 columns of plain ASCII, so it survives SSH, tmux, a
# serial console and a pasted ticket. Colour only repeats what the tag already says.
# ---------------------------------------------------------------------------------------

# One line inside a node box: "| [ OK ] label     detail |", WIDTH inner columns.
box_row() {
    local width="$1" comp="$2" label="$3"
    printf '| %s %-9s %s |' "$(tag "$(comp_status "$comp")")" "$label" "$(fit "$(comp_detail "$comp")" $((width - 19)))"
}
box_text() { printf '| %s |' "$(fit "$2" $(($1 - 2)))"; }
box_rule() { printf '+%s+' "$(printf '%*s' "$1" '' | tr ' ' '-')"; }

# Print two blocks of lines next to each other. Box lines have a fixed visible width, so
# only lines missing from the shorter left block need padding; colour codes never do.
side_by_side() {
    local -a left=() right=()
    local line i n
    while IFS= read -r line; do left+=("$line"); done <<< "$1"
    while IFS= read -r line; do right+=("$line"); done <<< "$2"
    n=${#left[@]}
    ((${#right[@]} > n)) && n=${#right[@]}
    for ((i = 0; i < n; i++)); do
        printf '%s %s\n' "${left[i]:-$(printf '%*s' "$3" '')}" "${right[i]:-}"
    done
}

render_header() {
    local worst=OK fails=0 warns=0 i
    for ((i = 0; i < ROWS; i++)); do
        case "${R_STATUS[i]}" in FAIL) fails=$((fails + 1)) ;; WARN) warns=$((warns + 1)) ;; esac
    done
    ((warns)) && worst=WARN
    ((fails)) && worst=FAIL
    OVERALL="$worst"
    printf '%sMUNICIPIO MONITOR%s  %s  (%s)  %s\n' "$C_B" "$C_0" "${NODE_NAME:-?}" "$(node_label 2>/dev/null || echo '?')" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'mode=%s  swarm=%s  site=%s\n' "${DEPLOYMENT_MODE:-?}" "${DOCKER_SWARM:-?}" "${SITE_ADDRESS:--}"
    printf 'OVERALL %s  %d failing, %d warnings, %d checks\n\n' "$(tag "$worst")" "$fails" "$warns" "$ROWS"
}

# The local VM as a vertical request path: the same flow as docs/architecture.md.
local_box_lines() {
    local w="$1"
    box_rule "$w"; echo
    box_text "$w" "THIS VM  ${NODE_NAME}  ${NODE_ADDRESS}"; echo
    box_text "$w" ''; echo
    box_row "$w" caddy caddy; echo
    box_text "$w" '         |  127.0.0.1:8080'; echo
    box_row "$w" app app; echo
    box_text "$w" '         |  unix socket'; echo
    box_row "$w" db db; echo
    box_text "$w" ''; echo
    box_row "$w" files files; echo
    box_row "$w" health healthz; echo
    box_row "$w" net ports; echo
    [[ "${DOCKER_SWARM:-0}" == 1 ]] && { box_row "$w" swarm swarm; echo; }
    box_rule "$w"; echo
}

peer_box_lines() {
    local w="$1"
    box_rule "$w"; echo
    box_text "$w" "PEER VM  ${PEER_TITLE:-?}  ${PEER_ADDRESS:-?}"; echo
    box_text "$w" '(as seen from this VM)'; echo
    local i
    for ((i = 0; i < ROWS; i++)); do
        [[ "${R_COMP[i]}" == peer ]] || continue
        printf '| %s %s |\n' "$(tag "${R_STATUS[i]}")" "$(fit "${R_CHECK[i]#peer }: ${R_DETAIL[i]}" $((w - 9)))"
    done
    box_rule "$w"; echo
}

render_standalone() {
    printf '%28s%s\n' '' 'Internet'
    printf '%28s%s\n' '' '   |  :80 :443'
    printf '%28s%s\n' '' '   v'
    local_box_lines 70 | sed 's/^/     /'
}

render_cluster() {
    printf '%9s%s\n' '' 'HTTP load balancer  (sends traffic only where /healthz = 200)'
    printf '%19s%s%39s%s\n' '' '|' '' '|'
    printf '%19s%s%39s%s\n' '' 'v' '' 'v'
    side_by_side "$(local_box_lines 37)" "$(peer_box_lines 37)" 39
    echo
    printf ' REPLICATION between the VMs\n'
    printf '   db    <== Galera ==>  db     %s %s\n' "$(tag "$(comp_status galera)")" "$(clip "$(comp_detail galera)" 40)"
    printf '   files <== Gluster ==> files  %s %s\n' "$(tag "$(comp_status gluster)")" "$(clip "$(comp_detail gluster)" 40)"
    if [[ "$DEPLOYMENT_MODE" == cluster-arbitrator ]]; then
        printf '   arbitrator (3rd vote)        %s %s\n' "$(tag "$(comp_status arb)")" "$(clip "$(comp_detail arb)" 40)"
    fi
}

render_arbiter() {
    local w=37
    {
        box_rule "$w"; echo
        box_text "$w" "ARBITRATOR  ${NODE_NAME}  ${NODE_ADDRESS}"; echo
        box_text "$w" 'third vote, holds no data'; echo
        box_row "$w" arb garbd; echo
        box_row "$w" host disk; echo
        box_rule "$w"; echo
    } | sed 's/^/                      /'
    printf '%21s%s\n' '' "  /  votes (Galera 4567) and   \\"
    printf '%21s%s\n' '' " /   quorum (Gluster 24007)     \\"
    local p1 p2 i
    for i in 1 2; do
        local comp="peer$i" name addr
        [[ "$i" == 1 ]] && name="$PRIMARY_NODE_NAME" addr="$PRIMARY_NODE_ADDRESS" || name="$SECONDARY_NODE_NAME" addr="$SECONDARY_NODE_ADDRESS"
        local out; out="$(
            box_rule "$w"; echo
            box_text "$w" "DATA VM  $name  $addr"; echo
            local j
            for ((j = 0; j < ROWS; j++)); do
                [[ "${R_COMP[j]}" == "$comp" ]] || continue
                printf '| %s %s |\n' "$(tag "${R_STATUS[j]}")" "$(fit "${R_CHECK[j]}: ${R_DETAIL[j]}" $((w - 9)))"
            done
            box_rule "$w"; echo)"
        [[ "$i" == 1 ]] && p1="$out" || p2="$out"
    done
    side_by_side "$p1" "$p2" 39
}

render_table() {
    printf '\n %-8s %-18s %-6s %s\n' LAYER CHECK STATUS DETAIL
    printf ' %s\n' '-------- ------------------ ------ ------------------------------------------'
    local i last=''
    for ((i = 0; i < ROWS; i++)); do
        local comp="${R_COMP[i]}"
        [[ "$comp" == "$last" ]] && comp=''
        last="${R_COMP[i]}"
        printf ' %-8s %s %s %s\n' "$comp" "$(fit "${R_CHECK[i]}" 18)" "$(tag "${R_STATUS[i]}")" "$(clip "${R_DETAIL[i]}" 43)"
    done
}

render_actions() {
    local i n=0
    for ((i = 0; i < ROWS; i++)); do
        [[ "${R_STATUS[i]}" == FAIL || "${R_STATUS[i]}" == WARN ]] || continue
        ((n++ == 0)) && printf '\n %sWHAT TO DO%s (most severe first)\n' "$C_B" "$C_0"
    done
    ((n)) || { printf '\n Nothing to do. Compare the fingerprint and cluster uuid with the peer VM.\n'; return; }
    local want
    for want in FAIL WARN; do
        for ((i = 0; i < ROWS; i++)); do
            [[ "${R_STATUS[i]}" == "$want" ]] || continue
            # The problem is wrapped to the screen; the hint is a command to paste, so it
            # is printed whole even when it is wider.
            printf '%s %s: %s\n' "${R_COMP[i]}" "${R_CHECK[i]}" "${R_DETAIL[i]}" | fold -s -w 71 \
                | awk -v t="$(tag "$want")" 'NR == 1 {print " " t " " $0; next} {print "        " $0}'
            [[ -z "${R_HINT[i]}" ]] || printf '        -> %s\n' "${R_HINT[i]}"
        done
    done
}

render() {
    render_header
    if [[ "${S_config:-}" == FAIL ]]; then
        render_table
        render_actions
        return
    fi
    if [[ "$NODE_ROLE" == arbiter ]]; then
        render_arbiter
    elif [[ "$DEPLOYMENT_MODE" == standalone ]]; then
        render_standalone
    else
        render_cluster
    fi
    render_table
    render_actions
}

# ---------------------------------------------------------------------------------------
# Demo data: fixed results, no probes, so the screen can be reviewed on any machine.
# ---------------------------------------------------------------------------------------
demo_collect() {
    NODE_NAME=kris1 NODE_ADDRESS=10.20.0.11 NODE_ROLE=data DOCKER_SWARM=0 SITE_ADDRESS=www.example.se
    PRIMARY_NODE_NAME=kris1 PRIMARY_NODE_ADDRESS=10.20.0.11 SECONDARY_NODE_NAME=kris2 SECONDARY_NODE_ADDRESS=10.20.0.12
    ARBITRATOR_NODE_ADDRESS=10.20.0.13
    PEER_TITLE=kris2 PEER_ADDRESS=10.20.0.12
    case "$1" in
        standalone) DEPLOYMENT_MODE=standalone NODE_NAME=municipio-01 ;;
        arbiter) DEPLOYMENT_MODE=cluster-arbitrator NODE_ROLE=arbiter NODE_NAME=arbiter NODE_ADDRESS=10.20.0.13 ;;
        *) DEPLOYMENT_MODE=cluster-manual ;;
    esac
    record config OK 'municipio.env' "valid: $DEPLOYMENT_MODE, role=$NODE_ROLE, swarm=0"
    if [[ "$NODE_ROLE" == arbiter ]]; then
        record host OK 'disk /' '31% used'
        record arb OK garb active
        record arb OK glusterd active
        record arb OK 'arbiter brick' online
        record peer1 OK '/healthz' 'HTTP 200'
        record peer1 OK 'galera port 4567' open
        record peer1 OK 'gluster brick' online
        record peer2 FAIL '/healthz' 'HTTP 000: unreachable or unhealthy' 'Run this monitor on kris2'
        record peer2 FAIL 'galera port 4567' closed 'Allow 4567 from 10.20.0.13 to 10.20.0.12'
        record peer2 FAIL 'gluster brick' offline 'On kris2: sudo systemctl restart glusterd'
        return
    fi
    [[ "$DEPLOYMENT_MODE" == standalone ]] || record config INFO 'shared settings' 'fingerprint 3fa9c2e1 - must match on the peer VM'
    record host OK docker.service active
    record host OK 'disk /' '42% used'
    record host WARN 'disk /var/lib/municipio' '84% used' 'Free space before it reaches 90%'
    record caddy OK container 'running, healthy'
    record caddy OK image 'pinned 0c994536bddb'
    record caddy OK 'route /healthz' 'HTTP 200 through Caddy'
    record caddy OK 'certificate expiry' '71 days left'
    record app OK container 'running, healthy'
    record app OK image 'pinned 9a7a2502fa3e'
    record app OK 'HTTP on loopback' 'HTTP 200 in 41 ms'
    record db OK container 'running, healthy'
    record db OK image 'pinned 70cc072b29b4'
    record db OK 'socket on host' '/var/lib/municipio/mysqld-socket/mysqld.sock'
    record db OK 'application login' 'login ok, 57 tables'
    if [[ "$DEPLOYMENT_MODE" == standalone ]]; then
        record files OK 'data directories' '/srv/municipio/data on local disk'
    else
        record files OK 'gluster mount' 'fuse.glusterfs, read/write'
    fi
    record health OK 'healthz marker' 'ready, 4 s old'
    record health OK 'health timer' 'active, every 10 s'
    record net OK 'port 8080' 'loopback only'
    record net OK 'port 3306' 'loopback only'
    record net OK 'port 80' 'listening (Caddy)'
    record net OK 'port 443' 'listening (Caddy)'
    if [[ "$DEPLOYMENT_MODE" != standalone ]]; then
        record galera FAIL 'bootstrap flag' 'ACTIVE and the peer has joined: a reboot forms a 2nd cluster' \
            'sudo /scripts/cluster.municipio.sh clear-bootstrap-flag'
        record galera OK component 'Primary: accepts writes'
        record galera OK 'ready/connected' 'ON/ON'
        record galera OK 'local state' Synced
        record galera OK members '2 of 2'
        record galera INFO 'cluster uuid' '8c1f02aa - must match on the peer VM'
        record gluster OK glusterd active
        record gluster OK 'volume municipio' started
        record gluster OK 'brick 10.20.0.11' online
        record gluster OK 'brick 10.20.0.12' online
        record gluster WARN self-heal '3 entries pending' 'Normal right after a peer returns; re-check in a few minutes'
        record peer OK 'peer /healthz' 'HTTP 200'
        record peer OK 'peer in galera' '2 of 2 members'
        record peer OK 'peer port 4567' open
        record peer OK 'peer port 24007' open
        record peer OK 'peer in gluster' 'peer connected'
    fi
    record backup INFO 'latest backup' '20260928T021500Z-manual, 1 days old (copy it off the VM)'
}

# ---------------------------------------------------------------------------------------
snapshot() {
    if [[ -n "$DEMO" ]]; then
        demo_collect "$DEMO"
    else
        collect
    fi
    render
    case "$OVERALL" in FAIL) return 2 ;; WARN) return 1 ;; *) return 0 ;; esac
}

if [[ -z "$DEMO" ]]; then
    [[ "$(id -u)" == 0 ]] || { echo 'Run as root: sudo /scripts/monitor.municipio.sh' >&2; exit 2; }
    # Installed by install/maintenance.sh; the repository copy is scripts/lib/common.sh.
    # shellcheck disable=SC1091
    source /usr/local/lib/municipio/common.sh
fi

if ((WATCH)); then
    trap 'printf "\n"; exit 0' INT TERM
    while true; do
        # Collect into a buffer first, so the screen is replaced in one write instead of
        # flickering while slow probes run. The subshell also resets every result.
        frame="$(snapshot)"
        printf '\033[H\033[2J%s\n\n %s(refresh every %ss, Ctrl-C to quit)%s\n' "$frame" "$C_DIM" "$INTERVAL" "$C_0"
        sleep "$INTERVAL"
    done
fi
snapshot
