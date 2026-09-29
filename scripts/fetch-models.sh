#!/usr/bin/env bash
# Download the pinned Qwen3-TTS GGUF weights (Apache-2.0) into the models dir.
#
# Usage: scripts/fetch-models.sh [dest]
#   dest defaults to "$OX_SAY_HOME/models" (OX_SAY_HOME defaults to
#   ~/Library/Application Support/ox-say).
#   OX_SAY_MODELS_FROM=<dir> copies matching files from a local dir instead of
#   downloading them (the checksum is verified either way).
set -euo pipefail

home=${OX_SAY_HOME:-"$HOME/Library/Application Support/ox-say"}
dest=${1:-"$home/models"}
base=https://huggingface.co/Serveurperso/Qwen3-TTS-GGUF/resolve/main

# name sha256
models=(
    "qwen-talker-0.6b-base-Q8_0.gguf d54dbaf10591421fa764ed630d764efa717ae40cd959bd48c66d4eb1af226426"
    "qwen-tokenizer-12hz-F32.gguf b16b95557c7c7340a121757bd6855b9609e1cf4ad3fad0778b89393293ae5f3d"
)

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

mkdir -p "$dest"
for entry in "${models[@]}"; do
    name=${entry% *}
    want=${entry#* }
    target="$dest/$name"
    if [ -f "$target" ] && [ "$(sha "$target")" = "$want" ]; then
        echo "ok      $name"
        continue
    fi
    part="$target.part"
    if [ -n "${OX_SAY_MODELS_FROM:-}" ] && [ -f "$OX_SAY_MODELS_FROM/$name" ]; then
        echo "copy    $name"
        cp "$OX_SAY_MODELS_FROM/$name" "$part"
    else
        echo "fetch   $name"
        curl -fL --retry 3 -o "$part" "$base/$name"
    fi
    got=$(sha "$part")
    if [ "$got" != "$want" ]; then
        rm -f "$part"
        echo "checksum mismatch for $name: got $got, want $want" >&2
        exit 1
    fi
    mv "$part" "$target"
    echo "ok      $name"
done
