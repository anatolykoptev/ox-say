#!/usr/bin/env bash
# Build ox-say from source and install it for the current user: engines, models,
# the ox-say binary and a LaunchAgent that keeps `ox-say serve` running.
# To install a prebuilt release instead, run get.sh (see README).
# Settings (OX_SAY_* variables): see scripts/lib-install.sh.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=scripts/lib-install.sh source-path=SCRIPTDIR
. "$root/scripts/lib-install.sh"

# meson and ninja: ox-aec (the meeting echo canceller, on for every install since it ships in every
# package) is built with them, the only engine that is not cmake.
oxs_require "brew install cmake go ffmpeg meson ninja" go cmake ffmpeg meson ninja plutil launchctl curl

version=dev
if command -v git >/dev/null && [ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" = "$root" ]; then
    version=$(git -C "$root" describe --tags --always --dirty)
fi

# 1. Build the binary first: `ox-say env-keys` names the variables the daemon
#    reads, which decides what oxs_settings carries over (fetch-models then
#    sees a carried-over OX_SAY_HOME) and what the render writes.
mkdir -p "$root/build"
(cd "$root" && go build -trimpath -ldflags "-s -w -X main.version=$version" -o build/ox-say ./cmd/ox-say)
oxs_env_keys_from "$root/build/ox-say"
oxs_settings

# 2. Build and fetch the rest. Nothing the running daemon uses changes until
#    step 3, so a failure here leaves the installed version intact.
#    OX_SAY_WITH_AEC: the source install gets the same ox-aec the release package ships —
#    without it the daemon's default-on echo cancellation would warn aec_missing on every meeting.
OX_SAY_WITH_AEC=1 "$root/engine/build.sh"
oxs_fetch_models "$root/scripts/fetch-models.sh"
# Caller-owned temp dir + plain-statement render: inside `tmp=$(oxs_render_agent)`
# command substitution bash 3.2 clears `set -e`, so a failing plutil would not
# stop the install.
tmpdir=$(mktemp -d)
tmp="$tmpdir/agent.plist"
# A kill mid-staging (TERM from the app's install timeout, Ctrl-C) must not strand .new copies beside the
# engines: the abort drops them, and is a no-op once oxs_stage_commit has emptied the queue (#508).
trap 'oxs_stage_abort_quiet; rm -f "$tmp"; rmdir "$tmpdir" 2>/dev/null || true' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
oxs_render_agent "$root/launchd/$label.plist.in" "$tmp"

# 3. Swap in the new engines and binary, then reload the agent.
oxs_install_engines "$root/build/engine/out"
oxs_install_binary "$root/build/ox-say"
oxs_load_agent "$tmp"

# 4. Wait for this build to answer.
oxs_wait_version "$version"
echo "MCP: claude mcp add --transport http --scope user ox-say http://$addr/mcp"
