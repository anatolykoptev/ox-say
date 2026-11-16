#!/usr/bin/env python3
"""End-to-end fixture test of ox-aec: synthetic echo, ERLE, passthrough.

Usage: test_cli.py --bin PATH [--keep DIR] [unittest args]

The fixture is generated in code with a pinned seed; nothing is committed.
The far end is a speech-like signal (noise shaped by a syllable envelope),
the echo is that signal convolved with a short synthetic impulse response at
-10 dB with the path delay under test, the near end is a different signal in
separate stretches plus one double-talk stretch. Two cases: the echo trailing
the render by +60 ms, and the render stamped 80 ms after the echo (a negative
lag, which only the alignment step can survive).

Mutation that must turn this RED: disable the capture shift in
engine/aec/ox-aec.cpp (the `int s =` line) -- the negative-lag case fails
its ERLE assertion.
"""
import argparse
import json
import math
import os
import random
import struct
import subprocess
import sys
import tempfile
import unittest

SR = 16000
BIN = None
KEEP = None

# Stretch layout, seconds: (kind, start, end). far-only stretches are long
# enough for AEC3 to converge; measurement trims the first 1.5 s of each.
FAR_ONLY = [(2.0, 6.0), (12.0, 16.0), (34.0, 38.0)]
NEAR_ONLY = [(8.0, 10.0), (28.0, 32.0)]
DOUBLE_TALK = [(20.0, 24.0)]
DUR = 40.0           # render length
TAIL = 1.5           # extra capture seconds past the render end (passthrough)
ECHO_DB = -10.0      # echo level below the render level


def synth_far(n, seed, syl_hz):
    """Speech-like far end: noise low-pass shaped by a one-pole filter under a
    syllable-rate envelope. Aperiodic, so the cross-correlation peak is sharp."""
    rng = random.Random(seed)
    out, y = [], 0.0
    a = 0.93  # ~1 kHz tilt
    for i in range(n):
        t = i / SR
        env = 0.5 + 0.5 * math.sin(2 * math.pi * syl_hz * t + seed * 0.7)
        env *= env
        y = a * y + (1 - a) * rng.gauss(0, 1)
        out.append(42000.0 * env * y)
    return out


def synth_near(n, seed, base_hz, syl_hz):
    """A different signal for the near talker: detuned partials, same envelope trick."""
    rng = random.Random(seed)
    phase = [rng.uniform(0, 2 * math.pi) for _ in range(6)]
    out = []
    for i in range(n):
        t = i / SR
        env = 0.5 + 0.5 * math.sin(2 * math.pi * syl_hz * t + seed)
        env *= env
        s = 0.0
        for h, p in enumerate(phase, 1):
            s += math.sin(2 * math.pi * base_hz * h * t + p) / h
        out.append(14000.0 * env * s)
    return out


def make_ir(seed=7, n=1280):
    """80 ms exponentially decaying noise; deterministic dominant first tap so
    the path delay stays the well-defined ground truth of the fixture."""
    rng = random.Random(seed)
    ir = [rng.gauss(0, 1) * math.exp(-i / (SR * 0.025)) for i in range(n)]
    ir[0] = 6.0
    e = math.sqrt(sum(v * v for v in ir)) or 1.0
    return [v / e for v in ir]


def convolve(x, h):
    out = [0.0] * (len(x) + len(h) - 1)
    for i, xv in enumerate(x):
        if xv == 0.0:
            continue
        for j, hv in enumerate(h):
            out[i + j] += xv * hv
    return out


def energy(x):
    return sum(v * v for v in x)


def db(a, b):
    return 10.0 * math.log10(a / b) if b > 0 else float("inf")


def clip16(x):
    return [max(-32768, min(32767, int(round(v)))) for v in x]


def write_pcm(path, x):
    with open(path, "wb") as f:
        f.write(struct.pack("<%dh" % len(x), *x))


def read_pcm(path):
    with open(path, "rb") as f:
        data = f.read()
    return list(struct.unpack("<%dh" % (len(data) // 2), data))


def build_case(delay_s):
    """Return (render, capture, regions) for a path delay in samples."""
    n = int(DUR * SR)
    render = [0.0] * n
    near = [0.0] * (n + int(TAIL * SR))
    far_segments = FAR_ONLY + DOUBLE_TALK
    near_segments = NEAR_ONLY + DOUBLE_TALK
    for k, (a, b) in enumerate(far_segments):
        seg = synth_far(int((b - a) * SR), 100 + k, 3.7 + 0.3 * k)
        render[int(a * SR):int(b * SR)] = seg
    for k, (a, b) in enumerate(near_segments):
        seg = synth_near(int((b * SR - a * SR)), 500 + k, 190.0 + 35 * k, 4.6 + 0.4 * k)
        near[int(a * SR):int(b * SR)] = seg
    echo = convolve(render, make_ir())
    # scale the echo to ECHO_DB below the render level inside far-only stretches
    e_ref = energy(sum((render[int(a * SR):int(b * SR)] for a, b in FAR_ONLY), []))
    e_echo = energy(sum((echo[int(a * SR):int(b * SR)] for a, b in FAR_ONLY), []))
    gain = math.sqrt(e_ref / e_echo) * 10 ** (ECHO_DB / 20.0)
    echo = [v * gain for v in echo]
    capture = list(near)
    for i, v in enumerate(echo):
        j = i + delay_s
        if 0 <= j < len(capture):
            capture[j] += v
    return clip16(render), clip16(capture), (FAR_ONLY, NEAR_ONLY)


def run_aec(tmp, name, render, capture, want_rc=0):
    rpath, cpath, opath, jpath = (os.path.join(tmp, name + s) for s in
                                  ("-r.pcm", "-c.pcm", "-o.pcm", ".json"))
    write_pcm(rpath, render)
    write_pcm(cpath, capture)
    p = subprocess.run([BIN, "--capture", cpath, "--render", rpath,
                        "--out", opath, "--report", jpath],
                       capture_output=True, text=True, timeout=300)
    if want_rc == 0 and p.returncode != 0:
        raise AssertionError("ox-aec exited %d: %s" % (p.returncode, p.stderr))
    out = read_pcm(opath) if p.returncode == 0 else None
    report = None
    if p.returncode == 0 and os.path.exists(jpath):
        with open(jpath) as jf:
            report = json.load(jf)
    return p, out, report


def erle(capture, out, a, b, trim_s=1.5):
    lo, hi = int((a + trim_s) * SR), int(b * SR)
    return db(energy(capture[lo:hi]), energy(out[lo:hi]))


class AecCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory(prefix="ox-aec-test-")
        cls.tmp = KEEP or cls._tmp.name
        os.makedirs(cls.tmp, exist_ok=True)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def _check_common(self, report, capture, out, want_lag_ms):
        self.assertEqual(len(out), len(capture), "output must stay on the capture timeline")
        self.assertIsNotNone(report.get("frames"), "report misses frames")
        lags = report.get("lag_ms") or []
        self.assertTrue(lags, "report misses lag_ms")
        self.assertAlmostEqual(lags[0], want_lag_ms, delta=2.0,
                               msg="first window lag should be %+g ms" % want_lag_ms)
        self.assertFalse(report.get("diverged"), "AEC diverged")
        self.assertNotIn("skipped", report, "must not skip voiced render")

    def test_positive_lag(self):
        render, capture, (far, near) = build_case(int(0.060 * SR))
        p, out, report = run_aec(self.tmp, "pos", render, capture)
        self._check_common(report, capture, out, 60.0)
        vals = [erle(capture, out, a, b) for a, b in far]
        for v in vals:
            self.assertGreaterEqual(v, 20.0, "far-end-only ERLE %.1f dB below 20" % v)
        for a, b in near:
            lo, hi = int(a * SR), int(b * SR)
            delta = abs(db(energy(out[lo:hi]), energy(capture[lo:hi])))
            self.assertLessEqual(delta, 1.0, "near-end stretch off by %.2f dB" % delta)
        # the capture tail past the render end passes through unchanged
        edge = len(render) + int(0.1 * SR)
        self.assertEqual(out[edge:], capture[edge:], "capture tail must pass through")
        print("\n  +60 ms case: ERLE per far-only stretch =",
              ", ".join("%.1f" % v for v in vals))

    def test_negative_lag(self):
        render, capture, (far, near) = build_case(int(-0.080 * SR))
        p, out, report = run_aec(self.tmp, "neg", render, capture)
        self._check_common(report, capture, out, -80.0)
        vals = [erle(capture, out, a, b) for a, b in far]
        for v in vals:
            self.assertGreaterEqual(v, 20.0, "far-end-only ERLE %.1f dB below 20" % v)
        print("\n  -80 ms case: ERLE per far-only stretch =",
              ", ".join("%.1f" % v for v in vals))

    def test_silent_render_passthrough(self):
        render, capture, _ = build_case(0)
        render = [0] * len(render)
        p, out, report = run_aec(self.tmp, "sil", render, capture)
        self.assertEqual(out, capture, "silent render must pass the capture through")
        self.assertEqual(report.get("skipped"), "no_render")
        self.assertEqual(report.get("frames"), 0)

    def test_usage(self):
        p = subprocess.run([BIN], capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)

    def test_refuses_out_over_capture(self):
        render, capture, _ = build_case(0)
        cpath = os.path.join(self.tmp, "same.pcm")
        rpath = os.path.join(self.tmp, "same-r.pcm")
        write_pcm(cpath, capture[:1600])
        write_pcm(rpath, render[:1600])
        p = subprocess.run([BIN, "--capture", cpath, "--render", rpath, "--out", cpath],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)
        self.assertEqual(read_pcm(cpath), capture[:1600], "capture file was modified")


def main():
    global BIN, KEEP
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--keep")
    ns, rest = ap.parse_known_args()
    BIN = ns.bin
    KEEP = ns.keep
    sys.argv = [sys.argv[0]] + rest
    unittest.main(verbosity=2)


if __name__ == "__main__":
    main()
