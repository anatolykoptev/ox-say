#!/usr/bin/env python3
"""Accuracy gate for ox-diar: DER and speaker confusion against reference RTTMs, and the speaker count the daemon
would report, on one or more recordings.

Runs ox-diar on each 16 kHz mono WAV (turned into the raw s16le it takes) and scores its exclusive timeline with
pyannote.metrics (collar 0.25 s, overlapped speech skipped, the spike's setting). Not part of CI: it needs
pyannote.metrics (`pip install pyannote.metrics`, which brings pyannote.core and pyannote.database) and the AMI
recordings. Run with `python -I`.

Usage: test_der.py --bin PATH --models DIR [--engine pyannote|nemotron] --case WAV,RTTM,URI,SPEAKERS,MAX_DER[,MAX_CONF] [--case ...]
  e.g. --case ES2004a.Mix-Headset.wav,ES2004a.rttm,ES2004a,4,9.7,0.8

--engine picks the diarization engine (default nemotron); --models names the dir holding that engine's set
(`speaker-diarization/` for pyannote, `nemotron-3-diarization/` for nemotron). MAX_CONF bounds the speaker
confusion — the detailed DiarizationErrorRate's confusion/total, the share of scored speech put on the wrong
speaker — and `-` skips it. SPEAKERS compares against the substantial clusters under the daemon's Decide rule,
not the raw speaker list: a cluster is a person only at >= 45 s of speech and >= 8 % of all diarized speech
(constants of internal/meeting/diarize.go's SubstantialSeconds/SubstantialShare).

The limits that separate the Nemotron engine (fast128, 1.5 s gap merge) from the pyannote one, each the Nemotron
measurement on this scorer + 0.5 points of margin: ES2004a 9.7, IS1009b 2.6, EN2002a 8.6, ru_p0iI 5.6, ru_nr3h
16.6, ru_yCX4 6.5. DER alone does not separate the engines on ES2004a (pyannote scores better there); the
confusion limit does — 0.8 sits between Nemotron's worst AMI file (0.41 %) and pyannote's best (1.06 %) — and the
Russian rows do (pyannote's DER is 2-7x Nemotron's). The count-only cases (MAX_DER 100) exist to catch a Nemotron
regression on the commonest product input, a 1:1 call: a spurious second slot >= 45 s would flip it into "offer
split".
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import wave

# internal/meeting/diarize.go: SubstantialSeconds, SubstantialShare (the daemon's Decide rule for "a real person").
SUBSTANTIAL_SECONDS = 45.0
SUBSTANTIAL_SHARE = 0.08


def to_pcm(wav, pcm):
    with wave.open(wav, "rb") as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, 16000), f"{wav}: not 16 kHz mono s16"
        with open(pcm, "wb") as f:
            f.write(w.readframes(w.getnframes()))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bin", required=True)
    p.add_argument("--models", required=True)
    p.add_argument("--engine", default="nemotron", choices=["pyannote", "nemotron"])
    p.add_argument("--case", action="append", required=True)
    a = p.parse_args()
    from pyannote.core import Annotation, Segment, Timeline
    from pyannote.database.util import load_rttm
    from pyannote.metrics.diarization import DiarizationErrorRate

    fails = []
    with tempfile.TemporaryDirectory() as tmp:
        for spec in a.case:
            wav, rttm, uri, speakers, limit, *rest = spec.split(",")
            conf_limit = rest[0] if rest and rest[0] != "-" else None
            pcm, out = os.path.join(tmp, "a.pcm"), os.path.join(tmp, "o.json")
            to_pcm(wav, pcm)
            subprocess.run([a.bin, pcm, out, "--models", a.models, "--engine", a.engine], check=True, capture_output=True)
            with open(out) as f:
                got = json.load(f)
            hyp = Annotation(uri=uri)
            for s in got["segments"]:
                hyp[Segment(s["s"], s["e"])] = f"S{s['spk']}"
            ref = load_rttm(rttm)[uri]
            uem = Timeline([Segment(0, got["duration_s"])])
            comp = DiarizationErrorRate(collar=0.25, skip_overlap=True)(ref, hyp, uem=uem, detailed=True)
            der = comp["diarization error rate"] * 100
            conf = comp["confusion"] / comp["total"] * 100 if comp["total"] else 0.0
            total = sum(s["speech_s"] for s in got["speakers"])
            found = len([s for s in got["speakers"]
                         if s["speech_s"] >= SUBSTANTIAL_SECONDS and s["speech_s"] >= SUBSTANTIAL_SHARE * total])
            print(f"{uri}: DER {der:.2f}% (limit {limit}), confusion {conf:.2f}% (limit {conf_limit or '-'}), "
                  f"speakers found {found} (want {speakers}, reference {len(ref.labels())}), "
                  f"timing {got['timing_s']}")
            if der > float(limit):
                fails.append(f"{uri}: DER {der:.2f} > {limit}")
            if conf_limit is not None and conf > float(conf_limit):
                fails.append(f"{uri}: confusion {conf:.2f} > {conf_limit}")
            if found != int(speakers):
                fails.append(f"{uri}: found {found} substantial speakers, want {speakers}")
    for f in fails:
        print("FAIL", f, file=sys.stderr)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
