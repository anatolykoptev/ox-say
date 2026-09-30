#!/bin/sh
# ox-say installer for Intel Macs:
#   curl -fsSL https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh | sh -s -- --version v0.2.0
#
# It downloads a prebuilt release from GitHub, checks its SHA-256, and runs the
# release's own scripts/install-release.sh: engines and models into
# ~/Library/Application Support/ox-say, the ox-say command into ~/.local/bin, a
# LaunchAgent for the daemon, the MCP server registered with Claude Code when
# it is installed, and a speak-and-transcribe self-test. It never uses sudo.
# Settings are OX_SAY_* environment variables; see scripts/lib-install.sh.
set -eu

repo=anatolykoptev/ox-say
asset=ox-say-macos-x86_64.tar.gz
version=latest

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            [ $# -ge 2 ] || { echo "ox-say: --version needs a tag, e.g. v0.2.0" >&2; exit 2; }
            version=$2
            shift 2
            ;;
        *) echo "ox-say: unknown option $1" >&2; exit 2 ;;
    esac
done

if [ "$(uname -s)" != Darwin ]; then
    echo "ox-say runs on macOS only." >&2
    exit 1
fi
# Under Rosetta, uname -m says x86_64 on an Apple Silicon Mac.
if [ "$(uname -m)" != x86_64 ] || [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
    echo "ox-say is built for Intel Macs (x86_64). On Apple Silicon, MLX-based speech tools run natively." >&2
    exit 1
fi
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
trap cleanup EXIT INT TERM

echo "downloading ox-say ($version)"
curl -fL --retry 3 --progress-bar -o "$tmp/$asset" "$url/$asset"
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
