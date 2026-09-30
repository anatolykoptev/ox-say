#!/usr/bin/env bash
# Build ox-say from source and install it for the current user: engines, models,
# the ox-say binary and a LaunchAgent that keeps `ox-say serve` running.
# To install a prebuilt release instead, run get.sh (see README).
# Settings (OX_SAY_* variables): see scripts/lib-install.sh.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=scripts/lib-install.sh source-path=SCRIPTDIR
. "$root/scripts/lib-install.sh"

oxs_require "brew install cmake go ffmpeg" go cmake ffmpeg plutil launchctl curl
oxs_settings

version=dev
if command -v git >/dev/null && [ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" = "$root" ]; then
    version=$(git -C "$root" describe --tags --always --dirty)
fi

# 1. Build and fetch everything first. Nothing the running daemon uses changes
#    until step 2, so a failure here leaves the installed version intact.
"$root/engine/build.sh"
oxs_fetch_models "$root/scripts/fetch-models.sh"
mkdir -p "$root/build"
(cd "$root" && go build -trimpath -ldflags "-s -w -X main.version=$version" -o build/ox-say ./cmd/ox-say)
tmp=$(oxs_render_agent "$root/launchd/$label.plist.in")
trap 'rm -f "$tmp"; rmdir "$(dirname "$tmp")" 2>/dev/null || true' EXIT

# 2. Swap in the new engines and binary, then reload the agent.
oxs_install_engines "$root/build/engine/out"
oxs_install_binary "$root/build/ox-say"
oxs_load_agent "$tmp"

# 3. Wait for this build to answer.
oxs_wait_version "$version"
echo "MCP: claude mcp add --transport http --scope user ox-say http://$addr/mcp"
