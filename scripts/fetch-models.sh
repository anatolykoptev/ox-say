#!/usr/bin/env bash
# Download the pinned model weights into the models dir, SHA-256 verified:
#   Qwen3-TTS talker + tokenizer (Apache-2.0)     text-to-speech
#   Parakeet TDT 0.6B v3 (CC-BY-4.0)             speech-to-text, 25 European languages
#   Whisper large-v3-turbo (MIT), --with-whisper  speech-to-text, 99 languages (1.6 GB)
#
# Usage: scripts/fetch-models.sh [--with-whisper] [dest]   (any order)
#   dest defaults to "$OX_SAY_HOME/models" (OX_SAY_HOME defaults to
#   ~/Library/Application Support/ox-say).
#   OX_SAY_MODELS_FROM=<dir> copies matching files from a local dir instead of
#   downloading them (the checksum is verified either way).
set -euo pipefail

with_whisper=0
dest=
for arg in "$@"; do
    case "$arg" in
        --with-whisper) with_whisper=1 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *)
            if [ -n "$dest" ]; then
                echo "more than one destination: $dest, $arg" >&2
                exit 2
            fi
            dest=$arg
            ;;
    esac
done
home=${OX_SAY_HOME:-"$HOME/Library/Application Support/ox-say"}
dest=${dest:-"$home/models"}

qwen=https://huggingface.co/Serveurperso/Qwen3-TTS-GGUF/resolve/main
parakeet=https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main
whisper=https://huggingface.co/ggerganov/whisper.cpp/resolve/main

# name sha256 base-url
models=(
    "qwen-talker-0.6b-base-Q8_0.gguf d54dbaf10591421fa764ed630d764efa717ae40cd959bd48c66d4eb1af226426 $qwen"
    "qwen-tokenizer-12hz-F32.gguf b16b95557c7c7340a121757bd6855b9609e1cf4ad3fad0778b89393293ae5f3d $qwen"
    "ggml-parakeet-tdt-0.6b-v3-f16.bin 833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f $parakeet"
)
if [ "$with_whisper" = 1 ]; then
    models+=("ggml-large-v3-turbo.bin 1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69 $whisper")
fi

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

mkdir -p "$dest"
for entry in "${models[@]}"; do
    read -r name want base <<< "$entry"
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
