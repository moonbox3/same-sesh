#!/bin/sh
# Optional macOS bootstrap. Native setup also works directly: ./same-sesh setup
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo 'This installer supports macOS terminals. Use same-sesh.cmd on Windows.' >&2
    exit 1
fi
if [ "${1:-}" = '--release' ]; then
    if [ "$#" -lt 3 ]; then
        echo 'Usage: ./install.sh --release VERSION SHA256 [setup options]' >&2
        exit 1
    fi
    release_version=$2
    expected_hash=$3
    shift 3
    if ! printf '%s\n' "$release_version" | /usr/bin/grep -Ex 'v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?' >/dev/null ||
       [ "${#expected_hash}" -ne 64 ] || ! printf '%s\n' "$expected_hash" | /usr/bin/grep -Ex '[a-fA-F0-9]{64}' >/dev/null; then
        echo 'Provide a release version (for example v0.1.0-preview.1) and its SHA-256.' >&2
        exit 1
    fi
    # Also reject newline-separated values even when one line matches.
    case "$release_version" in *[!A-Za-z0-9.-]*) exit 1 ;; esac
    setup_temp=$(/usr/bin/mktemp -d)
    trap 'rm -rf "$setup_temp"' EXIT HUP INT TERM
    setup_source="$setup_temp/same-sesh"
    /usr/bin/curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        "https://github.com/moonbox3/same-sesh/releases/download/$release_version/same-sesh" -o "$setup_source"
    expected_hash=$(printf '%s' "$expected_hash" | /usr/bin/tr 'A-F' 'a-f')
    if ! (cd "$setup_temp" && printf '%s  same-sesh\n' "$expected_hash" | /usr/bin/shasum -a 256 -c - >/dev/null); then
        echo 'Release checksum did not match. Setup was not run.' >&2
        exit 1
    fi
else
    installer_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || installer_dir=''
    if [ ! -f "$0" ] || [ -z "$installer_dir" ] || [ ! -f "$installer_dir/same-sesh" ]; then
        echo 'Use install.sh from a local checkout, or specify --release VERSION SHA256.' >&2
        exit 1
    fi
    setup_source="$installer_dir/same-sesh"
fi
# A piped installer must leave the wizard connected to the terminal.
if [ -t 0 ]; then
    /usr/bin/osascript -l JavaScript "$setup_source" setup "$@"
elif [ "${1:-}" = '--yes' ] || [ "${1:-}" = '-y' ]; then
    /usr/bin/osascript -l JavaScript "$setup_source" setup "$@"
else
    /usr/bin/osascript -l JavaScript "$setup_source" setup "$@" </dev/tty
fi
