#!/usr/bin/env bash
# Download the pinned model weights into the models dir, SHA-256 verified:
#   Qwen3-TTS talker + tokenizer (Apache-2.0)     text-to-speech
#   Parakeet TDT 0.6B v3 q8_0 (CC-BY-4.0)        speech-to-text, 25 European languages
#   Silero VAD v5.1.2 (MIT)                      ox-stt --serve --vad streaming sessions
#   Whisper large-v3-turbo (MIT), --with-whisper  speech-to-text, 99 languages (1.6 GB)
#   VoxCPM2 Q8_0 (Apache-2.0), --with-voxcpm2    quality text-to-speech, Apple Silicon only (3.0 GB)
#   Qwen3.5-4B Q4_K_M (Apache-2.0), --notes-only  meeting notes (2.7 GB); fetches this one model and nothing else.
#                                                 The daemon runs it from $OX_SAY_HOME/fetch-models.sh on the user's first use of notes.
#   Core ML community-1 diarization models (CC-BY-4.0), 24 files and 4 documents, 22 MB, in <dest>/diar/speaker-diarization/: who
#                                                 spoke on a group call (ox-diar). In the default set; --diar-only fetches
#                                                 just these.
#
# Usage: scripts/fetch-models.sh [--with-whisper] [--with-voxcpm2] [--notes-only] [--diar-only] [dest]   (any order)
#   dest defaults to "$OX_SAY_HOME/models" (OX_SAY_HOME defaults to
#   ~/Library/Application Support/ox-say).
#   OX_SAY_MODELS_FROM=<dir> copies matching files from a local dir instead of
#   downloading them (the checksum is verified either way).
set -euo pipefail

with_whisper=0
with_voxcpm2=0
notes_only=0
diar_only=0
dest=
for arg in "$@"; do
    case "$arg" in
        --with-whisper) with_whisper=1 ;;
        --with-voxcpm2) with_voxcpm2=1 ;;
        --notes-only) notes_only=1 ;;
        --diar-only) diar_only=1 ;;
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
whisper_vad=https://huggingface.co/ggml-org/whisper-vad/resolve/main

# name sha256 base-url [name-at-the-url]
models=(
    "qwen-talker-0.6b-base-Q8_0.gguf d54dbaf10591421fa764ed630d764efa717ae40cd959bd48c66d4eb1af226426 $qwen"
    "qwen-tokenizer-12hz-F32.gguf b16b95557c7c7340a121757bd6855b9609e1cf4ad3fad0778b89393293ae5f3d $qwen"
    "ggml-parakeet-tdt-0.6b-v3-q8_0.bin 4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e $parakeet"
    "ggml-silero-v5.1.2.bin 29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf $whisper_vad"
)
if [ "$with_whisper" = 1 ]; then
    models+=("ggml-large-v3-turbo.bin 1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69 $whisper")
fi
# VoxCPM2 Q8_0 (Apache-2.0 weights, GGUF by audio.cpp), --with-voxcpm2, 2.96 GB, Apple Silicon only.
voxcpm2=https://huggingface.co/audio-cpp/audio.cpp-gguf/resolve/f861648c0c1f4da9f18e9a0ce5e217b0679bb2f5/VoxCPM2-GGUF
if [ "$with_voxcpm2" = 1 ]; then
    models+=("voxcpm2-q8_0.gguf c8e01ab4416011e12a28f24ede298a1aa5ce64b43f8e8aaad53b1e2fe7c96432 $voxcpm2")
fi

# Speaker diarization (ox-diar): FluidInference/speaker-diarization-coreml, the Core ML conversion of pyannote's
# community-1 pipeline, at the revision FluidAudio 0.17.7 itself asks for (the spike measured the files at the repo's
# later head; all 24 are byte-identical at both, checked against Hugging Face's own listing of each: LFS files by
# SHA-256, the rest by git blob id). Stored as <dest>/diar/speaker-diarization/<path>, the layout FluidAudio's offline
# loader expects under `ox-diar --models <dest>/diar`. CC-BY-4.0 (attribution in NOTICE). The three documents the
# licence asks us to keep (LICENSE, NOTICE.md, README.md with the citations) and PROVENANCE.md come with them. Bumping
# the revision means new hashes, a new modelsRevision in engine/diar's Pins.swift (a unit test compares it with the
# library's own pin) and a new DiarModelsRevision in internal/config; tests compare the three.
diar_rev=df2625ac79a7ac6b65ad868fee6d80f320da4232
diar_url=https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/$diar_rev
diar_files=(
    "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682  Embedding.mlmodelc/analytics/coremldata.bin"
    "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004  Embedding.mlmodelc/coremldata.bin"
    "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5  Embedding.mlmodelc/metadata.json"
    "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3  Embedding.mlmodelc/model.mil"
    "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b  Embedding.mlmodelc/weights/weight.bin"
    "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a  FBank.mlmodelc/analytics/coremldata.bin"
    "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759  FBank.mlmodelc/coremldata.bin"
    "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a  FBank.mlmodelc/metadata.json"
    "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed  FBank.mlmodelc/model.mil"
    "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36  FBank.mlmodelc/weights/weight.bin"
    "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7  PldaRho.mlmodelc/analytics/coremldata.bin"
    "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418  PldaRho.mlmodelc/coremldata.bin"
    "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945  PldaRho.mlmodelc/metadata.json"
    "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041  PldaRho.mlmodelc/model.mil"
    "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36  PldaRho.mlmodelc/weights/weight.bin"
    "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb  Segmentation.mlmodelc/analytics/coremldata.bin"
    "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc  Segmentation.mlmodelc/coremldata.bin"
    "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124  Segmentation.mlmodelc/metadata.json"
    "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f  Segmentation.mlmodelc/model.mil"
    "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2  Segmentation.mlmodelc/weights/weight.bin"
    "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a  config.json"
    "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f  plda-parameters.json"
    "0353430db062715c411ba32e66cb435b9caee2662bccdb298f9e5d1bae760872  provenance.json"
    "f7cd5cc16e63e2d89db052a23018ecfc47a311998ed1e9e39838fbac65048688  xvector-transform.json"
)
diar_docs=(
    "736763bf08829e36266b8a3bebcc041ac68575424e976490671a7e6b43a525cf  LICENSE"
    "0964a66893fa5c3a574758257d30d2944669f44eeed5784b30ec3bab902012b3  NOTICE.md"
    "d0488f898df6da6e9d36f28b0704a65a13578d598c8685a9c5af0f5f8af13978  README.md"
    "0032bc1b7d01b6af2bb6eb8548a39c9a28fe5c1909f74166bc2ea2eb1cc27df6  PROVENANCE.md"
)
diar_models=()
for entry in "${diar_files[@]}" "${diar_docs[@]}"; do
    read -r sum rel <<< "$entry"
    diar_models+=("diar/speaker-diarization/$rel $sum $diar_url $rel")
done
models+=("${diar_models[@]}")

# Meeting notes (--notes-only): Qwen3.5-4B Q4_K_M, 2740937888 bytes, pinned to the repo commit
# the notes spike measured. The daemon reports download progress from the size of the .part
# file against config.NotesModelBytes, which must match this size.
qwen35=https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523
if [ "$notes_only" = 1 ]; then
    models=("Qwen3.5-4B-Q4_K_M.gguf 00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4 $qwen35")
fi
if [ "$diar_only" = 1 ]; then
    models=("${diar_models[@]}")
fi

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

mkdir -p "$dest"
for entry in "${models[@]}"; do
    read -r name want base remote <<< "$entry"
    remote=${remote:-$name}
    target="$dest/$name"
    mkdir -p "$(dirname "$target")"
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
        # -sS: no progress meter (it would flood the daemon's stderr tail), errors kept
        curl -fsSL --retry 3 -C - -o "$part" "$base/$remote"
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

# FluidAudio's loader reads <dir>/.fluidaudio-revision and refuses the models when it is not the revision it was told
# to expect (ox-diar sets it to diar_rev). It is written last, after every file above passed its checksum, so an
# interrupted fetch has no marker: ox-diar cannot load it and the daemon (config.DiarBlock) does not call it ready.
if [ "$notes_only" != 1 ]; then
    printf '%s\n' "$diar_rev" > "$dest/diar/speaker-diarization/.fluidaudio-revision.part"
    mv "$dest/diar/speaker-diarization/.fluidaudio-revision.part" "$dest/diar/speaker-diarization/.fluidaudio-revision"
fi

if [ "$notes_only" = 1 ] || [ "$diar_only" = 1 ]; then exit 0; fi
# The f16 Parakeet weights were the default until q8_0 replaced them (the same
# FLEURS ru/en WER, half the RAM). Name a leftover copy; never delete it here: the
# LaunchAgent's OX_SAY_STT_MODEL may name it, and a standalone run cannot see that.
# -ef compares the files themselves, so a trailing slash or a symlink does not matter.
old="$dest/ggml-parakeet-tdt-0.6b-v3-f16.bin"
if [ -f "$old" ] && ! [ "${OX_SAY_STT_MODEL:-}" -ef "$old" ]; then
    echo "note    $old (1.3 GB) is no longer the default; unless OX_SAY_STT_MODEL in your LaunchAgent names it, delete it to free the space"
fi
