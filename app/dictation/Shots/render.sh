#!/usr/bin/env bash
# Renders the main window to PNGs: Shots/render.sh [output dir]   (default ~/tmp/ox-say-main-window-shots)
# SHOTS_ONLY=settings,voices limits the scenes. A window flashes on screen for about a second per shot.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pkg=$(cd "$here/.." && pwd)
out=${1:-$HOME/tmp/ox-say-main-window-shots}
cd "$here"

# macOS ships no `timeout`; use GNU timeout/gtimeout (coreutils) when present, else run unbounded.
limit() {
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}

nice -n 15 bash -c "$(declare -f limit)"'; limit 900 swift build -c release --package-path "$0"' "$here"
bin=$(swift build -c release --package-path "$here" --show-bin-path)
nice -n 15 bash -c "$(declare -f limit)"'; limit 300 "$@"' _ "$bin/OxSayShots" "$pkg" "$out"
