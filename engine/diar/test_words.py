#!/usr/bin/env python3
"""Preparation for the word-level "who said what" gate.

`prep` builds, per meeting, under --out (scratch, never the repo):
  <id>/them.pcm            raw 16 kHz mono s16le of the mix, the channel ox-diar and the runner both read
  <id>/hyp.json           the words of the REAL Parakeet path: the file cut in internal/meeting pieces
                          (audio.go Spans/QuietestWindow/Silent, DefaultPieceSeconds = 240 s) and each
                          loud piece POSTed as a raw WAV body to an own `ox-stt --serve` the way the
                          daemon's transcribeServer does (stt.go: POST <base>/transcribe,
                          Content-Type audio/wav), piece offset added like runner.go recognize()
  <id>/ref.json           the AMI manual words: <w> elements of words/<id>.<channel>.words.xml
                          (punc/vocalsound/disfmarker skipped), lowercased, sorted by start; the
                          channel letter maps to the participant through corpusResources/meetings.xml
  <id>/diar/old.json      ox-diar --engine pyannote (existing models, read-only)
  <id>/diar/nemotron.json ox-diar --engine nemotron
  <id>/diar/g00..g20.json the saved fast128 probabilities through oxprobe `segs` at merge gaps
                          0/50/100/150/200 frames (the Timeline.mergeGaps code, by source)
  <id>/diar/oracle.json   the exclusive manual timeline: the manual RTTM turned exclusive (per-atom
                          majority of the manual words), with `embedding: []` like Nemotron, so
                          Decide joins a folded speaker by time exactly as it does for Nemotron
                          (the file keeps the name "oracle"; it is not a ceiling)
and asserts g15 equals ox-diar --engine nemotron to the millisecond on every meeting. The gate itself
is internal/meeting/whosaid_test.go under the `whosaid` build tag, pointed at this directory by
OX_WHOSAID_DIR (for example OX_WHOSAID_DIR=/path/to/whosaid).

Existing files are reused so an interrupted run resumes; `--force` regenerates the diarization
variants instead (the recognizer words and the reference words are kept).

Needs no Python packages. The AMI manual annotations zip must be the 1.6.2 archive whose sha256 is
pinned below; the Parakeet and VAD models must match the SHA-256 pinned in scripts/fetch-models.sh.
Audio never leaves --out; the reports it feeds hold no transcript text.
"""
import argparse
import array
import hashlib
import http.client
import json
import math
import os
import re
import socket
import struct
import subprocess
import sys
import time
import wave
import xml.etree.ElementTree as ET
import zipfile

SR = 16000
PIECE_SAMPLES = 240 * SR            # meeting.DefaultPieceSeconds
SEARCH_SAMPLES = 12 * SR            # audio.go searchSamples
QUIET_WINDOW = SR // 2              # audio.go quietWindow
RMS_WINDOW = SR // 10               # audio.go rmsWindow
MIN_LOUD_WINDOWS = 2                # audio.go minLoudWindows
SILENT_RMS = 75                     # audio.go silentRMS
PIECE_ATTEMPTS = 4                  # runner.go pieceAttempts
GAPS = {"g00": 0, "g05": 50, "g10": 100, "g15": 150, "g20": 200}
ANN_SHA256 = "b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d"
FETCH_MODELS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts", "fetch-models.sh")


def fail(msg):
    sys.exit(f"test_words: {msg}")


def shasum(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def pinned_sha(name):
    """The SHA-256 scripts/fetch-models.sh pins for a model file name (its `name sha256 url` entries)."""
    with open(FETCH_MODELS) as f:
        for line in f:
            m = re.match(r'\s*"([^\s"]+) ([0-9a-f]{64}) ', line)
            if m and m.group(1) == name:
                return m.group(2)
    fail(f"{name}: no pinned sha256 in {FETCH_MODELS}")


def verify_model(path):
    want = pinned_sha(os.path.basename(path))
    if shasum(path) != want:
        fail(f"{path}: sha256 mismatch against scripts/fetch-models.sh (want {want})")


# ---------------------------------------------------------------- audio, a port of internal/meeting/audio.go
# (and pcm.Clip.QuietestWindow / Encode). Keep in step with the Go comments.

def quietest_window(samples, window):
    """pcm.Clip.QuietestWindow: the least-energy whole window, half-window steps, earliest tie."""
    if window <= 0 or len(samples) <= window:
        return 0
    step = max(1, window // 2)
    best, best_energy = 0, float("inf")
    frm = 0
    while frm + window <= len(samples):
        e = 0.0
        for s in samples[frm:frm + window]:
            e += s * s
        if e < best_energy:
            best, best_energy = frm, e
        frm += step
    return best


def spans(total):
    """audio.go Spans: ~240 s pieces cut at the quietest half second within 12 s either side of the
    nominal cut; a tail shorter than a quarter piece joins the piece before it. Returns [(from, to))
    in samples."""
    min_tail = PIECE_SAMPLES // 4
    out = []
    frm = 0
    while frm + PIECE_SAMPLES + min_tail < total:
        nominal = frm + PIECE_SAMPLES
        lo = max(frm + SR, nominal - SEARCH_SAMPLES)
        hi = min(total, nominal + SEARCH_SAMPLES + QUIET_WINDOW)
        cut = lo + quietest_window(SAMPLES[lo:hi], QUIET_WINDOW) + QUIET_WINDOW // 2
        out.append((frm, cut))
        frm = cut
    out.append((frm, total))
    return out


def silent(clip):
    """audio.go Silent: fewer than MIN_LOUD_WINDOWS of the 100 ms windows have an RMS over SILENT_RMS;
    a short last window is padded with zeros."""
    windows = (len(clip) + RMS_WINDOW - 1) // RMS_WINDOW
    need = min(MIN_LOUD_WINDOWS, windows)
    loud = 0
    for frm in range(0, len(clip), RMS_WINDOW):
        seg = clip[frm:frm + RMS_WINDOW]
        energy = sum(s * s for s in seg)
        if math.sqrt(energy / RMS_WINDOW) > SILENT_RMS:
            loud += 1
            if loud >= need:
                return False
    return True


def encode_wav(clip):
    """pcm.Clip.Encode: canonical 44-byte-header 16-bit mono WAV."""
    import io
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(clip.tobytes())
    return buf.getvalue()


def read_pcm(path):
    a = array.array("h")
    with open(path, "rb") as f:
        a.frombytes(f.read())
    if sys.byteorder == "big":
        a.byteswap()
    return a


SAMPLES = array.array("h")  # the meeting's them.pcm, loaded once per prep_meeting


# ---------------------------------------------------------------- the resident server, own PID only

def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class STTServer:
    """An own `ox-stt --serve` on a free loopback port, argv as the daemon's STTServeArgs on Apple
    Silicon (GPU, --vad, --redecode-max-s 15). `nice` execs, so proc.pid is the ox-stt PID; stopped
    by terminate() on exactly that PID."""

    def __init__(self, binary, model, vad, log):
        self.port = free_port()
        self.log = open(log, "wb")
        argv = ["nice", "-n", "15", binary, "--serve", "--port", str(self.port), "-m", model,
                "--vad", vad, "--redecode-max-s", "15"]
        self.logpath = log
        self.proc = subprocess.Popen(argv, stdout=self.log, stderr=self.log, stdin=subprocess.DEVNULL)
        self.pid = self.proc.pid
        self.ready_s = 0.0

    def wait_healthy(self, limit=600):
        """Poll /health once a second. The caller holds the server under try/finally, so an
        interrupt or a fail() here still reaches stop()."""
        t0 = time.time()
        while time.time() - t0 < limit:
            if self.proc.poll() is not None:
                fail(f"ox-stt exited early (code {self.proc.returncode}); see {self.logpath}")
            try:
                if self.call("GET", "/health")[0] == 200:
                    self.ready_s = time.time() - t0
                    return
            except OSError:
                pass
            time.sleep(1)
        fail(f"ox-stt did not become healthy in {limit} s")

    def call(self, method, path, body=None, ctype=None, timeout=600):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        try:
            c.request(method, path, body=body, headers={"Content-Type": ctype} if ctype else {})
            r = c.getresponse()
            return r.status, r.read()
        finally:
            c.close()

    def transcribe(self, wav):
        """stt.go transcribeServer: raw WAV body, Content-Type audio/wav; runner.go retries one call
        PIECE_ATTEMPTS times. Returns the engine's stt.Result dict."""
        err = None
        for attempt in range(1, PIECE_ATTEMPTS + 1):
            st, body = self.call("POST", "/transcribe", wav, "audio/wav")
            if st == 200:
                return json.loads(body)
            err = RuntimeError(f"/transcribe {st}: {body[:200]!r}")
            if attempt < PIECE_ATTEMPTS:
                time.sleep(attempt)
        raise err

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(20)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.log.close()


# ---------------------------------------------------------------- AMI manual annotations

def ann_meetings(zf):
    """corpusResources/meetings.xml: per observation, nxt_agent (channel) -> global_name."""
    with zf.open("corpusResources/meetings.xml") as f:
        root = ET.parse(f).getroot()
    out = {}
    for m in root.iter("meeting"):
        obs = m.get("observation")
        if not obs:
            continue
        out[obs] = {s.get("nxt_agent"): s.get("global_name")
                    for s in m.iter("speaker") if s.get("nxt_agent")}
    return out


def ref_words(zf, meeting, agents):
    """The meeting's manual words: <w> elements of every channel, punc/vocalsound/disfmarker skipped,
    lowercased, sorted by start. Speaker = the channel's participant (the RTTM label space)."""
    words = []
    for ch, spk in sorted(agents.items()):
        name = f"words/{meeting}.{ch}.words.xml"
        try:
            f = zf.open(name)
        except KeyError:
            continue
        with f:
            for el in ET.parse(f).getroot():
                if el.tag != "w" or el.get("punc") == "true":
                    continue
                try:
                    s, e = float(el.get("starttime")), float(el.get("endtime", el.get("starttime")))
                except (TypeError, ValueError):
                    continue
                text = (el.text or "").strip().lower()
                if text:
                    words.append({"w": text, "s": s, "e": e, "spk": spk})
    words.sort(key=lambda w: (w["s"], w["e"]))
    return words


# ---------------------------------------------------------------- the exclusive manual timeline

def read_rttm(path):
    segs = []
    for line in open(path):
        p = line.split()
        if len(p) >= 8 and p[0] == "SPEAKER":
            s, d = float(p[3]), float(p[4])
            segs.append({"s": s, "e": s + d, "spk": p[7]})
    return sorted(segs, key=lambda x: (x["s"], x["e"]))


def manual_exclusive_diarization(rttm, words):
    """The exclusive manual timeline, from the overlapping manual RTTM. Every atomic interval between
    consecutive segment bounds is labelled with the speaker whose manual words cover the atom most
    (an atom no word covers goes to its earliest-starting covering segment); adjacent atoms of one
    speaker merge. Overlapped crosstalk keeps the dominant speaker only, so this is a reference
    timeline, not a ceiling. It carries no embeddings (`embedding: []`, as Nemotron's output): Decide
    joins a folded speaker by time, the same rule as for Nemotron. One-hot embeddings would make every
    cosine join 0 and land a folded speaker on an arbitrary voice."""
    bounds = sorted({x["s"] for x in rttm} | {x["e"] for x in rttm})
    # coverage of each atom by speaker, from the manual words (the ground truth of who is heard)
    bi = 0
    cover = {}
    for i in range(len(bounds) - 1):
        a, b = bounds[i], bounds[i + 1]
        if b - a <= 0:
            continue
        while bi < len(words) and words[bi]["e"] <= a:
            bi += 1
        shares = {}
        j = bi
        while j < len(words) and words[j]["s"] < b:
            w = words[j]
            ov = min(b, w["e"]) - max(a, w["s"])
            if ov > 0:
                shares[w["spk"]] = shares.get(w["spk"], 0.0) + ov
            j += 1
        cover[i] = shares
    atoms = []
    for i in range(len(bounds) - 1):
        a, b = bounds[i], bounds[i + 1]
        if b - a <= 0:
            continue
        here = [s for s in rttm if s["s"] < b and s["e"] > a]
        if not here:
            continue
        shares = cover.get(i, {})
        if shares:
            spk = max(sorted(shares), key=shares.get)
        else:
            spk = min(here, key=lambda s: s["s"])["spk"]
        if atoms and atoms[-1]["spk"] == spk and atoms[-1]["e"] >= a:
            atoms[-1]["e"] = b
        else:
            atoms.append({"s": a, "e": b, "spk": spk})
    return diarization_json(atoms, words[-1]["e"] if words else 0.0)


def diarization_json(segs, duration_s):
    """engine/diar Output.Diarization.make: ms-rounded, speakers 0..n-1 by descending speech."""
    def ms(x):
        return round(x * 1000) / 1000
    kept = sorted(({"s": ms(s["s"]), "e": ms(s["e"]), "spk": s["spk"]} for s in segs),
                  key=lambda x: (x["s"], x["e"]))
    kept = [s for s in kept if s["e"] > s["s"] and s["s"] >= 0]
    speech, first = {}, {}
    for s in kept:
        speech[s["spk"]] = speech.get(s["spk"], 0.0) + s["e"] - s["s"]
        first.setdefault(s["spk"], s["s"])
    order = sorted(speech, key=lambda k: (-ms(speech[k]), first[k], k))
    idx = {k: n for n, k in enumerate(order)}
    speakers = []
    for k in order:
        speakers.append({"id": idx[k], "speech_s": ms(speech[k]), "embedding": []})
    return {"version": 1, "duration_s": ms(duration_s), "speakers": speakers,
            "segments": [{"s": s["s"], "e": s["e"], "spk": idx[s["spk"]]} for s in kept],
            "timing_s": {"source": "manual-exclusive"}}


def gxx_to_diarization(gxx):
    """oxprobe segs already emits the Diarization.make shape; only the fields the gate needs."""
    return {"version": 1, "duration_s": gxx["duration_s"], "speakers": gxx["speakers"],
            "segments": gxx["segments"], "timing_s": gxx.get("timing_s", {})}


# ---------------------------------------------------------------- the heavy steps

def run(cmd, timeout=1800, log=None):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if log is not None:
        log.write(f"$ {' '.join(cmd)}\n{r.stdout}{r.stderr}\n")
        log.flush()
    if r.returncode != 0:
        fail(f"{' '.join(cmd[:3])}... exited {r.returncode}: {r.stderr[-300:]}")
    return r


def prep_meeting(mid, wav, zf, agents, args, srv, log):
    out = os.path.join(args.out, mid)
    os.makedirs(out, exist_ok=True)
    for d in ("diar", "pieces"):
        os.makedirs(os.path.join(out, d), exist_ok=True)

    pcm_path = os.path.join(out, "them.pcm")
    if not os.path.exists(pcm_path):
        run(["ffmpeg", "-nostdin", "-v", "error", "-i", wav, "-f", "s16le", "-ac", "1", "-ar", str(SR), "-y", pcm_path],
            log=log)
    global SAMPLES
    SAMPLES = read_pcm(pcm_path)
    total = len(SAMPLES)
    print(f"{mid}: {total / SR:.0f} s", flush=True)

    # (a) the recognizer's words, the meeting runner's own cutting and request shape
    hyp_path = os.path.join(out, "hyp.json")
    if not os.path.exists(hyp_path):
        pieces, words = [], []
        for frm, to in spans(total):
            cache = os.path.join(out, "pieces", f"{frm}-{to}.json")
            if os.path.exists(cache):
                with open(cache) as f:
                    pc = json.load(f)
            else:
                clip = SAMPLES[frm:to]
                if silent(clip):
                    pc = {"words": [], "loud": False}
                else:
                    res = srv.transcribe(encode_wav(clip))
                    pc = {"words": res.get("words", []), "loud": True}
                with open(cache, "w") as f:
                    json.dump(pc, f)
            ws = pc["words"]
            off = frm / SR
            for w in ws:
                w["s"] += off
                w["e"] += off
            words.extend(ws)
            pieces.append({"from": frm, "to": to, "loud": pc["loud"], "words": len(ws)})
            print(f"  piece {frm / SR:7.1f}-{to / SR:7.1f}s: {len(ws)} words", flush=True)
        with open(hyp_path, "w") as f:
            json.dump({"meeting": mid, "duration_s": total / SR, "pieces": pieces, "words": words}, f)

    # (b) the reference words
    ref = ref_words(zf, mid.removeprefix("mix_"), agents)
    ref_path = os.path.join(out, "ref.json")
    if not os.path.exists(ref_path):
        with open(ref_path, "w") as f:
            json.dump({"meeting": mid, "speakers": sorted(set(w["spk"] for w in ref)), "words": ref}, f)

    # (c) the diarization variants
    dpath = lambda v: os.path.join(out, "diar", v + ".json")  # noqa: E731
    if args.force or not os.path.exists(dpath("old")):
        run([args.ox_diar, pcm_path, dpath("old"),
             "--models", args.pyannote_models, "--engine", "pyannote"], log=log)
    if args.force or not os.path.exists(dpath("nemotron")):
        run([args.ox_diar, pcm_path, dpath("nemotron"),
             "--models", args.nemotron_models, "--engine", "nemotron"], log=log)
    probs = os.path.join(args.probs_dir, f"{mid}.f32")
    for name, gap in GAPS.items():
        if os.path.exists(dpath(name)) and not args.force:
            continue
        if not os.path.exists(probs):
            fail(f"no saved probabilities at {probs}")
        raw = os.path.join(out, "diar", f"{name}.segs.json")
        run([args.oxprobe, "segs", probs, raw, "--merge-gap", str(gap)], log=log)
        with open(raw) as f:
            d = gxx_to_diarization(json.load(f))
        with open(dpath(name), "w") as f:
            json.dump(d, f)
    if args.force or not os.path.exists(dpath("oracle")):
        rttm = read_rttm(os.path.join(args.refs_dir, f"{mid}.ref.rttm"))
        with open(dpath("oracle"), "w") as f:
            json.dump(manual_exclusive_diarization(rttm, ref), f)

    # the gate's precondition: g15 is the product, so the sweep measures the product's own rule
    with open(os.path.join(out, "diar", "g15.json")) as f:
        g15 = json.load(f)
    with open(os.path.join(out, "diar", "nemotron.json")) as f:
        nem = json.load(f)
    if g15["segments"] != nem["segments"] or \
            [s["id"] for s in g15["speakers"]] != [s["id"] for s in nem["speakers"]] or \
            [s["speech_s"] for s in g15["speakers"]] != [s["speech_s"] for s in nem["speakers"]]:
        fail(f"{mid}: g15 segments differ from the real ox-diar --engine nemotron output; "
             "the sweep would not measure the product (stop, report)")
    print(f"  g15 == ox-diar --engine nemotron: {len(nem['segments'])} segments verified", flush=True)


def cmd_prep(args):
    for p in (args.ox_stt, args.ox_diar, args.oxprobe):
        if not os.path.isfile(p):
            fail(f"no binary at {p}")
    for d in (args.pyannote_models, args.nemotron_models, args.refs_dir, args.probs_dir):
        if not os.path.isdir(d):
            fail(f"no directory at {d}")
    if shasum(args.ann) != ANN_SHA256:
        fail(f"{args.ann}: sha256 mismatch (want the AMI manual annotations 1.6.2 archive)")
    if not (os.path.isfile(args.stt_model) and os.path.isfile(args.stt_vad)):
        fail("the Parakeet/VAD model is missing")
    verify_model(args.stt_model)
    verify_model(args.stt_vad)

    meetings = dict(m.split("=", 1) for m in args.meeting)
    os.makedirs(args.out, exist_ok=True)
    log = open(os.path.join(args.out, "prep.log"), "w")
    zf = zipfile.ZipFile(args.ann)
    agents_all = ann_meetings(zf)

    srv = None
    missing = [m for m, w in meetings.items() if not os.path.exists(os.path.join(args.out, m, "hyp.json"))]
    try:
        if missing:  # started inside the try: an interrupt or a fail() from here on still reaches stop()
            srv = STTServer(args.ox_stt, args.stt_model, args.stt_vad, os.path.join(args.out, "ox-stt.log"))
            srv.wait_healthy()
            print(f"ox-stt pid {srv.pid} port {srv.port}, healthy after {srv.ready_s:.0f} s", flush=True)
        for mid, wav in meetings.items():
            if not os.path.isfile(wav):
                fail(f"no mix at {wav}")
            ann = mid.removeprefix("mix_")
            if ann not in agents_all:
                fail(f"{ann}: no entry in corpusResources/meetings.xml")
            prep_meeting(mid, wav, zf, agents_all[ann], args, srv, log)
    finally:
        if srv:
            srv.stop()
        log.close()
    print("prep done", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prep", help="build hyp/ref/diar per meeting under --out")
    p.add_argument("--out", required=True)
    p.add_argument("--force", action="store_true", help="regenerate the diarization variants instead of reusing existing files")
    p.add_argument("--ox-stt", required=True)
    p.add_argument("--ox-diar", required=True)
    p.add_argument("--oxprobe", required=True)
    p.add_argument("--stt-model", required=True)
    p.add_argument("--stt-vad", required=True)
    p.add_argument("--pyannote-models", required=True, help="models dir holding speaker-diarization/")
    p.add_argument("--nemotron-models", required=True, help="models dir holding nemotron-3-diarization/")
    p.add_argument("--ann", required=True, help="ami_public_manual_1.6.2.zip")
    p.add_argument("--refs-dir", required=True, help="directory of <id>.ref.rttm")
    p.add_argument("--probs-dir", required=True, help="directory of <id>.f32 probabilities")
    p.add_argument("meeting", nargs="+", help="ID=/path/to/mix.wav")
    p.set_defaults(fn=cmd_prep)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
