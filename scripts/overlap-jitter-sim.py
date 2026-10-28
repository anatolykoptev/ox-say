#!/usr/bin/env python3
"""Model of PcmChannelWriter's overlap rule (#266): how much REAL audio is shaved off by timestamp jitter, per overlap
allowance, over a two-hour recording of a tap (512 frames at 48 kHz -> 16 kHz). Run it: python3 scripts/overlap-jitter-sim.py

Model: the device clock runs `ppm` fast, every chunk's host timestamp carries Gaussian jitter (`sigma` ms), the
converter emits floor(frames/3) cumulative samples. A chunk stamped before the written position is trimmed by the
overlap when the overlap exceeds `allow` samples. `dropped` is audio removed; a +300 ppm clock really does produce
~2.1 s too much audio over two hours, so its drops are drift correction, not loss. Only the -300 / 0 ppm rows measure
jitter damage.

allow 1600 = the old rule (tolerance), 0 = trim every overlap, 320 = the shipped 20 ms allowance."""
import random

TOL = 1600


def run(ppm, sigma_ms, allow, frames=512, hours=2, seed=1):
    random.seed(seed)
    rate_dev = 48000 * (1 + ppm * 1e-6)
    total = written = dropped = out_prev = 0
    t = 0.0
    while t < hours * 3600:
        total += frames
        out = total // 3
        n, out_prev = out - out_prev, out
        t = (total - frames) / rate_dev
        exp = int(max(t + random.gauss(0, sigma_ms) / 1000, 0) * 16000)
        drop = 0
        if exp - written > TOL:
            written = exp
        elif written - exp > allow:
            drop = min(written - exp, n)
            dropped += drop
        written += n - drop
    return dropped / 16


if __name__ == "__main__":
    print("dropped real audio over 2 h, ms   (allowance in samples: 1600 old | 0 trim-all | 320 shipped)")
    print(f"{'ppm':>5} {'sigma ms':>8} {'1600':>9} {'0':>9} {'320':>9}")
    for ppm in (-300, 0, 300):
        for sigma in (0.5, 2.0, 5.0):
            print(f"{ppm:5} {sigma:8} " + " ".join(f"{run(ppm, sigma, a):9.1f}" for a in (1600, 0, 320)))
