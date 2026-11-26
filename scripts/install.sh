#!/bin/sh
# Installs or updates OpenSimulator from the latest release:
#   curl -fsSL https://ndworks.dev/opensimulator/install.sh | sh
#
# Everything runs inside main, so a download cut short executes nothing.

set -eu

RELEASE_URL="${OPENSIMULATOR_RELEASE_URL:-https://github.com/ndworks-dev/OpenSimulator/releases/latest/download}"
REQUIREMENT='anchor apple generic and identifier "com.nickolasdeluca.OpenSimulator" and certificate leaf[subject.OU] = "3BRKN94K4H"'

say() { printf '%s\n' "$*"; }
fail() { printf 'OpenSimulator: %s\n' "$*" >&2; exit 1; }

fetch() {
    /usr/bin/curl --proto "${OPENSIMULATOR_CURL_PROTO:-=https}" --fail --silent --show-error --location \
        --connect-timeout 15 --max-time 300 --output "$2" "$1"
}

install_dir() {
    if [ -n "${OPENSIMULATOR_INSTALL_DIR:-}" ]; then
        mkdir -p "$OPENSIMULATOR_INSTALL_DIR"
        printf '%s\n' "$OPENSIMULATOR_INSTALL_DIR"
    elif [ -w /Applications ]; then
        printf '%s\n' /Applications
    else
        mkdir -p "$HOME/Applications"
        printf '%s\n' "$HOME/Applications"
    fi
}

main() {
    [ "$(uname -s)" = "Darwin" ] || fail "this app runs only on macOS."
    major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "$major" -ge 14 ] || fail "macOS 14 or later is required."

    dir="$(install_dir)"
    work="$dir/.opensimulator-install.$$"
    trap 'rm -rf "$work"' EXIT INT TERM
    mkdir "$work" || fail "cannot write to $dir."

    say "Downloading OpenSimulator..."
    fetch "$RELEASE_URL/latest.json" "$work/latest.json"
    fetch "$RELEASE_URL/OpenSimulator.zip" "$work/OpenSimulator.zip"

    expected="$(sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]\{64\}\)".*/\1/p' "$work/latest.json")"
    version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' "$work/latest.json")"
    [ -n "$expected" ] || fail "the release has no checksum."
    actual="$(/usr/bin/shasum -a 256 "$work/OpenSimulator.zip" | cut -d' ' -f1)"
    [ "$actual" = "$expected" ] || fail "the download does not match the published checksum."

    /usr/bin/ditto -x -k "$work/OpenSimulator.zip" "$work/unpacked"
    /usr/bin/codesign --verify --deep --strict "-R=$REQUIREMENT" "$work/unpacked/OpenSimulator.app" 2>/dev/null \
        || fail "the app's signature was refused."

    # Quitting this way leaves running simulators up; the new app reopens their windows.
    if [ -z "${OPENSIMULATOR_NO_LAUNCH:-}" ]; then
        /usr/bin/pkill -x OpenSimulator 2>/dev/null || true
    fi
    if [ -e "$dir/OpenSimulator.app" ]; then
        mv "$dir/OpenSimulator.app" "$work/previous.app"
    fi
    if ! mv "$work/unpacked/OpenSimulator.app" "$dir/OpenSimulator.app"; then
        [ ! -e "$work/previous.app" ] || mv "$work/previous.app" "$dir/OpenSimulator.app"
        fail "could not place the app in $dir."
    fi

    say "OpenSimulator $version installed in $dir."
    if ! /usr/bin/xcode-select -p >/dev/null 2>&1 || [ ! -d "$(/usr/bin/xcode-select -p)/Platforms/iPhoneSimulator.platform" ]; then
        say "It needs Xcode 26 or 27 with an iOS simulator runtime, from the App Store or developer.apple.com."
    fi
    if [ -z "${OPENSIMULATOR_NO_LAUNCH:-}" ]; then
        /usr/bin/open "$dir/OpenSimulator.app"
    fi
}

main "$@"
