#!/bin/sh
# ox-say installer for Macs (Apple Silicon and Intel):
#   curl -fsSL https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh | sh -s -- --version v0.2.0
#
# It downloads a prebuilt release from GitHub, checks its SHA-256, and runs the
# release's own scripts/install-release.sh: engines and models into
# ~/Library/Application Support/ox-say, the ox-say command into ~/.local/bin, a
# LaunchAgent for the daemon, the MCP server registered with Claude Code when
# it is installed, and a speak-and-transcribe self-test. It never uses sudo.
# Settings are OX_SAY_* environment variables; see scripts/lib-install.sh.
#
# The whole body lives in main() so a truncated `curl | sh` download defines a
# function and never runs a half-received script.
set -eu

main() {
    repo=anatolykoptev/ox-say
    version=latest

    while [ $# -gt 0 ]; do
        case "$1" in
            --version)
                [ $# -ge 2 ] || { echo "ox-say: --version needs a tag, e.g. v0.2.0" >&2; exit 2; }
                version=$2
                shift 2
                ;;
            --version=*)
                version=${1#--version=}
                [ -n "$version" ] || { echo "ox-say: --version needs a tag, e.g. v0.2.0" >&2; exit 2; }
                shift
                ;;
            *) echo "ox-say: unknown option $1" >&2; exit 2 ;;
        esac
    done
    case $version in
        latest | v*) : ;;
        *) version="v$version" ;;   # --version 0.2.0 means tag v0.2.0
    esac

    if [ "$(uname -s)" != Darwin ]; then
        echo "ox-say runs on macOS only." >&2
        exit 1
    fi
    # The hardware decides, not the shell: hw.optional.arm64 is 1 on Apple
    # Silicon even in a Rosetta shell, where uname -m says x86_64, and the
    # native arm64 build is the one to install there.
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
        arch=arm64
    else
        arch=x86_64
    fi
    asset=ox-say-macos-$arch.tar.gz
    # Refuse before downloading ~3 GB into a machine that cannot run it.
    macos=$(sw_vers -productVersion)
    case ${macos%%.*} in
        '' | *[!0-9]*) echo "ox-say: could not determine the macOS version" >&2; exit 1 ;;
    esac
    if [ "${macos%%.*}" -lt 13 ]; then
        echo "ox-say needs macOS 13 or later; this is $macos." >&2
        exit 1
    fi
    if [ "$arch" = x86_64 ]; then
        case $(sysctl -n machdep.cpu.leaf7_features 2>/dev/null) in
            *AVX2*) : ;;
            *) echo "ox-say's engines need a CPU with AVX2; this one does not have it." >&2; exit 1 ;;
        esac
    fi
    # The dictation app's updater runs this script under launchd's default
    # PATH (/usr/bin:/bin:/usr/sbin:/sbin), which hides a Homebrew ffmpeg. Put
    # the two standard prefixes back, when they exist, for the tool checks and
    # for install-release.sh, which inherits this PATH.
    for prefix in /opt/homebrew/bin /usr/local/bin; do
        if [ -d "$prefix" ]; then
            PATH="$prefix:$PATH"
        fi
    done
    export PATH

    for tool in curl shasum tar; do
        command -v "$tool" >/dev/null || { echo "ox-say: $tool not found" >&2; exit 1; }
    done
    if ! command -v ffmpeg >/dev/null; then
        echo "ox-say needs ffmpeg. Install it with Homebrew (https://brew.sh), then run this again:" >&2
        echo "  brew install ffmpeg" >&2
        exit 1
    fi

    if [ -n "${OX_SAY_GET_URL:-}" ]; then
        # a mirror, or file:///path/to/dist for testing a locally built package
        url=$OX_SAY_GET_URL
    elif [ "$version" = latest ]; then
        url="https://github.com/$repo/releases/latest/download"
    else
        url="https://github.com/$repo/releases/download/$version"
    fi

    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-get.XXXXXX")
    cleanup() { case "$tmp" in */ox-say-get.*) rm -rf "$tmp" ;; esac; }
    trap cleanup EXIT
    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM

    echo "downloading ox-say ($version)"
    if ! curl -fL --retry 3 --progress-bar -o "$tmp/$asset" "$url/$asset"; then
        echo "ox-say: could not download $asset for $version." >&2
        if [ "$arch" = arm64 ]; then
            echo "This release may have no Apple Silicon package: pick a newer version, or build from source with scripts/install.sh." >&2
        fi
        exit 1
    fi
    curl -fsSL --retry 3 -o "$tmp/SHA256SUMS" "$url/SHA256SUMS"
    want=$(awk -v a="$asset" '$2 == a || $2 == "*" a { print $1 }' "$tmp/SHA256SUMS")
    got=$(shasum -a 256 "$tmp/$asset" | awk '{ print $1 }')
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
        echo "ox-say: checksum mismatch for $asset (want ${want:-none}, got $got); nothing was installed" >&2
        exit 1
    fi
    echo "checksum ok"

    mkdir "$tmp/release"
    tar -xzf "$tmp/$asset" -C "$tmp/release"
    bash "$tmp/release/ox-say/scripts/install-release.sh"
}

main "$@"
