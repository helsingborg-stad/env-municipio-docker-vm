#!/bin/sh
set -eu

# Publish this file at the chosen installer URL. It fetches the matching source
# bundle before running the interactive Bash installer on the VM.
if [ "$(id -u)" -ne 0 ]; then
    echo 'Run as root: sudo sh installer.sh' >&2
    exit 1
fi

if [ -z "${MUNICIPIO_SOURCE_URL:-}" ]; then
    MUNICIPIO_SOURCE_URL='https://github.com/helsingborg-stad/env-municipio-docker-vm/archive/refs/heads/main.tar.gz'
fi

command -v curl >/dev/null 2>&1 || { echo 'curl is required' >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo 'tar is required' >&2; exit 1; }
command -v bash >/dev/null 2>&1 || { echo 'bash is required' >&2; exit 1; }

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT HUP INT TERM
echo 'Downloading Municipio installer bundle...'
curl --fail --location --show-error --silent --retry 3 \
    "$MUNICIPIO_SOURCE_URL" -o "$work_dir/source.tar.gz"
tar -xzf "$work_dir/source.tar.gz" -C "$work_dir"
source_dir="$work_dir/env-municipio-docker-vm-main"
if [ ! -f "$source_dir/bin/interactive-install.sh" ] || [ ! -f "$source_dir/bin/install.sh" ]; then
    echo 'Downloaded bundle does not contain the expected installer' >&2
    exit 1
fi
bash "$source_dir/bin/interactive-install.sh"
