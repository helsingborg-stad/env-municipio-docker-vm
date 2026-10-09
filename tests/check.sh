#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

while IFS= read -r file; do
    bash -n "$file"
done < <(find bin scripts tests -type f -name '*.sh' -print)
sh -n installer.sh
bash -n uninstaller.sh

if command -v shellcheck >/dev/null 2>&1; then
    find bin scripts tests -type f -name '*.sh' -print0 | xargs -0 shellcheck
    shellcheck -s sh installer.sh
    shellcheck uninstaller.sh
else
    echo 'SKIP: shellcheck is not installed'
fi

if docker compose version >/dev/null 2>&1; then
    docker compose --env-file .env.example -f compose.yaml config >/dev/null
    # Caddy must not restart before Gluster mounts, and its /data must come from
    # the same DATA_ROOT that Gluster replicates in cluster mode.
    docker compose --env-file .env.example -f compose.yaml config --format json | python3 -c '
import json, sys
config = json.load(sys.stdin)
caddy = config["services"]["caddy"]
assert caddy["restart"] == "no"
assert any(mount["target"] == "/data" and mount["source"] == "/srv/municipio/data/caddy"
           for mount in caddy["volumes"])
'
    # The Galera bootstrap overlay must merge onto the same project.
    docker compose --env-file .env.example \
        -f compose.yaml -f compose.galera-bootstrap.yaml config | grep -q -- '--wsrep-new-cluster'
    # Every long-running service is a container; nothing is left for the host to install.
    for service in db caddy municipio; do
        docker compose --env-file .env.example -f compose.yaml config --services | grep -qx "$service"
    done
    # `docker stack config` interpolates from the environment, so the example values are
    # sourced inside a subshell. Leaking them into this script would let the negative
    # configuration tests below inherit a value the fixture deliberately removed.
    (
        set -a
        # shellcheck disable=SC1091
        source .env.example
        set +a
        docker stack config -c compose.swarm.yaml | grep -q 'mode: global'
        docker stack config -c compose.swarm.yaml | grep -q 'node.labels.municipio.data == true'
        # Swarm manages the application only; MariaDB and Caddy stay per-VM Compose services.
        if docker stack config -c compose.swarm.yaml | grep -qE '^  (db|caddy):'; then
            echo 'ERROR: compose.swarm.yaml must contain the application service only' >&2
            exit 1
        fi
    )
else
    echo 'SKIP: docker compose is not installed'
fi

# The configuration file is read by bash `source` and by Compose's dotenv parser. A
# password that the two decode differently would create the database account with one
# string and hand the container another, locking the site out of its own database.
if docker compose version >/dev/null 2>&1; then
    quoting_env="$(mktemp)"
    quoting_dir="$(mktemp -d)"
    quoting_yaml="$quoting_dir/compose.yaml"
    # The literal $ and backslash are the point of this fixture, not an expansion.
    # shellcheck disable=SC2016
    probe_value='pa$$w0rd \back #hash;semi&pipe| "dq" a b'
    printf "TRICKY='%s'\n" "$probe_value" > "$quoting_env"
    cat > "$quoting_yaml" <<'YML'
services:
  probe:
    image: alpine
    environment:
      VALUE: ${TRICKY}
    command: ["sh", "-c", "printf '%s' \"$$VALUE\""]
YML
    from_bash="$(set -a; # shellcheck disable=SC1090
        source "$quoting_env"; set +a; printf '%s' "$TRICKY")"
    from_compose="$(docker compose --env-file "$quoting_env" -f "$quoting_yaml" run --rm -q probe)"
    rm -f "$quoting_env"
    rm -rf "$quoting_dir"
    if [[ "$from_bash" != "$probe_value" || "$from_compose" != "$probe_value" ]]; then
        echo 'ERROR: bash and Docker Compose disagree on the dotenv encoding' >&2
        printf '  expected: [%s]\n  bash:     [%s]\n  compose:  [%s]\n' \
            "$probe_value" "$from_bash" "$from_compose" >&2
        exit 1
    fi
    grep -q "printf \"%s='%s'" bin/interactive-install.sh || {
        echo 'ERROR: the installer no longer single-quotes generated values' >&2
        exit 1
    }
fi

# The wizard's output must stand on its own. Docker Compose reads the installed file
# directly and applies none of validate_config's shell defaults, so a path the wizard
# forgets to write becomes an empty bind-mount source in a real installation while every
# test that starts from .env.example still passes.
if docker compose version >/dev/null 2>&1; then
    wizard_env="$(mktemp)"
    while IFS= read -r name; do
        printf "%s='%s'\n" "$name" "$(sed -n "s/^$name=//p" .env.example)"
    done < <({
        sed -n 's/^write_value \([A-Z_][A-Z0-9_]*\).*/\1/p' bin/interactive-install.sh
        sed -n "s/^COPIED_DEFAULT_NAMES='\(.*\)'$/\1/p" bin/interactive-install.sh | tr ' ' '\n'
    } | grep -E '^[A-Z_][A-Z0-9_]*$' | sort -u) > "$wizard_env"
    if ! docker compose --env-file "$wizard_env" -f compose.yaml config >/dev/null 2>&1; then
        echo 'ERROR: the wizard does not write every value compose.yaml interpolates' >&2
        docker compose --env-file "$wizard_env" -f compose.yaml config 2>&1 \
            | grep -i 'not set\|invalid' | sort -u >&2
        rm -f "$wizard_env"
        exit 1
    fi
    MUNICIPIO_ENV_FILE="$wizard_env" bash -c 'source scripts/lib/common.sh; load_config' >/dev/null
    rm -f "$wizard_env"
fi

# Caddy's boot unit must wait for its data mount, while cluster activation creates
# the directory only after Gluster has mounted it.
grep -Fq 'RequiresMountsFor="@CADDY_DATA_ROOT@"' systemd/municipio-caddy.service.in
grep -Fq 'systemctl enable municipio-caddy.service' scripts/install/maintenance.sh
grep -Fq "tar -C \"\$DATA_ROOT\" -czf \"\$target/files.tar.gz\" uploads cache caddy" scripts/backup.municipio.sh
grep -Fq "install -d -m 0700 \"\$DATA_ROOT/caddy\"" scripts/cluster.municipio.sh
grep -Fq 'CLUSTER_START_WAIT_SECONDS=60' scripts/cluster.municipio.sh
grep -Fq 'peer_is_connected()' scripts/cluster.municipio.sh
grep -Fq 'ensure_volume_started()' scripts/cluster.municipio.sh
grep -Fq 'waiting for Peer in Cluster (Connected)' scripts/cluster.municipio.sh
grep -Fq 'backup_server="$PRIMARY_NODE_ADDRESS"' scripts/cluster.municipio.sh
grep -Fq 'Local Gluster does not know volume municipio yet' scripts/cluster.municipio.sh
grep -Fq "Gluster peer probe to \${name} (\${address}) failed on attempt" scripts/cluster.municipio.sh
grep -Fq "Gluster mount attempt \${attempt} on \${NODE_NAME} (\${NODE_ADDRESS}) failed" scripts/cluster.municipio.sh
grep -Fq "Waiting up to \${CLUSTER_START_WAIT_SECONDS}s for Gluster peer" scripts/cluster.municipio.sh
grep -Fq 'mount_volume --wait-for-volume' scripts/cluster.municipio.sh
grep -Fq "Waiting up to \${CLUSTER_START_WAIT_SECONDS}s for Gluster volume municipio to mount" scripts/cluster.municipio.sh
grep -Fq 'storage file_system /data/caddy' scripts/refresh-sites.municipio.sh
grep -Fq 'dns.providers.loopia' scripts/refresh-sites.municipio.sh
grep -Fq 'dns.providers.namedotcom' scripts/refresh-sites.municipio.sh
grep -Fq 'dns_challenge_override_domain' scripts/refresh-sites.municipio.sh
# The default Caddy image must carry every provider ACME_DNS_PROVIDER accepts.
for module in loopia namedotcom; do
    grep -Fq "github.com/caddy-dns/$module@" docker/caddy/Dockerfile
    grep -Fq "dns.providers.$module" .github/workflows/caddy-image.yml
done

# The installer must not install a database or web server package on data VMs.
if grep -nE 'apt-get install[^|]*\b(mariadb-server|mariadb-client|mariadb-backup|caddy)\b' \
    scripts/install/*.sh; then
    echo 'ERROR: a host database or web server package is being installed' >&2
    exit 1
fi
# Application deployments must never recreate the database container.
if grep -nE 'compose up [^|]*municipio' scripts/*.sh scripts/lib/*.sh | grep -v -- '--no-deps'; then
    echo 'ERROR: an application compose up is missing --no-deps' >&2
    exit 1
fi

MUNICIPIO_ENV_FILE="$ROOT_DIR/.env.example" bash -c \
    'source scripts/lib/common.sh; load_config; [[ "$DEPLOYMENT_MODE" == standalone ]]'

# Exercise every supported mode and node role through the same configuration loader
# used by the installer. Data nodes must also render a complete Compose project.
mode_env="$(mktemp)"
trap 'rm -f "$mode_env"' EXIT
for scenario in manual-primary manual-secondary arbitrator-primary arbitrator-secondary arbitrator-witness; do
    case "$scenario" in
        manual-*) mode=cluster-manual ;;
        arbitrator-*) mode=cluster-arbitrator ;;
    esac
    role=data name=municipio-01 address=10.20.0.11
    case "$scenario" in
        *-secondary) name=municipio-02 address=10.20.0.12 ;;
        *-witness) role=arbiter name=municipio-arbiter address=10.20.0.13 ;;
    esac
    sed -e "s/^DEPLOYMENT_MODE=.*/DEPLOYMENT_MODE=$mode/" \
        -e "s/^NODE_ROLE=.*/NODE_ROLE=$role/" \
        -e "s/^NODE_NAME=.*/NODE_NAME=$name/" \
        -e "s/^NODE_ADDRESS=.*/NODE_ADDRESS=$address/" \
        -e 's/^ARBITRATOR_NODE_ADDRESS=.*/ARBITRATOR_NODE_ADDRESS=10.20.0.13/' \
        .env.example > "$mode_env"
    MUNICIPIO_ENV_FILE="$mode_env" bash -c \
        'source scripts/lib/common.sh; load_config; [[ "$DEPLOYMENT_MODE" == "$1" && "$NODE_ROLE" == "$2" ]]' \
        _ "$mode" "$role"
    if [[ "$role" == data ]] && docker compose version >/dev/null 2>&1; then
        docker compose --env-file "$mode_env" -f compose.yaml config >/dev/null
    fi
done
rm -f "$mode_env"
trap - EXIT

grep -Fq 'packages+=(idn2 psl openssl)' scripts/install/host.sh || {
    echo 'ERROR: host installer must install hostname and certificate check tools on data VMs' >&2
    exit 1
}

if command -v psl >/dev/null 2>&1; then
    if ! command -v idn2 >/dev/null 2>&1 || ! idn2 --version >/dev/null 2>&1; then
        # This macOS test host has an incompatible idn2 binary; Linux uses the real command.
        idn2() {
            local value="${*: -1}"
            case "$value" in
                bücher.se) printf 'xn--bcher-kva.se\n' ;;
                *) printf '%s\n' "$value" ;;
            esac
        }
        export -f idn2
    fi
    site_list="$(printf 'example.co.uk\nblog.example.co.uk\nbücher.se\n' | \
        bash scripts/lib/build-caddy-sites.sh --http-only)"
    [[ "$site_list" == *'http://www.example.co.uk {'* ]]
    [[ "$site_list" == *'http://www.xn--bcher-kva.se {'* ]]
    [[ "$site_list" != *'www.blog.example.co.uk'* ]]
    # A site list retained while WordPress is down is regenerated from its own hostnames,
    # so a changed ACME_DNS_PROVIDER still adds or removes the per-site TLS import.
    retained_hosts="$(printf '%s\n' "$site_list" | \
        awk '/^[^[:space:]#].* [{]$/ { sub(/^http:\/\//, "", $1); print $1 }')"
    [[ "$(printf '%s\n' "$retained_hosts" | bash scripts/lib/build-caddy-sites.sh --http-only)" == "$site_list" ]]
    dns_list="$(printf '%s\n' "$retained_hosts" | bash scripts/lib/build-caddy-sites.sh --dns-challenge)"
    [[ "$dns_list" == *$'example.co.uk {\n    import municipio_tls\n'* ]]
    grep -Fq "awk '/^[^[:space:]#].* [{]\$/ { sub(/^http:\\/\\//, \"\", \$1); print \$1 }'" \
        scripts/refresh-sites.municipio.sh
    # The installer hostname must appear in WordPress's own list. An alias generated
    # for an apex domain does not count as a registered WordPress site.
    printf 'example.co.uk\nblog.example.co.uk\n' | \
        bash scripts/lib/build-caddy-sites.sh --require-host example.co.uk >/dev/null
    if printf 'example.co.uk\n' | \
        bash scripts/lib/build-caddy-sites.sh --require-host www.example.co.uk >/dev/null 2>&1; then
        echo 'ERROR: generated www alias satisfied the required WordPress hostname' >&2
        exit 1
    fi
    if printf 'other.example.co.uk\n' | \
        bash scripts/lib/build-caddy-sites.sh --require-host example.co.uk >/dev/null 2>&1; then
        echo 'ERROR: missing setup hostname passed WordPress discovery' >&2
        exit 1
    fi
    [[ "$(psl --print-reg-domain example.co.uk)" == 'example.co.uk: example.co.uk' ]]
    [[ "$(psl --print-reg-domain blog.example.co.uk)" == 'blog.example.co.uk: example.co.uk' ]]
    for invalid in 'https://example.com:444' 'foo.com {' '127.0.0.1' 'foo.com/bar'; do
        if printf '%s\n' "$invalid" | bash scripts/lib/build-caddy-sites.sh >/dev/null 2>&1; then
            echo "ERROR: accepted invalid hostname: $invalid" >&2
            exit 1
        fi
    done
    if declare -F idn2 >/dev/null; then unset -f idn2; fi
else
    echo 'SKIP: psl is not installed; Caddy host generation tests need psl'
fi

source scripts/lib/platform.sh
for release in 'ubuntu 22.04 jammy' 'ubuntu 24.04 noble' 'ubuntu 26.04 resolute' \
    'debian 12 bookworm' 'debian 13 trixie'; do
    read -r distro version codename <<< "$release"
    platform_supported "$distro" "$version" "$codename" amd64
done
if platform_supported ubuntu 20.04 focal amd64 || \
    platform_supported ubuntu 24.04 noble arm64 || \
    platform_supported debian 13 bookworm amd64; then
    echo 'ERROR: unsupported platform passed validation' >&2
    exit 1
fi
(
    platform_fixture="$(mktemp)"
    trap 'rm -f "$platform_fixture"' EXIT
    printf 'ID=debian\nVERSION_ID=13\nVERSION_CODENAME=trixie\n' > "$platform_fixture"
    detect_platform "$platform_fixture" amd64
    [[ "$PLATFORM_ID" == debian && "$PLATFORM_CODENAME" == trixie && "$PLATFORM_ARCH" == amd64 ]]
)

bad_env="$(mktemp)"
trap 'rm -f "$bad_env"' EXIT

reject_config() {
    local description="$1"
    shift
    "$@" .env.example > "$bad_env"
    if MUNICIPIO_ENV_FILE="$bad_env" bash -c 'source scripts/lib/common.sh; load_config' >/dev/null 2>&1; then
        echo "ERROR: $description passed validation" >&2
        exit 1
    fi
}

reject_config 'a mutable application image tag' \
    sed 's|^MUNICIPIO_IMAGE=.*$|MUNICIPIO_IMAGE=ghcr.io/municipio-se/municipio-deployment-docker:latest|'
reject_config 'a mutable MariaDB image tag' sed 's|^MARIADB_IMAGE=.*$|MARIADB_IMAGE=mariadb:11.4|'
reject_config 'a mutable Caddy image tag' sed 's|^CADDY_IMAGE=.*$|CADDY_IMAGE=caddy:2|'
reject_config 'an unsupported ACME DNS provider' \
    sed 's|^ACME_DNS_PROVIDER=.*$|ACME_DNS_PROVIDER=unsupported|'
reject_config 'a Loopia DNS configuration without API credentials' \
    sed 's|^ACME_DNS_PROVIDER=.*$|ACME_DNS_PROVIDER=loopia|'
reject_config 'a Loopia password that would break the generated Caddyfile' sed \
    -e 's|^ACME_DNS_PROVIDER=.*$|ACME_DNS_PROVIDER=loopia|' \
    -e 's|^ACME_DNS_LOOPIA_USERNAME=.*$|ACME_DNS_LOOPIA_USERNAME=api@loopiaapi|' \
    -e 's|^ACME_DNS_LOOPIA_PASSWORD=.*$|ACME_DNS_LOOPIA_PASSWORD='"'"'ab}cd'"'"'|'
reject_config 'a name.com token containing a double quote' sed \
    -e 's|^ACME_DNS_PROVIDER=.*$|ACME_DNS_PROVIDER=namedotcom|' \
    -e 's|^ACME_DNS_NAMEDOTCOM_USER=.*$|ACME_DNS_NAMEDOTCOM_USER=user|' \
    -e 's|^ACME_DNS_NAMEDOTCOM_TOKEN=.*$|ACME_DNS_NAMEDOTCOM_TOKEN='"'"'ab"cd'"'"'|'
# Credentials are quoted in the generated Caddyfile, so spaces remain valid.
sed -e 's|^ACME_DNS_PROVIDER=.*$|ACME_DNS_PROVIDER=loopia|' \
    -e 's|^ACME_DNS_LOOPIA_USERNAME=.*$|ACME_DNS_LOOPIA_USERNAME=api@loopiaapi|' \
    -e "s|^ACME_DNS_LOOPIA_PASSWORD=.*\$|ACME_DNS_LOOPIA_PASSWORD='ab cd'|" .env.example > "$bad_env"
MUNICIPIO_ENV_FILE="$bad_env" bash -c 'source scripts/lib/common.sh; load_config' >/dev/null
reject_config 'a malformed delegated ACME DNS record name' \
    sed 's|^ACME_DNS_CHALLENGE_DOMAIN=.*$|ACME_DNS_CHALLENGE_DOMAIN=wrong.example.test|'
# The MariaDB data directory on replicated storage corrupts silently, so refuse it early.
reject_config 'a database directory inside DATA_ROOT' \
    sed 's|^DB_DATA_ROOT=.*$|DB_DATA_ROOT=/srv/municipio/data/mysql|'
reject_config 'a database directory inside GLUSTER_BRICK' \
    sed 's|^DB_DATA_ROOT=.*$|DB_DATA_ROOT=/srv/municipio/gluster-brick/mysql|'
reject_config 'a missing database root password' sed 's|^DB_ROOT_PASSWORD=.*$||'
reject_config 'an arbitrator in standalone mode' sed 's|^NODE_ROLE=.*$|NODE_ROLE=arbiter|'
reject_config 'a publicly bound application port' sed 's|^APP_BIND_ADDRESS=.*$|APP_BIND_ADDRESS=0.0.0.0|'
reject_config 'a cluster data node with mismatched identity' sed \
    -e 's|^DEPLOYMENT_MODE=.*$|DEPLOYMENT_MODE=cluster-manual|' \
    -e 's|^NODE_ADDRESS=.*$|NODE_ADDRESS=10.20.0.99|'

# The status board must render every layout without touching the system. The demo
# cluster contains a failure, so exit status 2 is the expected result.
for layout in standalone cluster arbiter; do
    monitor_status=0
    bash scripts/monitor.municipio.sh --demo "$layout" --no-color > /dev/null || monitor_status=$?
    [[ "$monitor_status" -ge 1 ]] || { echo "ERROR: monitor demo $layout did not report its sample problems" >&2; exit 1; }
done
# Captured first: the demo exits non-zero, which pipefail would turn into a pass.
# Fix hints ("->") are commands to paste and are exempt from the width limit.
monitor_screen="$(bash scripts/monitor.municipio.sh --demo cluster --no-color || true)"
if grep -v '^ *-> ' <<< "$monitor_screen" | awk 'length > 80 {found = 1} END {exit !found}'; then
    echo 'ERROR: the monitor screen is wider than 80 columns' >&2
    exit 1
fi

echo 'Static checks passed'
