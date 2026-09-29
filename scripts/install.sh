#!/usr/bin/env bash
# Build and install ox-say for the current user: engines, models, daemon binary
# and a LaunchAgent that keeps `ox-say serve` running.
# OX_SAY_WITH_WHISPER=1 also downloads Whisper large-v3-turbo (1.6 GB).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
label=io.github.anatolykoptev.ox-say
bindir=${OX_SAY_BINDIR:-"$HOME/.local/bin"}
logdir="$HOME/Library/Logs/ox-say"
plist="$HOME/Library/LaunchAgents/$label.plist"
addr=${OX_SAY_ADDR:-127.0.0.1:8094}

"$root/engine/build.sh"
"$root/scripts/install-engine.sh"
if [ "${OX_SAY_WITH_WHISPER:-0}" = 1 ]; then
    "$root/scripts/fetch-models.sh" --with-whisper
else
    "$root/scripts/fetch-models.sh"
fi

version=$(git -C "$root" describe --tags --always --dirty 2>/dev/null || echo dev)
mkdir -p "$root/build" "$bindir" "$logdir" "$(dirname "$plist")"
(cd "$root" && go build -trimpath -ldflags "-s -w -X main.version=$version" -o build/ox-say ./cmd/ox-say)
# Copy then rename, so the running daemon keeps its old inode until restart.
cp "$root/build/ox-say" "$bindir/ox-say.new"
mv "$bindir/ox-say.new" "$bindir/ox-say"

sed -e "s|@BIN@|$bindir/ox-say|" -e "s|@LOGDIR@|$logdir|" \
    "$root/launchd/$label.plist.in" > "$plist"
plutil -lint "$plist" >/dev/null

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
# bootout returns before the old job is gone; bootstrap fails with EIO until then
for i in 1 2 3 4 5 6 7 8 9 10; do
    if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null; then
        break
    fi
    if [ "$i" = 10 ]; then
        launchctl bootstrap "gui/$(id -u)" "$plist"  # let the error show
    fi
    sleep 0.5
done

for _ in $(seq 1 20); do
    if curl -sf -o /dev/null "http://$addr/health"; then
        echo "ox-say is running on http://$addr"
        echo "MCP: claude mcp add --transport http --scope user ox-say http://$addr/mcp"
        exit 0
    fi
    sleep 0.5
done
echo "ox-say did not answer on http://$addr/health; see $logdir/ox-say.log" >&2
exit 1
