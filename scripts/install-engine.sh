#!/usr/bin/env bash
# Install the built engine (engine/build.sh output) into "$OX_SAY_HOME/engine".
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
home=${OX_SAY_HOME:-"$HOME/Library/Application Support/ox-say"}
out="$root/build/engine/out"

if [ ! -x "$out/tts-server" ]; then
    echo "no engine build at $out; run engine/build.sh first" >&2
    exit 1
fi
mkdir -p "$home/engine/licenses"
# Copy then rename, so a running tts-server keeps its old inode.
cp "$out/tts-server" "$home/engine/tts-server.new"
mv "$home/engine/tts-server.new" "$home/engine/tts-server"
cp "$out"/licenses/* "$home/engine/licenses/"
echo "installed $home/engine/tts-server"
