#!/usr/bin/env bash
# Synthetic eval of Parakeet decoder term boosting (engine/stt/boost.h + the token-bias patch).
#
#   engine/stt/eval/boost_eval.sh corpus|synth|decode|score|all
#
#   corpus  vocab dump + manifest.tsv (boost_corpus.py)
#   synth   one clip per manifest line with the installed `ox-say say` (read-only use of the daemon),
#           resampled to 16 kHz mono; sequential, skips clips that exist
#   decode  every clip through ox-stt in arms base (no flags), a0 (--terms-stdin --boost-alpha 0),
#           a1 a2 a3, interleaved per clip so drift hits every arm alike; plus tiny (alpha 1e-6, token
#           reference) and huge (alpha 30) on every 4th clip and on the silence clips, for the
#           patch-level self-checks
#   score   boost_score.py: recall RU/EN, false insertions per 100 sentences, decode ms, the
#           acoustic-veto arms and the self-checks
#
# Env: WORK (default ~/tmp/ox-say-boost-spike; all audio and outputs live there, never in the repo),
#      OXSTT (ox-stt binary built with engine/patches/whisper), MODEL (ggml-parakeet-tdt-0.6b-v3-q8_0.bin),
#      STOP_AT (epoch seconds; synth/decode stop cleanly after it).
# Mac safety: one heavy job at a time. Before every 25th file the script checks `pmset -g therm` and waits
# while another Swift build/test runs; a thermal or performance warning stops it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
WORK=${WORK:-$HOME/tmp/ox-say-boost-spike}
OXSTT=${OXSTT:-$WORK/build/out/ox-stt}
MODEL=${MODEL:-$WORK/models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin}
STOP_AT=${STOP_AT:-0}
SEED=20261114
TERMS="OxSay Hormozi Devin GitHub vaelor Dropbox Sonnet Haiku Fable Codex krolik pillow kisol dozor Glossa Claude Parakeet Brave Opus Hugging_Face"

mkdir -p "$WORK/raw" "$WORK/audio" "$WORK/out"

die() { echo "boost_eval: $*" >&2; exit 1; }

# guard: thermal state and other agents' Swift jobs, before a heavy phase and every ~25 files
guard() {
    local t
    t=$(pmset -g therm 2>&1 || true)
    if printf '%s\n' "$t" | grep -Eq 'CPU_Speed_Limit *= *([0-9]|[1-9][0-9])$|(thermal|performance) warning level *= *[1-9]'; then
        die "thermal or performance warning, stopping: $t"
    fi
    while pgrep -fl 'xctest|swift-build|swift-frontend' > /dev/null 2>&1; do
        echo "boost_eval: a Swift build/test is running; waiting"
        sleep 30
    done
    if [ "$STOP_AT" -gt 0 ] && [ "$(date +%s)" -ge "$STOP_AT" ]; then
        die "STOP_AT reached; re-run the same stage to resume (finished files are skipped)"
    fi
}

# shellcheck disable=SC2086  # TERMS is a word list on purpose; '_' stands for a space inside a term
terms_stdin() { printf '%s\n' $TERMS | tr '_' ' '; }

cmd_corpus() {
    [ -f "$WORK/vocab.json" ] || python3 -I "$here/parakeet_vocab.py" "$MODEL" > "$WORK/vocab.json"
    python3 -I "$here/boost_corpus.py" "$WORK/vocab.json" "$WORK" "$repo"
}

cmd_synth() {
    [ -f "$WORK/manifest.tsv" ] || cmd_corpus
    local have
    have=$(ox-say voice ls 2>&1) || die "ox-say voice ls failed: $have"
    for v in ru-milena ru-ruslan en-emma; do
        printf '%s\n' "$have" | grep -q "^$v " || die "voice $v is not installed (ox-say voice ls)"
    done
    guard
    local n=0 id kind _lang voice text _terms attempt
    while IFS=$'\t' read -r id kind _lang voice text _terms; do
        [ -f "$WORK/audio/$id.wav" ] && continue
        n=$((n + 1))
        if [ $((n % 25)) -eq 0 ]; then guard; fi
        # the engine now and then runs past its length budget (502); the message says to take another seed
        for attempt in 0 1 2 3; do
            ox-say say -v "$voice" --seed $((SEED + 10#${id//[!0-9]/} + 1000 * attempt)) -f wav -o "$WORK/raw/$id.wav" "$text" \
                > /dev/null 2> "$WORK/raw/$id.err" < /dev/null && break
            [ "$attempt" -lt 3 ] || die "ox-say say failed 4 times for $id: $(cat "$WORK/raw/$id.err")"
        done
        ffmpeg -nostdin -v error -y -i "$WORK/raw/$id.wav" -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/audio/$id.wav"
    done < "$WORK/manifest.tsv"
    # silence-padded variants (3 s of digital silence on each side) of every 8th term clip, and 5 s of pure
    # silence: the patch-level self-checks (a boost must not make words out of silence)
    local k=0
    while IFS=$'\t' read -r id kind _lang _voice _text _terms; do
        [ "$kind" = term ] || continue
        k=$((k + 1))
        [ $((k % 8)) -eq 0 ] || continue
        [ -f "$WORK/audio/sp-$id.wav" ] && continue
        ffmpeg -nostdin -v error -y -f lavfi -t 3 -i anullsrc=r=16000:cl=mono -i "$WORK/audio/$id.wav" \
            -f lavfi -t 3 -i anullsrc=r=16000:cl=mono -filter_complex '[0][1][2]concat=n=3:v=0:a=1' \
            -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/audio/sp-$id.wav"
    done < "$WORK/manifest.tsv"
    [ -f "$WORK/audio/silence.wav" ] ||
        ffmpeg -nostdin -v error -y -f lavfi -t 5 -i anullsrc=r=16000:cl=mono -c:a pcm_s16le "$WORK/audio/silence.wav"
    echo "synth done: $(find "$WORK/audio" -name '*.wav' | wc -l | tr -d ' ') files"
}

# run_arm <clip> <arm> [alpha]: arm base = no flags; otherwise --terms-stdin --boost-alpha <alpha>
run_arm() {
    local clip=$1 arm=$2 alpha=${3:-} d="$WORK/out/$2"
    mkdir -p "$d"
    [ -f "$d/$clip.json" ] && return 0
    if [ "$arm" = base ]; then
        nice -n 15 "$OXSTT" -m "$MODEL" -f "$WORK/audio/$clip.wav" -v > "$d/$clip.json.tmp" 2> "$d/$clip.err"
    else
        terms_stdin | nice -n 15 "$OXSTT" -m "$MODEL" -f "$WORK/audio/$clip.wav" --terms-stdin --boost-alpha "$alpha" -v \
            > "$d/$clip.json.tmp" 2> "$d/$clip.err"
    fi
    mv "$d/$clip.json.tmp" "$d/$clip.json"
}

cmd_decode() {
    [ -x "$OXSTT" ] || die "no ox-stt at $OXSTT (OX_SAY_ONLY=stt engine/build.sh <dir>)"
    [ -f "$MODEL" ] || die "no model at $MODEL"
    guard
    local n=0 clip
    local clips
    clips=$(find "$WORK/audio" -name '*.wav' | sed 's|.*/||; s|\.wav$||' | LC_ALL=C sort | grep -v '^test$')
    for clip in $clips; do
        n=$((n + 1))
        if [ $((n % 25)) -eq 0 ]; then guard; fi
        case $clip in
            sp-* | silence)
                run_arm "$clip" base
                run_arm "$clip" tiny 0.000001
                run_arm "$clip" huge 30
                ;;
            *)
                run_arm "$clip" base
                run_arm "$clip" a0 0
                run_arm "$clip" a1 1
                run_arm "$clip" a2 2
                run_arm "$clip" a3 3
                if [ $((n % 4)) -eq 0 ]; then
                    run_arm "$clip" tiny 0.000001
                    run_arm "$clip" huge 30
                fi
                ;;
        esac
    done
    echo "decode done"
}

cmd_score() {
    python3 -I "$here/boost_score.py" "$WORK"
}

case ${1:-} in
    corpus) cmd_corpus ;;
    synth) cmd_synth ;;
    decode) cmd_decode ;;
    score) cmd_score ;;
    all) cmd_corpus; cmd_synth; cmd_decode; cmd_score ;;
    *) die "usage: boost_eval.sh corpus|synth|decode|score|all" ;;
esac
