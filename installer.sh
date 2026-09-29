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
mkdir "$work_dir/source"
tar -xzf "$work_dir/source.tar.gz" -C "$work_dir/source"
# GitHub names the archive's single top-level directory after the ref, such as
# env-municipio-docker-vm-main or env-municipio-docker-vm-feat-some-branch, so it is
# discovered rather than assumed. Any other MUNICIPIO_SOURCE_URL then works too.
set -- "$work_dir/source"/*
if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo 'Downloaded bundle must contain exactly one top-level directory' >&2
    exit 1
fi
source_dir="$1"
if [ ! -f "$source_dir/bin/interactive-install.sh" ] || [ ! -f "$source_dir/bin/install.sh" ]; then
    echo 'Downloaded bundle does not contain the expected installer' >&2
    exit 1
fi
bash "$source_dir/bin/interactive-install.sh"
