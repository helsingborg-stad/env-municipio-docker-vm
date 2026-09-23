#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 0 || ( $# -eq 1 && "$1" == --http-only ) ]] || {
    echo 'Usage: build-caddy-sites.sh [--http-only]' >&2
    exit 2
}
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

hosts_file="$(mktemp)"
trap 'rm -f -- "$hosts_file"' EXIT
count=0
while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ -n "$raw" ]] || continue
    host="$(normalize_host "$raw")"
    printf '%s\n' "$host" >> "$hosts_file"
    count=$((count + 1))
    registered="$(psl --print-reg-domain -- "$host")" || die "public suffix lookup failed: $host"
    if [[ "$registered" == "$host: $host" ]]; then
        normalize_host "www.$host" >> "$hosts_file"
    fi
done
((count > 0)) || die 'WordPress returned no site hostnames'

while IFS= read -r host; do
    [[ "${1:-}" == --http-only ]] && host="http://$host"
    printf '%s {\n    import municipio_proxy\n}\n\n' "$host"
done < <(LC_ALL=C sort -u "$hosts_file")
