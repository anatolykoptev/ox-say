"""Fixture for Tests/OxCleanCoreTests/ChunkerTests.swift (build-time only; Global Constraint 2).

Run from the repo root:
  ~/Developer/ashaki-video/tools/enhance/bin/python -B engine/clean/testdata/ref_chunker.py

Oracle: the spike's own chunking, `reference.plan20` / `reference.fill20` / `reference.windowed20`
(~/Developer/utilities/mossformer2-coreml-spike/reference.py), which the 20 s window study measured. It shares no code with
Chunker.swift. The "enhancer" is deterministic and not the identity: window k returns its input x (k + 1), so every seam is
a visible ramp between two different levels.

The input is x[i] = float32((i * 7919) % 10007) / float32(10007) - 0.5, which Swift regenerates exactly.
For each length the fixture keeps the window starts, the crossfade centres, and sampled output values: all of them for a
tiny clip, otherwise a coarse grid plus a dense probe around every seam. (Whole signals would be tens of MB.)

Also cross-checks the spike's plan20 against an independent transcription of the controller's decision-2 text
over a sweep of lengths and aborts on any disagreement.
"""
import json
import os
import pathlib
import random
import sys

import numpy as np

SPIKE = os.path.expanduser("~/Developer/utilities/mossformer2-coreml-spike")
sys.path.insert(0, SPIKE)
import reference as R  # noqa: E402

W, S, X = R.WIN20, R.STRIDE20, R.XFADE
assert (W, S, X) == (960_000, 720_000, 2_400)
here = pathlib.Path(__file__).resolve().parent


def decision2_starts(n):
    """Decision 2, rule 1/2, transcribed literally (not the spike's formula)."""
    if n <= W:
        return [0]
    out, s = [], 0
    while s + W < n:
        out.append(s)
        s += S
    if out[-1] != n - W:
        out.append(n - W)
    return out


def mids(starts):
    return [(starts[i] + starts[i + 1] + W) // 2 for i in range(len(starts) - 1)]


rng = random.Random(7)
sweep = list(range(1, 50)) + [W - 1, W, W + 1, W + S - 1, W + S, W + S + 1, 2 * W, 3 * W + 17] \
    + [rng.randrange(1, 40 * W) for _ in range(20000)]
for n in sweep:
    assert R.plan20(n) == decision2_starts(n), f"plan20 and decision 2 disagree at n={n}: {R.plan20(n)} vs {decision2_starts(n)}"
    assert len(set(R.plan20(n))) == len(R.plan20(n))


def signal(n):
    i = np.arange(n, dtype=np.int64)
    return ((i * 7919) % 10007).astype(np.float32) / np.float32(10007) - np.float32(0.5)


lengths = [1, 2399, W - 1, W, W + 1, W + S - 1, W + S, W + S + 1, 2 * W, W + 2 * S, 3 * W + 17, 28_800_000]
cases = []
for n in lengths:
    x = signal(n)
    starts = R.plan20(n)

    def enhancer(scaled, s):
        return scaled.numpy() * np.float32(starts.index(s) + 1)

    y = R.windowed20(x, enhancer)
    assert len(y) == n and np.isfinite(y).all()
    idx = set(range(n)) if n <= 4000 else set(range(0, n, max(1, n // 300))) | {0, 1, n - 2, n - 1}
    for m in mids(starts):
        idx |= {m + o for o in range(-X // 2 - 6, X // 2 + 6, 37)} | {m + o for o in (-X // 2 - 1, -X // 2, -X // 2 + 1, -1, 0, 1, X // 2 - 1, X // 2, X // 2 + 1)}
    for s in starts:
        idx |= {s, s + 1, s + W - 1}
    idx = sorted(i for i in idx if 0 <= i < n)
    cases.append({"n": n, "starts": starts, "mids": mids(starts), "samples": [[i, float(y[i])] for i in idx]})
    print(n, len(starts), "windows", len(idx), "samples")

(here / "chunker_ref.json").write_text(json.dumps({"window": W, "stride": S, "crossfade": X, "cases": cases}, separators=(",", ":")))
print("ok, plan20 == decision 2 on", len(sweep), "lengths")
