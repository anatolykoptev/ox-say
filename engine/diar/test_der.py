#!/usr/bin/env python3
"""Accuracy gate for ox-diar: DER against reference RTTMs, and the speaker count, on one or more recordings.

Runs ox-diar on each 16 kHz mono WAV (turned into the raw s16le it takes) and scores its exclusive timeline with
pyannote.metrics (collar 0.25 s, overlapped speech skipped, the spike's setting). Not part of CI: it needs
pyannote.metrics (`pip install pyannote.metrics`, which brings pyannote.core and pyannote.database) and the AMI
recordings. Run with `python -I`.

Usage: test_der.py --bin PATH --models DIR --case WAV,RTTM,URI,SPEAKERS,MAX_DER [--case ...]
  e.g. --case ES2004a.Mix-Headset.wav,ES2004a.rttm,ES2004a,4,8.7

The limits that separate the pinned configuration from the library's defaults (measured on the exclusive timeline,
pinned / defaults): ES2004a 8.25 / 8.97, so 8.7; the other two files' limits are set from the same measurement (see
the plan, Task 20a step 7). The decision's own gate, 9.5 on ES2004a, cannot tell the two apart.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import wave


def to_pcm(wav, pcm):
    with wave.open(wav, "rb") as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, 16000), f"{wav}: not 16 kHz mono s16"
        with open(pcm, "wb") as f:
            f.write(w.readframes(w.getnframes()))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bin", required=True)
    p.add_argument("--models", required=True)
    p.add_argument("--case", action="append", required=True)
    a = p.parse_args()
    from pyannote.core import Annotation, Segment, Timeline
    from pyannote.database.util import load_rttm
    from pyannote.metrics.diarization import DiarizationErrorRate

    fails = []
    with tempfile.TemporaryDirectory() as tmp:
        for spec in a.case:
            wav, rttm, uri, speakers, limit = spec.split(",")
            pcm, out = os.path.join(tmp, "a.pcm"), os.path.join(tmp, "o.json")
            to_pcm(wav, pcm)
            subprocess.run([a.bin, pcm, out, "--models", a.models], check=True, capture_output=True)
            with open(out) as f:
                got = json.load(f)
            hyp = Annotation(uri=uri)
            for s in got["segments"]:
                hyp[Segment(s["s"], s["e"])] = f"S{s['spk']}"
            ref = load_rttm(rttm)[uri]
            uem = Timeline([Segment(0, got["duration_s"])])
            der = DiarizationErrorRate(collar=0.25, skip_overlap=True)(ref, hyp, uem=uem) * 100
            found = len(got["speakers"])
            print(f"{uri}: DER {der:.2f}% (limit {limit}), speakers found {found} (want {speakers}, reference {len(ref.labels())}), "
                  f"timing {got['timing_s']}")
            if der > float(limit):
                fails.append(f"{uri}: DER {der:.2f} > {limit}")
            if found != int(speakers):
                fails.append(f"{uri}: found {found} speakers, want {speakers}")
    for f in fails:
        print("FAIL", f, file=sys.stderr)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
