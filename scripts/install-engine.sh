#!/usr/bin/env bash
# Install the built engines (engine/build.sh output) into "$OX_SAY_HOME/engine".
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
home=${OX_SAY_HOME:-"$HOME/Library/Application Support/ox-say"}
out="$root/build/engine/out"

for bin in tts-server ox-stt ox-align; do
    if [ ! -x "$out/$bin" ]; then
        echo "no $bin in $out; run engine/build.sh first" >&2
        exit 1
    fi
done
mkdir -p "$home/engine/licenses"
for bin in tts-server ox-stt ox-align; do
    # Copy then rename, so a running process keeps its old inode.
    cp "$out/$bin" "$home/engine/$bin.new"
    mv "$home/engine/$bin.new" "$home/engine/$bin"
    echo "installed $home/engine/$bin"
done
cp "$out"/licenses/* "$home/engine/licenses/"
