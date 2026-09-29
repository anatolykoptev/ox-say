#!/usr/bin/env bash
# Stop and remove the LaunchAgent and the binary. Models, voices and the engine
# stay in ~/Library/Application Support/ox-say unless --purge is given.
set -euo pipefail

label=io.github.anatolykoptev.ox-say
bindir=${OX_SAY_BINDIR:-"$HOME/.local/bin"}
home=${OX_SAY_HOME:-"$HOME/Library/Application Support/ox-say"}

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$bindir/ox-say"
if [ "${1:-}" = "--purge" ]; then
    rm -rf "$home" "$HOME/Library/Logs/ox-say" "$HOME/Library/Caches/ox-say"
fi
echo "ox-say uninstalled"
