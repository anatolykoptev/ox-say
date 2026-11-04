"""Fixtures for Tests/OxCleanCoreTests/FbankTests.swift. Build-time only (Global Constraint 2: no Python at runtime).

Run from the repo root:
  ~/Developer/ashaki-video/tools/enhance/bin/python -B engine/clean/testdata/gen_fixtures.py

Oracle: torchaudio.compliance.kaldi.fbank + torchaudio.functional.compute_deltas, dither 0.
Also writes noise_golden.f32: the first values of the dither generator, from a pure-Python SplitMix64 + Box-Muller
that shares no code with Fbank.swift.
"""
import math
import pathlib

import numpy as np
import torch
import torchaudio

here = pathlib.Path(__file__).resolve().parent
rng = np.random.default_rng(20261103)
t = np.arange(48000) / 48000.0
x = 0.3 * np.sin(2 * np.pi * (180 * t + 60 * t * t)) + 0.1 * np.sin(2 * np.pi * 1900 * t) * (t > 0.4) + 0.02 * rng.standard_normal(48000)
x = np.clip(x, -1, 1).astype(np.float32)
a = torch.from_numpy(x * 32768.0)
fb = torchaudio.compliance.kaldi.fbank(a.unsqueeze(0), dither=0.0, frame_length=40.0, frame_shift=8.0, num_mel_bins=60,
                                       sample_frequency=48000, window_type="hamming")
d1 = torchaudio.functional.compute_deltas(fb.T).T
d2 = torchaudio.functional.compute_deltas(d1.T).T
feat = torch.cat([fb, d1, d2], 1)  # [121, 180]
x.tofile(here / "clip1s.f32")
feat.numpy().astype(np.float32).tofile(here / "feat1s.f32")

M64 = (1 << 64) - 1


def splitmix(state):
    while True:
        state = (state + 0x9E3779B97F4A7C15) & M64
        z = state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
        yield z ^ (z >> 31)


def gauss(seed, n):
    g, out = splitmix(seed), []
    while len(out) < n:
        u1 = ((next(g) >> 11) + 0.5) * 2.0 ** -53
        u2 = ((next(g) >> 11) + 0.5) * 2.0 ** -53
        r = math.sqrt(-2.0 * math.log(u1))
        out += [r * math.cos(2 * math.pi * u2), r * math.sin(2 * math.pi * u2)]
    return out[:n]


np.array(gauss(1, 64) + gauss(20261103, 64), dtype=np.float32).tofile(here / "noise_golden.f32")
print(f"torch {torch.__version__} torchaudio {torchaudio.__version__}")
