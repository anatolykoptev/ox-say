#!/bin/bash
# Gated model test for #123: Parakeet must not drop speech at chunk edges. Needs the Parakeet and
# Silero VAD models (CI has neither: it SKIPs with a message, after the fixture drift guard).
# Starts its own ox-stt --serve on a free loopback port; never touches the daemon's engine.
# Compatible with /bin/bash 3.2; the driver is python3 with the standard library only.
#
# Run: bash scripts/test-stt-edges.sh
#   OX_STT_BIN    ox-stt binary      (default build/engine/out/ox-stt, from engine/build.sh)
#   OX_STT_MODEL  Parakeet model     (default the installed one in ~/Library/Application Support/ox-say/models)
#   OX_STT_VAD    Silero VAD model   (same directory)
#   OX_STT_FLAGS  extra server flags (e.g. -ng)
#
# Fixtures (engine/stt/testdata/edges, 16 kHz mono PCM16, digital-zero edges trimmed) are ox-say
# TTS takes: `ox-say say -v <voice> --seed <n> -f wav -o x.wav "<text>"`, then
# `ffmpeg -ar 16000 -ac 1`, then trimmed to the first/last sample above 1e-3. Their sha256 is
# asserted first: a TTS or resampler change must not turn this test vacuously green. Assertions are
# word-count floors, not exact text.
#
# Mutations that must turn this RED:
#   * engine/stt/ox-stt.cpp decode_parakeet: pass the raw chunk to parakeet_full
#     (`x.data() + b[c], (int) n`) instead of the padded one -> "tight ready-en-deniro-s4" fails
#     with 0 words, and the cuts and the session stream fall under their floors
#   * decode_parakeet: push words with the raw padded times (d.t0 / d.t1) instead of the placed
#     t0 / t1 -> word times land 1 s late -> the "starts by" / "ends within the clip" checks fail
#   * edge_pad.h place(): set kDropMarginFrames to 0 -> "Thanks" loses "Than" -> the edge-word check fails
#   * decode_parakeet: drop the trailing_punct exemption -> "soon." loses its period -> the edge-word check fails
#   * edge_pad.h pad(): drop the floor check -> edge_pad_test's t_floor fails (not run against this
#     script: the silence controls here guard the outcome, not the mechanism)
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
data="$root/engine/stt/testdata/edges"
models="$HOME/Library/Application Support/ox-say/models"
bin=${OX_STT_BIN:-"$root/build/engine/out/ox-stt"}
model=${OX_STT_MODEL:-"$models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin"}
vad=${OX_STT_VAD:-"$models/ggml-silero-v5.1.2.bin"}

# Drift guard: runs everywhere, model or not.
bad=0
while read -r sum name; do
    got=$(shasum -a 256 "$data/$name" 2>/dev/null | cut -d' ' -f1)
    if [ "$got" != "$sum" ]; then
        echo "FAIL fixture $name: sha256 ${got:-missing}, expected $sum"
        bad=1
    fi
done <<'SUMS'
caf88ffa5424a28806c699b47fb870f5b7d5bc6acc413f223d88b6d97ef95fef ready-en-deniro-s4.wav
ae162141a16e2cbb2bc44117450b27c9738e7928a0c68735065427d050005006 ready-en-geralt-s3.wav
a3beabd9dba1a00075bc212698d1618432116730fadd6a51b22238980ad11661 ready-en-geralt-s7.wav
8af9062c38192d73a94b3e201f2046a321cf8fcb6b359a2c6e3e511242bd00d7 ready-en-deniro-s21.wav
74fa643550aeb1a18703eebc068d5d85e88c7705ab3f55d5a12d55d4a906a17c ready-en-deniro-s2.wav
1a7c23a4a8f0242e27402bc3bea47f01e102cd10d14b119877b59c7d1b961e28 ready-en-deniro-s3.wav
31627a766a77a5f3937b8e47c7faf4716604d9443a395049afa57faceccde6fa weather-en-geralt-s3.wav
ef4758b155e275bfb46c69c669246d0b98dfcd47d2a0b7ee92d95288dc0a90aa station-en-deniro-s1.wav
0beeea2efa7f97bc2afc86dbcd896dc27176ffdbb0f712bfe106b71f04823ddc thanks-en-freeman-s5.wav
49836bb199cce19d43484d52267dcde3b499ad6a6b4a6864d1f94758b9a23751 save-ru-ruslan-s5.wav
SUMS
[ "$bad" = 0 ] || exit 1
echo "ok   fixtures match their sha256"

for f in "$model" "$vad"; do
    if [ ! -f "$f" ]; then
        echo "SKIP test-stt-edges: model not found: $f (set OX_STT_MODEL / OX_STT_VAD)"
        exit 0
    fi
done
if [ ! -x "$bin" ]; then
    echo "FAIL ox-stt not found at $bin: build it with engine/build.sh or set OX_STT_BIN"
    exit 1
fi

port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
log=$(mktemp "${TMPDIR:-/tmp}/ox-stt-edges.XXXXXX")
# shellcheck disable=SC2086  # OX_STT_FLAGS is a flag list
"$bin" --serve -m "$model" --vad "$vad" --port "$port" ${OX_STT_FLAGS:-} > "$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$log"' EXIT

python3 -I - "$port" "$data" "$pid" "$log" <<'PY'
import array, json, math, os, random, sys, time, urllib.error, urllib.request, wave

port, data, pid, log = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
base = "http://127.0.0.1:" + port
SR = 16000
fails = 0


def ok(msg):
    print("ok   " + msg, flush=True)


def fail(msg):
    global fails
    fails += 1
    print("FAIL " + msg, flush=True)


def check(cond, msg):
    (ok if cond else fail)(msg)


def post(path, body, ctype):
    r = urllib.request.Request(base + path, data=body, method="POST", headers={"Content-Type": ctype})
    try:
        with urllib.request.urlopen(r, timeout=600) as f:
            return f.status, f.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


for _ in range(360):  # up to 3 min: a first GPU run may compile Metal shaders
    try:
        os.kill(pid, 0)
    except OSError:
        print("FAIL ox-stt exited before it was ready:\n" + open(log).read()[-2000:])
        sys.exit(1)
    try:
        with urllib.request.urlopen(base + "/health", timeout=2) as f:
            if f.status == 200:
                break
    except Exception:
        time.sleep(0.5)
else:
    print("FAIL ox-stt did not become ready in 3 min")
    sys.exit(1)


def load(name):
    with wave.open(os.path.join(data, name)) as w:
        assert w.getframerate() == SR and w.getnchannels() == 1 and w.getsampwidth() == 2, name
        a = array.array("h", w.readframes(w.getnframes()))
    if sys.byteorder != "little":
        a.byteswap()
    return [v / 32768.0 for v in a]


def wav(x):
    a = array.array("h", (max(-32768, min(32767, int(round(v * 32768.0)))) for v in x))
    if sys.byteorder != "little":
        a.byteswap()
    import io
    b = io.BytesIO()
    with wave.open(b, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(a.tobytes())
    return b.getvalue()


def transcribe(x):
    st, b = post("/transcribe", wav(x), "audio/wav")
    if st != 200:
        raise SystemExit("FAIL /transcribe answered %d: %r" % (st, b[:200]))
    return json.loads(b)


def session(x, chunk=1600):
    st, b = post("/sessions", b"{}", "application/json")
    if st != 200:
        raise SystemExit("FAIL POST /sessions answered %d: %r" % (st, b[:200]))
    sid = json.loads(b)["id"]
    words = []
    for o in range(0, len(x), chunk):
        a = array.array("f", x[o:o + chunk])
        if sys.byteorder != "little":
            a.byteswap()
        while True:
            st, b = post("/sessions/%s/audio" % sid, a.tobytes(), "application/octet-stream")
            if st != 429:
                break
            time.sleep(0.2)  # decode backlog: the audio was not taken; send it again
        if st != 200:
            raise SystemExit("FAIL session audio answered %d: %r" % (st, b[:200]))
        words += json.loads(b).get("words", [])
    st, b = post("/sessions/%s/finish" % sid, b"{}", "application/json")
    if st != 200:
        raise SystemExit("FAIL session finish answered %d: %r" % (st, b[:200]))
    return words + json.loads(b).get("words", [])


def said(ws):
    return " ".join(w["w"] for w in ws) or "(nothing)"


def timing(label, ws, dur, speech_at):
    # Word times are on the input's own timeline: the first word starts near where the speech does,
    # the last ends inside the clip. Without the pad shift every time lands 1 s late.
    if not ws:
        return
    check(speech_at - 0.05 <= ws[0]["s"] < speech_at + 0.5,
          "%s: first word starts by %.2f s (got %.2f)" % (label, speech_at + 0.5, ws[0]["s"]))
    check(ws[-1]["e"] <= dur + 0.01, "%s: last word ends within the clip (%.2f <= %.2f s)" % (label, ws[-1]["e"], dur))
    check(all(w["s"] <= w["e"] for w in ws), "%s: every word has s <= e" % label)


# 1. Tight short clips: speech from the first sample to the last. Empty on the unpadded decode.
for name in ["ready-en-deniro-s4.wav", "ready-en-geralt-s3.wav", "ready-en-geralt-s7.wav", "ready-en-deniro-s21.wav"]:
    x = load(name)
    ws = transcribe(x)["words"]
    check(len(ws) >= 2, "tight %s: >= 2 words (got %d: %s)" % (name[:-4], len(ws), said(ws)))
    timing("tight " + name[:-4], ws, len(x) / SR, 0.0)

# 2. The same kind of clip with 1 s of digital silence on both sides: silence is not the cure.
for name in ["ready-en-deniro-s2.wav", "ready-en-deniro-s3.wav", "ready-en-deniro-s21.wav"]:
    x = [0.0] * SR + load(name) + [0.0] * SR
    ws = transcribe(x)["words"]
    check(len(ws) >= 2, "silence-padded %s: >= 2 words (got %d: %s)" % (name[:-4], len(ws), said(ws)))
    timing("silence-padded " + name[:-4], ws, len(x) / SR, 1.0)

# 3. Symptom A: two voices joined without a pause, cut mid-speech. The unpadded decode drops the
#    whole second voice (39 words: the first passage only).
e = load("weather-en-geralt-s3.wav") + load("station-en-deniro-s1.wav")
for T, floor in [(16, 50), (17, 51), (18, 56), (20, 62)]:
    x = e[:T * SR]
    ws = transcribe(x)["words"]
    check(len(ws) >= floor, "cut at %d s: >= %d words (got %d)" % (T, floor, len(ws)))
    timing("cut at %d s" % T, ws, T, 0.0)

# 4. Dictation path: 120 s of continuous speech through /sessions (VAD, 12 s cap cuts).
ws = session(e * 5)
check(len(ws) >= 380, "session stream %.0f s: >= 380 of 390 words (got %d)" % (len(e) * 5 / SR, len(ws)))
check(all(ws[i]["s"] <= ws[i + 1]["s"] + 0.01 for i in range(len(ws) - 1)), "session stream: word times are in order")

# 5. Edge words stay whole: clean clips the unpadded decode gets right must keep their first and last
#    word, final period included. TDT stamps the first/last pieces of speech a frame or two inside
#    the pad, and parakeet puts the final period at the last word's end: dropping "pad tokens" by
#    time alone cut "Thanks" to "ks" and "soon." to "soon" with the word counts unchanged.
for name, first, last in [("thanks-en-freeman-s5.wav", "Thanks", "soon."),
                          ("save-ru-ruslan-s5.wav", "\u0421\u043e\u0445\u0440\u0430\u043d\u0438", "\u043e\u043a\u043d\u043e.")]:
    x = load(name)
    for path, ws in [("one-shot", transcribe(x)["words"]), ("session", session(x))]:
        got = (ws[0]["w"], ws[-1]["w"]) if ws else ("", "")
        check(got == (first, last), "%s %s: first/last word %r/%r (got %r/%r)" % (path, name[:-4], first, last, got[0], got[1]))

# 6. Silence and noise stay empty: chunks under the floor are not padded, and noise alone is not speech.
rng = random.Random(7)
for label, x in [("1 s digital zeros", [0.0] * SR), ("3 s digital zeros", [0.0] * (3 * SR))] + [
        ("2 s white noise %d dBFS" % db, [rng.gauss(0.0, 10 ** (db / 20)) for _ in range(2 * SR)]) for db in (-50, -40, -30)]:
    ws = transcribe(x)["words"]
    check(not ws, "%s: no words (got %s)" % (label, said(ws)))

print("%s test-stt-edges: %d failure(s)" % ("FAIL" if fails else "ok  ", fails))
sys.exit(1 if fails else 0)
PY
