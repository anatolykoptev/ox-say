"""Fixtures for Tests/OxCleanCoreTests/FbankTests.swift. Build-time only (Global Constraint 2: no Python at runtime).

Run from the repo root:
  ~/Developer/ashaki-video/tools/enhance/bin/python -B engine/clean/testdata/gen_fixtures.py

Oracle: torchaudio.compliance.kaldi.fbank + torchaudio.functional.compute_deltas, dither 0.
Also writes noise_golden.f32: the first values of the dither generator, from a pure-Python SplitMix64 + Box-Muller
that shares no code with Fbank.swift.
Task 5 adds stft_clip.f32 / stft_ref.f32: torch.stft of the first 20736 samples (50 frames) of the 1 s clip x 32768, the
pair kept under 0.5 MB. Task 4's fixtures are written first and are untouched by the Task 5 block.
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
# Task 5: STFT oracle. Window 1920 non-periodic Hamming, hop 384, center=False, one-sided, real/imag pairs.
STFT_FRAMES = 50
stft_n = 1920 + 384 * (STFT_FRAMES - 1)  # 20736: includes the tone onset at sample 19200
stft_clip = x[:stft_n]
spec = torch.stft(torch.from_numpy(stft_clip * 32768.0), n_fft=1920, hop_length=384, win_length=1920,
                  window=torch.hamming_window(1920, periodic=False), center=False, onesided=True, return_complex=False)
assert spec.shape == (961, STFT_FRAMES, 2), spec.shape
stft_clip.tofile(here / "stft_clip.f32")
spec.permute(1, 0, 2).contiguous().numpy().astype(np.float32).tofile(here / "stft_ref.f32")  # [50, 961, 2]
print(f"torch {torch.__version__} torchaudio {torchaudio.__version__}")
