"""End-to-end golden for Tests/OxCleanCoreTests/ModelGoldenTests.swift (build-time only; Global Constraint 2).

Run from the repo root, in the converter's venv, under the shared lock:
  CKPT=~/Developer/ashaki-video/tools/models/clearvoice/checkpoints/MossFormer2_SE_48K/last_best_checkpoint.pt
  /usr/bin/lockf -k -t 3600 ~/tmp/.ox-say-suite.lock nice -n 15 \
    engine/clean/convert/.venv/bin/python -B engine/clean/testdata/gen_fixtures.py --golden-e2e "$CKPT"

Writes golden21_meta.json and golden21_ref.i16 next to this file.

Input: a 21 s synthetic voiced clip (no recording). The Swift test regenerates it from the same formulas (`GoldenClip` in
ModelGoldenTests.swift) and spot-checks the values listed in `input_probes`; the clip itself is not stored. 21 s is
20 s + 1 s: two windows (0 and 1 s, end-aligned) and one seam.
Oracle: the fp32 PyTorch network (convert/reference.py `load_net`, the pinned checkpoint) driven by the spike's chunker
(~/Developer/utilities/mossformer2-coreml-spike/reference.py `windowed20_net`: plan20, 50 ms crossfade, torch.stft and
torch.istft), at dither 0. It shares no code with Swift. The output is stored as int16 / ref_scale.
"""
import importlib.util
import json
import math
import os
import pathlib
import sys

import numpy as np
import torch

here = pathlib.Path(__file__).resolve().parent
CONVERT = here.parent / "convert"
SPIKE = pathlib.Path(os.path.expanduser("~/Developer/utilities/mossformer2-coreml-spike/reference.py"))
N = 21 * 48000
NOISE_SEED = 20261104
M64 = (1 << 64) - 1


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def splitmix(state):
    while True:
        state = (state + 0x9E3779B97F4A7C15) & M64
        z = state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
        yield z ^ (z >> 31)


def gauss(seed, n):
    """Same stream as GaussianNoise.next() in Fbank.swift: per pair u1, u2 from consecutive words, r cos then r sin."""
    g, out = splitmix(seed), []
    while len(out) < n:
        u1 = ((next(g) >> 11) + 0.5) * 2.0 ** -53
        u2 = ((next(g) >> 11) + 0.5) * 2.0 ** -53
        r = math.sqrt(-2.0 * math.log(u1))
        out += [r * math.cos(2 * math.pi * u2), r * math.sin(2 * math.pi * u2)]
    return np.array(out[:n])


def golden_clip(n):
    """Mirrors GoldenClip.samples in ModelGoldenTests.swift, formula for formula."""
    two_pi = 2 * math.pi
    t = np.arange(n, dtype=np.float64) / 48000
    f0 = 110 + 60 * (0.5 - 0.5 * np.cos(two_pi * t / 3.7))
    phase = two_pi * (140 * t - (30 * 3.7 / two_pi) * np.sin(two_pi * t / 3.7))
    v = np.zeros(n)
    for h in range(1, 25):
        f = h * f0
        a = (0.6 * np.exp(-(((f - 700) / 250) ** 2)) + 0.4 * np.exp(-(((f - 1500) / 400) ** 2))
             + 0.2 * np.exp(-(((f - 2600) / 500) ** 2)) + 0.05)
        v += np.where(f < 8000, a / h * np.sin(h * phase), 0.0)
    syll = (0.5 + 0.5 * np.sin(two_pi * 3.1 * t - math.pi / 2)) ** 1.5
    gate = np.where(np.mod(t / 6.1, 1.0) < 0.85, 1.0, 0.0)
    x = (0.12 * v * syll * gate).astype(np.float32) + (0.003 * gauss(NOISE_SEED, n)).astype(np.float32)
    return x.astype(np.float32)


def main(ckpt):
    spike = _load("spike_reference", SPIKE)
    sys.path.insert(0, str(CONVERT))
    import reference as R  # the converter's reference.py (load_net with the pinned-checkpoint SHA check)
    net, _ = R.load_net(ckpt)
    x = golden_clip(N)
    y = spike.windowed20_net(x, spike.torch_mask_fn(net), dither=0.0)
    assert len(y) == N and np.isfinite(y).all()
    peak = float(np.abs(y).max())
    scale = 32767.0 / peak
    scale = float(math.floor(scale))  # an exact integer, so the Swift side divides by the same number
    (here / "golden21_ref.i16").write_bytes(np.round(y.astype(np.float64) * scale).astype("<i2").tobytes())
    probes = [{"at": a, "values": [float(v) for v in x[a:a + 8]]} for a in (0, 123_457, 500_003, 1_000_000, N - 8)]
    meta = {"samples": N, "ref_scale": scale, "ref_peak": peak, "ref_rms": float(np.sqrt(np.mean(y.astype(np.float64) ** 2))),
            "input_rms": float(np.sqrt(np.mean(x.astype(np.float64) ** 2))), "input_probes": probes,
            "torch": torch.__version__, "oracle": "convert/reference.py load_net + spike windowed20_net, dither 0"}
    (here / "golden21_meta.json").write_text(json.dumps(meta, indent=1) + "\n")
    print("wrote golden21_ref.i16", len(y), "samples; ref rms", meta["ref_rms"], "input rms", meta["input_rms"])


if __name__ == "__main__":
    main(sys.argv[sys.argv.index("--golden-e2e") + 1])
