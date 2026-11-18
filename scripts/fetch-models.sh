#!/usr/bin/env bash
# Download the pinned model weights into the models dir, SHA-256 verified:
#   Qwen3-TTS talker + tokenizer (Apache-2.0)     text-to-speech
#   parakeet-ultra q8_0 (CC-BY-4.0)              speech-to-text, 25 European languages
#   parakeet-ultra f16 (CC-BY-4.0), --with-parakeet-f16
#                                                 the same model unquantised (1.26 GB): slightly lower WER on accented
#                                                 English, about twice as slow. Also fetched, with no flag, when
#                                                 OX_SAY_STT_MODEL names a file called ggml-parakeet-ultra-f16.bin, so an
#                                                 update keeps it. The q8_0 file above is always fetched too (default, fallback).
#   Silero VAD v5.1.2 (MIT)                      ox-stt --serve --vad streaming sessions
#   Whisper large-v3-turbo (MIT), --with-whisper  speech-to-text, 99 languages (1.6 GB)
#   VoxCPM2 Q8_0 (Apache-2.0), --with-voxcpm2    quality text-to-speech, Apple Silicon only (3.0 GB)
#   a notes model (one of the meeting-notes catalog), --notes <file> <sha256> <url>
#                                                 fetches this one model and nothing else; the daemon names the
#                                                 catalog file, its pinned SHA-256 and its pinned resolve URL, and
#                                                 runs it from $OX_SAY_HOME/fetch-models.sh.
#   Nemotron 3 Diarization fast128 (OpenMDW-1.1), 5 files and 2 documents, 199 MB, in <dest>/diar/nemotron-3-diarization/:
#                                                 who spoke on a group call (ox-diar). In the default set and in --diar-only
#                                                 on every Apple Silicon Mac, whatever its macOS; --nemotron-only fetches
#                                                 just it, on any Mac.
#   MossFormer2 SE 48K Core ML voice cleanup (Apache-2.0), 8 files and 4 documents, 131 MB, in
#                                                 <dest>/clean/mossformer2-se-48k/: ox-clean. In NO default set, on any Mac:
#                                                 the daemon runs --clean-only on the user's first use of cleanup. Apple Silicon
#                                                 and Intel alike (no hardware test here; the daemon decides what runs).
#
# Usage: scripts/fetch-models.sh [--with-whisper] [--with-voxcpm2] [--with-parakeet-f16] [--notes <file> <sha256> <url>] [--diar-only] [--nemotron-only] [--clean-only] [dest]   (any order)
#   dest defaults to "$OX_SAY_HOME/models" (OX_SAY_HOME defaults to
#   ~/Library/Application Support/ox-say).
#   OX_SAY_MODELS_FROM=<dir> copies matching files from a local dir instead of
#   downloading them (the checksum is verified either way).
set -euo pipefail

with_whisper=0
with_voxcpm2=0
with_parakeet_f16=0
notes_only=0
notes_file=
notes_sha=
notes_url=
diar_only=0
nemotron_only=0
clean_only=0
dest=
while [ $# -gt 0 ]; do
    case "$1" in
        --with-whisper) with_whisper=1 ;;
        --with-voxcpm2) with_voxcpm2=1 ;;
        --with-parakeet-f16) with_parakeet_f16=1 ;;
        --notes)
            if [ "$notes_only" = 1 ]; then
                echo "--notes may be given once" >&2
                exit 2
            fi
            if [ $# -lt 4 ]; then
                echo "--notes wants a file name, its sha256 and its Hugging Face URL" >&2
                exit 2
            fi
            notes_only=1
            notes_file=$2
            notes_sha=$3
            notes_url=$4
            shift 3
            ;;
        --diar-only) diar_only=1 ;;
        --nemotron-only) nemotron_only=1 ;;
        --clean-only) clean_only=1 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)
            if [ -n "$dest" ]; then
                echo "more than one destination: $dest, $1" >&2
                exit 2
            fi
            dest=$1
            ;;
    esac
    shift
done
# --notes, --diar-only, --nemotron-only and --clean-only each replace the model list; an option for another model would be dropped without a word.
if [ $((notes_only + diar_only + nemotron_only + clean_only)) -gt 1 ]; then
    echo "--notes, --diar-only, --nemotron-only and --clean-only select different model sets; give one" >&2
    exit 2
fi
if [ "$notes_only" = 1 ] || [ "$diar_only" = 1 ] || [ "$nemotron_only" = 1 ] || [ "$clean_only" = 1 ]; then
    if [ "$with_whisper" = 1 ] || [ "$with_voxcpm2" = 1 ] || [ "$with_parakeet_f16" = 1 ]; then
        echo "--with-whisper, --with-voxcpm2 and --with-parakeet-f16 do not combine with --notes, --diar-only, --nemotron-only or --clean-only: those fetch one set and nothing else" >&2
        exit 2
    fi
fi
# --notes is the daemon's download: its three arguments are checked here, before
# any file is copied or any URL is fetched, so a malformed call fails with a
# usage error and never touches the network. The sha256 itself is what verifies
# the downloaded file below.
if [ "$notes_only" = 1 ]; then
    case "$notes_file" in
        *.gguf) ;;
        *) echo "--notes: the file name must end in .gguf: $notes_file" >&2; exit 2 ;;
    esac
    case "$notes_file" in
        */* | *" "* | "") echo "--notes: the file name must be a plain name, not a path: $notes_file" >&2; exit 2 ;;
    esac
    case "$notes_sha" in
        *[!0-9a-f]* | "") echo "--notes: the sha256 must be 64 lowercase hex chars" >&2; exit 2 ;;
    esac
    if [ "${#notes_sha}" -ne 64 ]; then
        echo "--notes: the sha256 must be 64 hex chars, got ${#notes_sha}" >&2
        exit 2
    fi
    case "$notes_url" in
        https://huggingface.co/*/resolve/*) ;;
        *) echo "--notes: the URL must be a pinned https://huggingface.co/<repo>/resolve/<rev> URL" >&2; exit 2 ;;
    esac
    # A branch or tag name floats; the pin is a 40-hex commit, like every other URL here.
    notes_rev=${notes_url##*/resolve/}
    case "$notes_rev" in
        */* | *[!0-9a-f]* | "") echo "--notes: the URL must pin a commit, got $notes_url" >&2; exit 2 ;;
    esac
    if [ "${#notes_rev}" -ne 40 ]; then
        echo "--notes: the URL must pin a 40-hex commit, got $notes_url" >&2
        exit 2
    fi
fi
home=${OX_SAY_HOME:-"$HOME/Library/Application Support/ox-say"}
dest=${dest:-"$home/models"}

# Pinned to the commit each repo's main resolved to on 2026-11-05 (x-repo-commit of a HEAD on the file URL), so a user
# installs the bytes we tested even when upstream moves main. At each commit the LFS SHA-256 (x-linked-etag) of every file
# below equals the hash in the list, and so does x-linked-size at main. A bump means new hashes. A test fails if a
# floating-branch URL comes back. The parakeet-ultra pin (2026-11-18) is the revision the file was published at:
# x-repo-commit matched, x-linked-etag is the SHA-256 below and x-linked-size is 668757119.
qwen=https://huggingface.co/Serveurperso/Qwen3-TTS-GGUF/resolve/b7ee2e8c7459c3bea99da23e3d178125a7d1713c
parakeet=https://huggingface.co/Koptev/parakeet-ultra-ggml/resolve/376105ac643ed20ac1e6cb54c2c04c454294c5a9
# The f16 file was published later, at its own revision (x-repo-commit, x-linked-etag = the SHA-256 below and
# x-linked-size = 1255897319, checked 2026-11-18). The q8_0 bytes are unchanged at the revision above, so that pin stays.
parakeet_f16=https://huggingface.co/Koptev/parakeet-ultra-ggml/resolve/2d1259722b0a0ee0d525aaaadcd648de58641dc0
whisper=https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1
whisper_vad=https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b

# name sha256 base-url [name-at-the-url]
models=(
    "qwen-talker-0.6b-base-Q8_0.gguf d54dbaf10591421fa764ed630d764efa717ae40cd959bd48c66d4eb1af226426 $qwen"
    "qwen-tokenizer-12hz-F32.gguf b16b95557c7c7340a121757bd6855b9609e1cf4ad3fad0778b89393293ae5f3d $qwen"
    "ggml-parakeet-ultra-q8_0.bin fa28ec8c6afd9893da9829ec9f2fa908a60bc0fbebd37fd60bbd2f0953076fb2 $parakeet"
    "ggml-silero-v5.1.2.bin 29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf $whisper_vad"
)
# parakeet-ultra f16, 1.26 GB: --with-parakeet-f16, or OX_SAY_STT_MODEL naming it. The installer exports the agent's
# OX_SAY_STT_MODEL (oxs_settings) before it runs this script, so an update by get.sh keeps a verified f16 file in place
# for the agent that points at it, with no flag. The match is the file name, not the directory.
case ${OX_SAY_STT_MODEL:-} in
    ggml-parakeet-ultra-f16.bin | */ggml-parakeet-ultra-f16.bin) with_parakeet_f16=1 ;;
esac
if [ "$with_parakeet_f16" = 1 ]; then
    models+=("ggml-parakeet-ultra-f16.bin ee42f83ae751d7b3f9c435543df92ea6926f2d73df3129186a1ab58a8c7b6150 $parakeet_f16")
fi
if [ "$with_whisper" = 1 ]; then
    models+=("ggml-large-v3-turbo.bin 1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69 $whisper")
fi
# VoxCPM2 Q8_0 (Apache-2.0 weights, GGUF by audio.cpp), --with-voxcpm2, 2.96 GB, Apple Silicon only.
voxcpm2=https://huggingface.co/audio-cpp/audio.cpp-gguf/resolve/f861648c0c1f4da9f18e9a0ce5e217b0679bb2f5/VoxCPM2-GGUF
if [ "$with_voxcpm2" = 1 ]; then
    models+=("voxcpm2-q8_0.gguf c8e01ab4416011e12a28f24ede298a1aa5ce64b43f8e8aaad53b1e2fe7c96432 $voxcpm2")
fi

# Nemotron 3 Diarization (ox-diar): FluidInference/nemotron-3-diarization-coreml, the Core ML conversion of
# nvidia/Nemotron-3-Diarization (OpenMDW-1.1), fast128 preset (monolithic/v2), at the revision the spike measured. Stored as
# <dest>/diar/nemotron-3-diarization/, the flat layout Nemotron3Models.load(config:directory:) reads. Never `main`: the
# library's own default revision is a moving branch. Bumping means new hashes here and nem_rev in
# config.NemotronModelsRevision and engine/diar's Pins.swift (TestDiarPinsAgreeAcrossLanguages compares the three).
nem_rev=25a90f97f254428d4b30374b76af9c74fdee8327
nem_url=https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/resolve/$nem_rev
nem_bundle=Nemotron3Diarizer_fast128.mlmodelc
nem_files=(
    "e7c029a46d9f327bec4c47fc34e5d32ee2cec9ce596950af0c403d05146b4ead  $nem_bundle/model.mil"
    "ebcca7245d8d774305752b9f2b79433ad1858f8a06df3b326e0ae6305d981d25  $nem_bundle/coremldata.bin"
    "e8c90d2d0e16787a420de6805fd5b7a95c116fac0163208b5bc4d8a9ae459ca4  $nem_bundle/weights/weight.bin"
    "a71e06616a3ae7bddef06ce5dfc7fe523a286e489f63a8da2fc4f1e940d560a4  $nem_bundle/analytics/coremldata.bin"
    "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7  learnable_sil_emb.bin"
)
nem_docs=(
    "a091d8d252882018a82593cafdd8020b924102b2d9b8d38a0db0c57413e84115  README.md"
    "6af4f721e1fc33b9a701f041d04addc120af7a3867596833f79e71337c35296a  config.json"
)
nem_models=()
for entry in "${nem_files[@]}" "${nem_docs[@]}"; do
    read -r sum rel <<< "$entry"
    case $rel in
        $nem_bundle/*) remote=monolithic/v2/$rel ;;   # the bundle sits under monolithic/v2/ at the source
        *) remote=$rel ;;
    esac
    nem_models+=("diar/nemotron-3-diarization/$rel $sum $nem_url $remote")
done

# A Mac that cannot run ox-diar gets no 199 MB it cannot use: the engine refuses Intel (internal/daemon/diarize.go
# diarReady), so the set joins the default list and --diar-only on Apple Silicon only. The macOS version is NOT
# tested: a Mac installed on macOS 14 that later upgrades to 15 gets no new fetch (nothing re-runs this script
# without a release), and the daemon reads only the Nemotron marker, so a version test here would leave it at
# models_missing for good. The set waits on disk (199 MB) while diarReady answers os_too_old.
# OX_SAY_NEMOTRON=1 forces the set on (a seeded test dir, a CI cache); =0 forces it off.
nemotron_ok() {
    case ${OX_SAY_NEMOTRON:-} in
        1) return 0 ;;
        0) return 1 ;;
    esac
    # arm64 hardware, not just an arm64 shell: a Rosetta shell says x86_64 while the Mac is Apple Silicon —
    # hw.optional.arm64 reads the hardware, the same test get.sh makes for its own arch.
    [ "$(uname -m)" = arm64 ] || [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]
}

nem_in_set=0
if nemotron_ok; then
    models+=("${nem_models[@]}")   # Nemotron last
    nem_in_set=1
fi

# MossFormer2 SE 48K voice cleanup (ox-clean): Koptev/mossformer2-se-48k-coreml, our Core ML conversion of
# alibabasglab/MossFormer2_SE_48K (Apache-2.0; NOTICE credits Alibaba SLAB), at the commit published and verified on
# 2026-11-04 (the resolve URL at this commit answers with x-repo-commit: clean_rev). Never `main`. Stored as
# <dest>/clean/mossformer2-se-48k/<rel>. The app loads the compiled .mlmodelc, so the .mlpackage (the source of
# truth in the repo) is NOT fetched. reference_window.bin is the known-answer window the engine checks the model
# with on every load. The four documents (LICENSE, NOTICE.md, PROVENANCE.md, README.md) keep the Apache-2.0 terms
# next to the weights. The set is lazy: NO default list includes it, on any architecture, and only --clean-only
# fetches it (the daemon calls that on the user's first use, as it does for the notes model). Bumping means new
# hashes here and clean_rev in config.CleanModelsRevision (TestCleanPinsAgreeAcrossLanguages compares the two; Task 3
# adds engine/clean's Pins.swift as the third) and config.CleanModelsBytes.
clean_rev=da0d6b45be2fe7f2ec495ee76280132848a789c0
clean_url=https://huggingface.co/Koptev/mossformer2-se-48k-coreml/resolve/$clean_rev
clean_files=(
    "019a117d1b12476d342ce787954cd065e97d7977c8575b0b4a64ba1cd6f6a919  MossFormer2_SE_48K.mlmodelc/analytics/coremldata.bin"
    "45f9c86c73f7e4fcb9eb552789bbdeb11274c9de235dd637bc018b1f8a6aa2a5  MossFormer2_SE_48K.mlmodelc/coremldata.bin"
    "795e65fd7adda75bfe4e62912c899592a0ece1c45b19beb4a39468a622c34b9b  MossFormer2_SE_48K.mlmodelc/metadata.json"
    "6db168e889ed29a8c36c4fd9429872cf1a01b241368af0f5e33baa853c8141f5  MossFormer2_SE_48K.mlmodelc/model.mil"
    "a240669911aade7aa87991de27e09d0c3d56d7d9fa491a7df180725fe3250446  MossFormer2_SE_48K.mlmodelc/weights/weight.bin"
    "49e9ae2faabea3259737ea6b315d4558c27ff83af2580329c1ec855cd15a12bd  manifest.json"
    "639b015f07dda17e176b0c0473241bf507f8688127d52e681d6af0f44b373f0c  config.json"
    "29fcb372069103a8337c0e19e32f2e983bc709ea45185a662213a26ee7435beb  reference_window.bin"
)
clean_docs=(
    "c95bae1d1ce0235ecccd3560b772ec1efb97f348a79f0fbe0a634f0c2ccefe2c  LICENSE"
    "8dbf05185f2faa1e46abc7a628acc943825e5916ad50a05e9425767a4d7e6b96  NOTICE.md"
    "5feecdab893ba16536ae78e01f85a0c8a4f46bbbebb1e018f6b0431743107504  PROVENANCE.md"
    "cf4c35fc0e07825124e6e1196431f5fb37cd43f3db6d93218c4df2aed20e60ff  README.md"
)
clean_models=()
for entry in "${clean_files[@]}" "${clean_docs[@]}"; do
    read -r sum rel <<< "$entry"
    clean_models+=("clean/mossformer2-se-48k/$rel $sum $clean_url $rel")
done

# Meeting notes (--notes): the daemon names the catalog model — its file name,
# pinned SHA-256 and pinned resolve URL come from internal/config/notesmodels.go.
# The daemon reports download progress from the size of the .part file against
# the catalog entry's bytes.
if [ "$notes_only" = 1 ]; then
    models=("$notes_file $notes_sha $notes_url")
fi
if [ "$diar_only" = 1 ]; then
    if [ "$nem_in_set" != 1 ]; then
        echo "nothing to fetch: ox-diar does not run on this Mac"   # an empty list would trip `set -u` on bash 3.2
        exit 0
    fi
    models=("${nem_models[@]}")
fi
if [ "$nemotron_only" = 1 ]; then
    models=("${nem_models[@]}")
    nem_in_set=1
fi
if [ "$clean_only" = 1 ]; then
    models=("${clean_models[@]}")
fi

# Seconds a download may stay under 1 KB/s before it is given up on; OX_SAY_STALL_SECS shortens it for tests.
stall_secs=${OX_SAY_STALL_SECS:-30}

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# human_size <bytes>: "3 MB" from one MiB up, "12 KB" from one KiB up, else "512 bytes" ("1 byte") (a small .part is never "0 MB").
human_size() {
    if [ "$1" -ge 1048576 ]; then echo "$(( $1 / 1048576 )) MB"
    elif [ "$1" -ge 1024 ]; then echo "$(( $1 / 1024 )) KB"
    elif [ "$1" -eq 1 ]; then echo "1 byte"
    else echo "$1 bytes"
    fi
}

nem_marker="$dest/diar/nemotron-3-diarization/.ox-say-revision"
clean_marker="$dest/clean/mossformer2-se-48k/.ox-say-revision"

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
    # The marker of a set says "every file of the set passed its checksum". This one did not, so it is about to be
    # replaced (or is missing): the marker of its set goes now, and is written again at the end. Dropped here and not
    # before the loop, a failure on an unrelated model earlier in the list would take the marker of intact files with
    # it.
    case $name in
        diar/nemotron-3-diarization/*) rm -f "$nem_marker" ;;
        clean/mossformer2-se-48k/*) rm -f "$clean_marker" ;;
    esac
    if [ -n "${OX_SAY_MODELS_FROM:-}" ] && [ -f "$OX_SAY_MODELS_FROM/$name" ]; then
        echo "copy    $name"
        cp "$OX_SAY_MODELS_FROM/$name" "$part"
    else
        # A rerun over a .part says so (and how much it holds): the log of a continuation and of a restart must differ.
        # Whether the server accepts the Range request is known only when it answers, so the line claims no more than
        # it knows ("trying to continue"); a .part that is then dropped says so below, after this line.
        if [ -s "$part" ]; then
            echo "fetch   $name (found a partial download, $(human_size "$(wc -c < "$part" | tr -d ' ')"); trying to continue it)"
        else
            echo "fetch   $name"
        fi
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
            echo "the partial download of $name cannot be continued (curl exit $rc${fetch_code:+, HTTP $fetch_code}); fetching it again from the start" >&2
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

# .ox-say-revision is the marker of the nemotron set, ours because no loader outside this repo reads it. A marker is
# written last, after every file of its set passed its checksum, so an interrupted fetch has no marker: ox-diar cannot load it, and the daemon will not call the models ready either
# (Task 20b.2: Config.DiarModelsReady). An old marker is removed before the first file of its set is fetched, for the
# same reason. The clean set's marker is the same contract, read by the daemon alone (Config.CleanModelsReady).
if [ "$notes_only" != 1 ] && [ "$clean_only" != 1 ]; then
    if [ "$nem_in_set" = 1 ]; then
        printf '%s\n' "$nem_rev" > "$dest/diar/nemotron-3-diarization/.ox-say-revision.part"
        mv "$dest/diar/nemotron-3-diarization/.ox-say-revision.part" "$dest/diar/nemotron-3-diarization/.ox-say-revision"
    fi
fi

if [ "$clean_only" = 1 ]; then
    printf '%s\n' "$clean_rev" > "$dest/clean/mossformer2-se-48k/.ox-say-revision.part"
    mv "$dest/clean/mossformer2-se-48k/.ox-say-revision.part" "$dest/clean/mossformer2-se-48k/.ox-say-revision"
    exit 0
fi

if [ "$notes_only" = 1 ] || [ "$diar_only" = 1 ] || [ "$nemotron_only" = 1 ]; then exit 0; fi
# The f16 Parakeet weights were the default until q8_0 replaced them (the same
# FLEURS ru/en WER, half the RAM). Name a leftover copy; never delete it here: the
# LaunchAgent's OX_SAY_STT_MODEL may name it, and a standalone run cannot see that.
# -ef compares the files themselves, so a trailing slash or a symlink does not matter.
old="$dest/ggml-parakeet-tdt-0.6b-v3-f16.bin"
if [ -f "$old" ] && ! [ "${OX_SAY_STT_MODEL:-}" -ef "$old" ]; then
    echo "note    $old (1.3 GB) is no longer the default; unless OX_SAY_STT_MODEL in your LaunchAgent names it, delete it to free the space"
fi
# The v3 q8_0 weights were the default until parakeet-ultra replaced them (lower
# WER on the same architecture and tokenizer). Same leftover rules as the f16
# note above: name it, never delete it, -ef stays silent while OX_SAY_STT_MODEL names it.
old="$dest/ggml-parakeet-tdt-0.6b-v3-q8_0.bin"
if [ -f "$old" ] && ! [ "${OX_SAY_STT_MODEL:-}" -ef "$old" ]; then
    echo "note    $old (669 MB) is no longer the default; unless OX_SAY_STT_MODEL in your LaunchAgent names it, delete it to free the space"
fi
# The community-1 speaker models (pyannote, 22 MB) belonged to the speaker engine that Nemotron replaced and nothing reads
# them now. Name a leftover folder, never delete it here: it is the user's disk, and the marker inside is not ours to judge.
old="$dest/diar/speaker-diarization"
if [ -d "$old" ]; then
    echo "note    $old (22 MB) is no longer used; delete it to free the space"
fi
