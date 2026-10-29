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
# --notes-only and --diar-only each replace the model list; an option for another model would be dropped without a word.
if [ "$notes_only" = 1 ] && [ "$diar_only" = 1 ]; then
    echo "--notes-only and --diar-only select different model sets; give one" >&2
    exit 2
fi
if [ "$notes_only" = 1 ] || [ "$diar_only" = 1 ]; then
    if [ "$with_whisper" = 1 ] || [ "$with_voxcpm2" = 1 ]; then
        echo "--with-whisper and --with-voxcpm2 do not combine with --notes-only or --diar-only: those fetch one set and nothing else" >&2
        exit 2
    fi
fi
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
# the revision means new hashes and a new modelsRevision in engine/diar's Pins.swift (a unit test compares it with the
# library's own pin, and engine/diar/build.sh compares it with diar_rev). Task 20b.2 adds the Go side
# (internal/config DiarModelsRevision) and TestDiarPinsAgreeAcrossLanguages, which compares the three.
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

# Seconds a download may stay under 1 KB/s before it is given up on; OX_SAY_STALL_SECS shortens it for tests.
stall_secs=${OX_SAY_STALL_SECS:-30}

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

diar_marker="$dest/diar/speaker-diarization/.fluidaudio-revision"

# Seconds per retry pass to wait before the next one (pass * unit); OX_SAY_RETRY_SLEEP_UNIT=0 turns it off for tests.
retry_unit=${OX_SAY_RETRY_SLEEP_UNIT:-2}

# fetch_part <url> <part> <resume 0|1>: one download into <part>. Transient failures are tried again here in the
# shell, up to 3 more passes with a growing pause, and each pass resumes (-C -) from the bytes <part> holds now:
#   - a stall (28) or a dropped or refused line (6, 7, 18, 35, 52, 56)
#   - an HTTP 408, 429 or 5xx (curl -f turns every HTTP error into exit 22; the status comes from -w)
# curl's own --retry would not do: with -C - it re-reads the offset it started the run with, so a 3 GB model that
# stalls near the end would be fetched again from where that run began.
# Returns curl's last exit status; fetch_code holds the last HTTP status (empty when curl got none).
# progress_tick <part> <parent>: print "progress <name> <bytes>" every $progress_secs s, until killed, or until the
# parent (the script's pid, captured by the caller before backgrounding) is gone: a Ctrl-C of a terminal install
# kills the script, and the ticker, running on its own, must not outlive it and keep printing (#299).
progress_secs=${OX_SAY_PROGRESS_SECS:-30}
progress_tick() {
    local part=$1 parent=$2 n=0
    # TERM from fetch_part ends it at once; the 1 s sleep runs on its own and cannot hold a pipe open
    trap 'exit 0' TERM
    while :; do
        sleep 1 >/dev/null 2>&1 &
        wait $!
        kill -0 "$parent" 2>/dev/null || exit 0
        n=$((n + 1))
        if [ "$n" -ge "$progress_secs" ]; then
            n=0
            echo "progress ${part##*/} $(wc -c < "$part" 2>/dev/null | tr -d ' ') bytes"
        fi
    done
}

fetch_code=
fetch_part() {
    local url=$1 part=$2 resume=$3 pass=0 rc
    local opts=(-fsSL --connect-timeout 15 --speed-limit 1024 --speed-time "$stall_secs" -w '%{http_code}')
    if [ "$resume" = 1 ]; then opts+=(-C -); else rm -f "$part"; fi
    while :; do
        rc=0
        # The download is silent (-sS), and an installer that makes no output looks wedged to the app's watchdog
        # (#356): while curl runs, one line every $progress_secs says how many bytes <part> holds. The line is the
        # app's progress signal; it needs no knowledge of where OX_SAY_HOME points.
        progress_tick "$part" "$$" &
        ticker=$!
        fetch_code=$(curl "${opts[@]}" -o "$part" "$url") || rc=$?
        kill "$ticker" 2>/dev/null || true
        wait "$ticker" 2>/dev/null || true
        [ "$rc" -eq 0 ] && return 0
        case $rc in
            6 | 7 | 18 | 28 | 35 | 52 | 56) ;;
            22)
                case $fetch_code in
                    408 | 429 | 5??) ;;
                    *) return "$rc" ;;
                esac
                ;;
            *) return "$rc" ;;
        esac
        pass=$((pass + 1))
        [ "$pass" -le 3 ] || return "$rc"
        # A fresh download (resume 0) that is retried has bytes by now: the next pass continues them, it does not
        # truncate the file and start again from byte 0.
        [ "$resume" = 1 ] || { resume=1; opts+=(-C -); }
        sleep $((pass * retry_unit))
    done
}

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
    # The marker says "every diarization file passed its checksum". This one did not, so it is about to be replaced (or
    # is missing): the marker goes now, and is written again at the end. Dropped here and not before the loop, a
    # failure on an unrelated model earlier in the list would take the marker of intact diarization files with it.
    case $name in diar/*) rm -f "$diar_marker" ;; esac
    if [ -n "${OX_SAY_MODELS_FROM:-}" ] && [ -f "$OX_SAY_MODELS_FROM/$name" ]; then
        echo "copy    $name"
        cp "$OX_SAY_MODELS_FROM/$name" "$part"
    else
        echo "fetch   $name"
        # -sS: no progress meter (it would flood the daemon's stderr tail), errors kept
        # A dead line must end, not hang (an install waits on this): connect in 15 s, and give up on a
        # transfer that stays under 1 KB/s for $stall_secs s (an average over that window; a slow but alive
        # line is never cut). A stall is curl exit 28; fetch_part resumes it from the .part (-C -). Not a total
        # bound: a 3 GB model on a slow line takes as long as it needs.
        # A .part the server will not resume (curl exit 33, or HTTP 412 / 416 on the Range request: the object changed
        # or the offset no longer fits it) would fail every later run the same way, so it is dropped and the file is
        # fetched once from the start. Nothing else drops it: a stall, a dropped line, a 5xx, a 404 or a 403 leave the
        # .part (a fresh request would meet the same error, and the bytes are what the next run resumes from).
        # Which of the two signals arrives depends on curl: 8.7.1 (macOS) exits 0 on a 416 under -C - (it takes the
        # file for complete) and the checksum check below drops a .part that is wrong; a curl that fails with 22 on
        # the 416 lands in the arm here. Both ends in a clean fetch, so the arm stays for the curls that need it.
        rc=0
        resumed=0
        [ -s "$part" ] && resumed=1
        fetch_part "$base/$remote" "$part" 1 || rc=$?
        if [ "$resumed" = 1 ] && { [ "$rc" -eq 33 ] || { [ "$rc" -eq 22 ] && { [ "$fetch_code" = 412 ] || [ "$fetch_code" = 416 ]; }; }; }; then
            echo "resuming $name failed (curl exit $rc${fetch_code:+, HTTP $fetch_code}); fetching it again from the start" >&2
            rc=0
            fetch_part "$base/$remote" "$part" 0 || rc=$?
        fi
        if [ "$rc" -ne 0 ]; then
            if [ "$rc" -eq 28 ]; then
                echo "download of $name stalled (under 1 KB/s for $stall_secs s); check the network and run it again" >&2
            else
                echo "download of $name failed (curl exit $rc)${fetch_code:+; HTTP $fetch_code}" >&2
            fi
            exit 1
        fi
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
# interrupted fetch has no marker: ox-diar cannot load it, and the daemon will not call the models ready either
# (Task 20b.2: Config.DiarModelsReady). An old marker is removed before the first diarization file is fetched, for the
# same reason.
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
