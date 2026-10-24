#!/usr/bin/env bash
# Does a running diarization slow a dictation down? The M3 question of plan Task 20: if it does, ox-diar must be held
# while a dictation is in flight (the conditional step "hold ox-diar"); if it does not, it is not built.
#
#   scripts/probe-diar-dictation.sh <ox-diar> <models-dir> <long.pcm> <clip.wav> [requests]
#     <long.pcm>  raw 16 kHz mono s16le speech (what ox-diar reads: a meeting's them.pcm), 20 minutes or more; it is
#                 diarized again and again for the length of the probe
#     <clip.wav>  5 to 10 seconds of speech: the dictation stand-in, posted to the running daemon's
#                 /v1/audio/transcriptions (the engine dictation uses)
#     requests    per phase, default 20
# Needs the daemon running (OX_SAY_ADDR, default 127.0.0.1:8094). Phase 1 posts the clip with nothing else running;
# phase 2 posts it while ox-diar loops over the long recording. Prints both p50 and p95 and exits 1 when the p95 during
# a diarization is both 25 % and 150 ms above the idle one. Those two numbers are a starting guess, not a measurement:
# the probe's first run on a real Mac is what sets them.
set -u
bin=${1:?usage: $0 <ox-diar> <models-dir> <long.pcm> <clip.wav> [requests]}
models=${2:?}; long=${3:?}; clip=${4:?}; n=${5:-20}
addr=${OX_SAY_ADDR:-127.0.0.1:8094}

# percentile <p> <numbers on stdin>: nearest-rank, seconds
percentile() { sort -n | awk -v p="$1" '{ v[NR] = $1 } END { i = int((p / 100) * NR + 0.999999); if (i < 1) i = 1; if (i > NR) i = NR; print v[i] }'; }

latencies() { # n times: one transcription of the clip, its wall time in seconds
    local i
    for ((i = 0; i < n; i++)); do
        curl -s -o /dev/null -w '%{time_total}\n' -F "file=@$clip" -F model=parakeet "http://$addr/v1/audio/transcriptions"
        sleep 0.5
    done
}

idle=$(latencies)
out=$(mktemp -d "${TMPDIR:-/tmp}/ox-diar-probe.XXXXXX")
( while [ ! -e "$out/stop" ]; do "$bin" "$long" "$out/o.json" --models "$models" > /dev/null 2>&1 || break; done ) &
loop=$!
sleep 3 # let the first diarization get going
busy=$(latencies)
touch "$out/stop"
wait "$loop"
rm -f "$out/o.json" "$out/stop"
rmdir "$out"

i50=$(printf '%s\n' "$idle" | percentile 50); i95=$(printf '%s\n' "$idle" | percentile 95)
b50=$(printf '%s\n' "$busy" | percentile 50); b95=$(printf '%s\n' "$busy" | percentile 95)
echo "dictation latency, $n requests: idle p50 ${i50}s p95 ${i95}s; during a diarization p50 ${b50}s p95 ${b95}s"
awk -v i="$i95" -v b="$b95" 'BEGIN { exit !(b > i * 1.25 && b - i > 0.15) }' && { echo "REGRESSION: hold ox-diar while a dictation is in flight" >&2; exit 1; }
echo "no regression: ox-diar is not held"
