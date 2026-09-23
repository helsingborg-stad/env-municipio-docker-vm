#!/usr/bin/env bash

# Keep this list explicit: repository selection is defined for these releases,
# while other versions and derivatives are not assumed compatible.
platform_supported() {
    case "$1:$2:$3:$4" in
        ubuntu:22.04:jammy:amd64|ubuntu:24.04:noble:amd64|ubuntu:26.04:resolute:amd64|\
        debian:12:bookworm:amd64|debian:13:trixie:amd64) return 0 ;;
        *) return 1 ;;
    esac
}

detect_platform() {
    local release_file="${1:-/etc/os-release}"
    local architecture="${2:-$(dpkg --print-architecture)}"
    local ID= VERSION_ID= VERSION_CODENAME= UBUNTU_CODENAME=
    [[ -r "$release_file" ]] || { printf 'Cannot read %s\n' "$release_file" >&2; return 1; }
    # shellcheck disable=SC1090
    source "$release_file"
    local codename="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
    if ! platform_supported "$ID" "$VERSION_ID" "$codename" "$architecture"; then
        printf 'Unsupported host: %s %s (%s), %s. Use Ubuntu 22.04/24.04/26.04 LTS or Debian 12/13 on amd64.\n' \
            "$ID" "$VERSION_ID" "$codename" "$architecture" >&2
        return 1
    fi
    PLATFORM_ID="$ID"
    PLATFORM_VERSION="$VERSION_ID"
    PLATFORM_CODENAME="$codename"
    PLATFORM_ARCH="$architecture"
}
