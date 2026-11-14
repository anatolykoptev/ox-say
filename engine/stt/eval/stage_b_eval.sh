#!/usr/bin/env bash
# Stage B eval: the real daemon path (Daemon.Transcribe -> boost list from a synthetic temp glossary -> resident
# ox-stt /transcribe with X-Ox-Terms), unboosted and boosted per clip, interleaved; then stage_b_score.py.
#
#   engine/stt/eval/stage_b_eval.sh [run|score]
#
# Needs the clips and manifests of boost_eval.sh (synth / cyr) in $WORK, an ox-stt built from this tree, the
# parakeet model. Env: WORK (default ~/tmp/ox-say-boost-spike), OXSTT, MODEL, OUT, ALPHA (default 2).
# Mac safety: one heavy job at a time; waits while a Swift build/test runs, stops on a thermal warning.
# Never touches the installed OxSay: the daemon here is in-process in a Go test with a temp $OX_SAY_HOME.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
WORK=${WORK:-$HOME/tmp/ox-say-boost-spike}
OXSTT=${OXSTT:?set OXSTT to the ox-stt built from this tree}
MODEL=${MODEL:-$WORK/models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin}
OUT=${OUT:-$WORK/stage-b-results.jsonl}
ALPHA=${ALPHA:-2}

guard() {
    local t
    t=$(pmset -g therm 2>&1 || true)
    if printf '%s\n' "$t" | grep -Eq 'CPU_Speed_Limit *= *([0-9]|[1-9][0-9])$|(thermal|performance) warning level *= *[1-9]'; then
        echo "stage_b_eval: thermal or performance warning, stopping: $t" >&2
        exit 1
    fi
    while pgrep -fl 'xctest|swift-build|swift-frontend' > /dev/null 2>&1; do
        echo "stage_b_eval: a Swift build/test is running; waiting"
        sleep 30
    done
}

case ${1:-run} in
    run)
        guard
        cd "$repo"
        BOOST_EVAL_WORK="$WORK" BOOST_EVAL_STT="$OXSTT" BOOST_EVAL_MODEL="$MODEL" BOOST_EVAL_OUT="$OUT" BOOST_EVAL_ALPHA="$ALPHA" \
            GOWORK=off nice -n 10 go test -tags boosteval -count=1 -timeout 60m -run TestBoostEval -v ./internal/daemon
        python3 -I "$here/stage_b_score.py" "$WORK" "$OUT"
        ;;
    score) python3 -I "$here/stage_b_score.py" "$WORK" "$OUT" ;;
    *) echo "usage: stage_b_eval.sh [run|score]" >&2; exit 2 ;;
esac
