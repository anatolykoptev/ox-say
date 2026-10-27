#!/usr/bin/env bash
# Renders the main window to PNGs: Shots/render.sh [output dir]   (default ~/tmp/ox-say-main-window-shots)
# SHOTS_ONLY=settings,voices limits the scenes. A window flashes on screen for about a second per shot.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pkg=$(cd "$here/.." && pwd)
out=${1:-$HOME/tmp/ox-say-main-window-shots}
cd "$here"
nice -n 15 timeout 900 swift build -c release --package-path "$here"
nice -n 15 timeout 300 "$(swift build -c release --package-path "$here" --show-bin-path)/OxSayShots" "$pkg" "$out"
