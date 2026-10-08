#!/usr/bin/env bash
set -euo pipefail

http_only=false
dns_challenge=false
required_host=
while (($#)); do
    case "$1" in
        --http-only) http_only=true; shift ;;
        --dns-challenge) dns_challenge=true; shift ;;
        --require-host)
            [[ $# -ge 2 && -n "$2" ]] || {
                echo 'Usage: build-caddy-sites.sh [--http-only] [--dns-challenge] [--require-host HOST]' >&2
                exit 2
            }
            required_host="$2"
            shift 2
            ;;
        *)
            echo 'Usage: build-caddy-sites.sh [--http-only] [--dns-challenge] [--require-host HOST]' >&2
            exit 2
            ;;
    esac
done
command -v idn2 >/dev/null || { echo 'idn2 is required' >&2; exit 1; }
command -v psl >/dev/null || { echo 'psl is required' >&2; exit 1; }

die() { printf 'Caddy site generation failed: %s\n' "$*" >&2; exit 1; }

normalize_host() {
    local raw="$1" host label rest
    case "$raw" in
        http://*|https://*)
            raw="${raw#*://}"
            raw="${raw%%/*}"
            ;;
    esac
    raw="${raw%.}"
    [[ -n "$raw" && "$raw" != *[[:space:]]* && "$raw" != *[/:@#?{},\;\\]* ]] || \
        die "invalid hostname: $1"
    host="$(LC_ALL=C.UTF-8 idn2 --quiet --usestd3asciirules -- "$raw")" || \
        die "invalid IDN hostname: $1"
    host="$(printf '%s' "$host" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    [[ ${#host} -le 253 && "$host" == *.* && "$host" =~ ^[a-z0-9.-]+$ ]] || \
        die "invalid DNS hostname: $1"
    rest="$host"
    while [[ "$rest" == *.* ]]; do
        label="${rest%%.*}"
        [[ -n "$label" && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || \
            die "invalid DNS label in: $1"
        rest="${rest#*.}"
    done
    [[ -n "$rest" && ${#rest} -le 63 && "$rest" != -* && "$rest" != *- ]] || \
        die "invalid DNS label in: $1"
    [[ ! "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "IP address is not a site hostname: $1"
    printf '%s\n' "$host"
}

[[ -z "$required_host" ]] || required_host="$(normalize_host "$required_host")"

hosts_file="$(mktemp)"
trap 'rm -f -- "$hosts_file"' EXIT
count=0
required_found=false
while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ -n "$raw" ]] || continue
    host="$(normalize_host "$raw")"
    [[ -z "$required_host" || "$host" != "$required_host" ]] || required_found=true
    printf '%s\n' "$host" >> "$hosts_file"
    count=$((count + 1))
    registered="$(psl --print-reg-domain -- "$host")" || die "public suffix lookup failed: $host"
    if [[ "$registered" == "$host: $host" ]]; then
        normalize_host "www.$host" >> "$hosts_file"
    fi
done
((count > 0)) || die 'WordPress returned no site hostnames'
[[ -z "$required_host" || "$required_found" == true ]] || \
    die "setup hostname $required_host is missing from WordPress; existing Caddy routes were retained"

while IFS= read -r host; do
    [[ "$http_only" == true ]] && host="http://$host"
    if [[ "$dns_challenge" == true ]]; then
        printf '%s {\n    import municipio_tls\n    import municipio_proxy\n}\n\n' "$host"
    else
        printf '%s {\n    import municipio_proxy\n}\n\n' "$host"
    fi
done < <(LC_ALL=C sort -u "$hosts_file")
