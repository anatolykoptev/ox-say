#!/bin/bash
# tts-server must stop a take whose talker does not end inside its frame budget
# and answer an ERROR, never a cut WAV (patches/qwentts/0003, #122). This runs a
# real tts-server on a spare port with the real models:
#   1. a budget hit on the wav route -> HTTP 502, error type generation_runaway;
#   2. a budget hit on the streaming (pcm) route, after the 200 went out -> the
#      transfer FAILS (curl 18), it does not end cleanly;
#   3. the derived budget is logged and a normal sentence is untouched (200,
#      more than a second of audio, EOS before the budget).
# A cap of 5 frames stands in for a talker that never emits EOS: both end the
# same way, in the engine's budget check (src/pipeline-tts.cpp).
#
# Usage: bash scripts/test-tts-frame-budget.sh [tts-server] [models-dir]
#   defaults: build/engine/out/tts-server, ~/Library/Application Support/ox-say/models
# Exit 0 = pass, 1 = fail, 77 = skipped (no engine or models here; says so).
#
# Mutation: in patches/qwentts/0003, replace `s.step >= s.frame_budget` with
# `s.step >= p->max_new_tokens` (the old silent cap) and rebuild -> check 1 fails.
set -u
root=$(cd "$(dirname "$0")/.." && pwd -P)
bin=${1:-"$root/build/engine/out/tts-server"}
models=${2:-"$HOME/Library/Application Support/ox-say/models"}
talker="$models/qwen-talker-0.6b-base-Q8_0.gguf"
codec="$models/qwen-tokenizer-12hz-F32.gguf"
for f in "$bin" "$talker" "$codec"; do
    [ -f "$f" ] || { echo "SKIP test-tts-frame-budget: $f is missing"; exit 77; }
done

port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
tmp=$(mktemp -d)
log=$tmp/engine.log
"$bin" --model "$talker" --codec "$codec" --host 127.0.0.1 --port "$port" --max-batch 1 >"$log" 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$tmp"/*; rmdir "$tmp"; }
trap cleanup EXIT
for _ in $(seq 1 90); do
    curl -s -m 2 "http://127.0.0.1:$port/health" >/dev/null && break
    sleep 2
done
curl -s -m 2 "http://127.0.0.1:$port/health" >/dev/null || { echo "FAIL engine did not start; see:"; tail -5 "$log"; exit 1; }

fail=0
say() { # say <json> <out> -> prints "<http code> <curl exit>"
    local code rc
    code=$(curl -s -m 120 -o "$2" -w '%{http_code}' "http://127.0.0.1:$port/v1/audio/speech" \
        -H 'content-type: application/json' -d "$1")
    rc=$?
    echo "$code $rc"
}
text='The weather is nice today, and we are going for a walk.'

read -r code rc < <(say "{\"input\":\"$text\",\"seed\":1,\"response_format\":\"wav\",\"max_new_tokens\":5}" "$tmp/a.out")
if [ "$code" = 502 ] && grep -q '"type":"generation_runaway"' "$tmp/a.out"; then
    echo "ok   wav route: budget hit -> 502 generation_runaway"
else
    echo "FAIL wav route: http=$code curl=$rc body=$(head -c 200 "$tmp/a.out" | tr -d '\000')"; fail=1
fi

read -r code rc < <(say "{\"input\":\"$text\",\"seed\":1,\"response_format\":\"pcm\",\"max_new_tokens\":5}" "$tmp/b.out")
if [ "$rc" = 18 ]; then
    echo "ok   pcm route: budget hit after the 200 -> the transfer fails (curl 18)"
else
    echo "FAIL pcm route: http=$code curl=$rc (want a failed transfer, curl 18)"; fail=1
fi

read -r code rc < <(say "{\"input\":\"$text\",\"seed\":1,\"response_format\":\"wav\"}" "$tmp/c.out")
size=$(wc -c <"$tmp/c.out" | tr -d ' ')
if [ "$code" = 200 ] && [ "$size" -gt 48000 ] && grep -q 'Frame budget' "$log" && grep -q 'EOS at step' "$log"; then
    echo "ok   normal sentence: 200, $size bytes, EOS inside the logged budget"
else
    echo "FAIL normal sentence: http=$code bytes=$size"; fail=1
fi
exit $fail
