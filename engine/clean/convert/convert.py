"""MossFormer2_SE_48K mask network -> Core ML (mlprogram), the repo's build-time converter.

Port of the Task 0/0b spike at the fixed 20 s shape [1,2496,180] -> [1,2496,961]
(controller decisions 1-2: mixed precision, cpuAndGPU only; the spike's three experiment
patches are dropped, each marked "tried, no effect").

  convert.py --checkpoint PATH --out DIR [--precision fp16|fp32|mixed]

Writes into DIR:
  MossFormer2_SE_48K.mlpackage    the source of truth
  MossFormer2_SE_48K.mlmodelc/    compiled (xcrun coremlcompiler compile)
  reference_window.bin            the known-answer reference (decision 10): one seeded synthetic
                                  feature window + its fp32 PyTorch mask; the engine replays it
                                  after every load, limit mask MSE <= 1e-4
  manifest.json                   I/O, chunking constants, pins, the reference's SHA-256
  config.json                     the I/O contract for the model repo
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reference as R
import patches
import coremltools as ct

IN_NAME, OUT_NAME = "features", "mask"
PATCHES = ("no_rotary_cache", "negative_pad", "einsum_as_matmul")
MODEL_STEM = "MossFormer2_SE_48K"
REF_SEED, REF_DITHER = 1, 1.0          # the known-answer window: seeded synthetic signal, production dither


class Mask(torch.nn.Module):
    def __init__(self, net, gain=1.0):
        super().__init__(); self.net = net; self.gain = gain
    def forward(self, f):
        return self.net(f)[-1] * self.gain          # net(x) returns a list; the LAST element is the mask


def _git_sha():
    try:
        r = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=os.path.dirname(os.path.abspath(__file__)),
                           capture_output=True, text=True, timeout=10)
        return r.stdout.strip() or "unknown"
    except Exception:
        return "unknown"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", required=True, help="last_best_checkpoint.pt or its directory (SHA-256 pinned)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--precision", default="mixed", choices=["fp16", "fp32", "mixed"])
    ap.add_argument("--mask-gain", type=float, default=1.0,
                    help="TEST HOOK for test_convert.py's wrong-model fixture: scales the mask inside the wrapper")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    net, _ = R.load_net(a.checkpoint)
    for n in PATCHES:
        getattr(patches, n)(net)
    m = Mask(net, a.mask_gain).eval()
    frames = R.FRAMES20
    ex = torch.randn(1, frames, R.MELS * 3)
    with torch.no_grad():
        t0 = time.time(); tr = torch.jit.trace(m, ex, check_trace=False); print("trace s", round(time.time() - t0, 1))
        chk = tr(torch.randn(1, frames, R.MELS * 3) * 3)
    print("traced out", tuple(chk.shape))
    assert tuple(chk.shape) == (1, frames, R.BINS), chk.shape
    # 'einsum(\'..., f -> ... f\')' converts silently WRONG in coremltools 9.0: no einsum may survive in the traced graph.
    ops = [n.kind() for n in tr.inlined_graph.nodes()]
    n_ein = sum(1 for k in ops if "einsum" in k)
    print("traced graph nodes", len(ops), "einsum nodes", n_ein)
    assert n_ein == 0, f"{n_ein} einsum node(s) survive in the traced graph"
    kw = {}
    if a.precision == "mixed":
        kw["compute_precision"] = ct.transform.FP16ComputePrecision(op_selector=patches.mixed_selector)
    else:
        kw["compute_precision"] = {"fp16": ct.precision.FLOAT16, "fp32": ct.precision.FLOAT32}[a.precision]
    t0 = time.time()
    mlm = ct.convert(tr, inputs=[ct.TensorType(name=IN_NAME, shape=(1, frames, R.MELS * 3), dtype=np.float32)],
                     outputs=[ct.TensorType(name=OUT_NAME, dtype=np.float32)],
                     convert_to="mlprogram", minimum_deployment_target=ct.target.macOS13, **kw)
    print("convert s", round(time.time() - t0, 1))
    mil_ops = [o.type for f in mlm.get_spec().mlProgram.functions.values() for b in f.block_specializations.values() for o in b.operations]
    print("converted program ops", len(mil_ops), "einsum ops", sum(1 for k in mil_ops if "einsum" in k))
    assert not any("einsum" in k for k in mil_ops)
    pkg = os.path.join(a.out, MODEL_STEM + ".mlpackage")
    mlm.save(pkg)

    # Known-answer reference (decision 10): one seeded synthetic window through the production feature
    # path (dither 1.0), mask from the fp32 PyTorch reference (the ungained net: --mask-gain must not
    # leak into the stored truth).
    sig = R.synthetic_window(REF_SEED)
    feats = R.features(torch.from_numpy(sig * R.SCALE), dither=REF_DITHER, seed=REF_SEED).numpy().astype(np.float32)
    with torch.no_grad():
        ref_mask = net(torch.from_numpy(feats).unsqueeze(0))[-1][0].numpy().astype(np.float32)
    ref_path = os.path.join(a.out, "reference_window.bin")
    R.write_reference(ref_path, feats, ref_mask)
    ref_sha = hashlib.sha256(open(ref_path, "rb").read()).hexdigest()

    print("compiling .mlmodelc")
    subprocess.run(["xcrun", "coremlcompiler", "compile", pkg, a.out], check=True)
    mlc = os.path.join(a.out, MODEL_STEM + ".mlmodelc")
    mlc_bytes = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(mlc) for f in fs)

    manifest = {
        "model": MODEL_STEM,
        "format": "mlprogram",
        "minimum_deployment_target": "macOS13",
        "compute_units": "cpuAndGPU",
        "precision": a.precision,
        "dither": REF_DITHER,
        "scale": int(R.SCALE),
        "window_samples": R.WIN20,
        "stride_samples": R.STRIDE20,
        "xfade_samples": R.XFADE,
        "last_window": "end-aligned",
        "short_clip_fill": "tile",
        "frames": frames,
        "features": R.MELS * 3,
        "bins": R.BINS,
        "input": IN_NAME,
        "output": OUT_NAME,
        "reference_file": "reference_window.bin",
        "reference_sha256": ref_sha,
        "known_answer_limit": "mask MSE <= 1e-4",
        "checkpoint_sha256": R.CKPT_SHA256["last_best_checkpoint.pt"],
        "converter": _git_sha(),
        "coremltools": ct.__version__,
        "torch": torch.__version__,
        "mlmodelc_bytes": mlc_bytes,
    }
    with open(os.path.join(a.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    config = {
        "model": MODEL_STEM,
        "architecture": "mossformer2 mask network, Core ML mlprogram",
        "compute_units": "cpuAndGPU",
        "precision": a.precision,
        "input": {"name": IN_NAME, "shape": [1, frames, R.MELS * 3], "dtype": "float32",
                  "meaning": "Kaldi fbank 60 + delta 60 + delta-delta 60, dither 1.0"},
        "output": {"name": OUT_NAME, "shape": [1, frames, R.BINS], "dtype": "float32",
                   "meaning": "STFT magnitude mask (ReLU, not bounded by 1)"},
        "audio": {"sample_rate": R.SR, "scale": int(R.SCALE), "fft_len": R.FFT, "hop": R.HOP,
                  "win_len": R.WIN, "window": "hamming periodic=False", "center": False},
        "features": {"type": "kaldi_fbank", "num_mel_bins": R.MELS, "deltas": 2,
                     "frame_length_ms": R.WIN / R.SR * 1000, "frame_shift_ms": R.HOP / R.SR * 1000,
                     "dither": REF_DITHER},
        "chunking": {"window_samples": R.WIN20, "stride_samples": R.STRIDE20, "frames": frames,
                     "last_window": "end-aligned", "short_clip_fill": "tile",
                     "splice": "50 ms linear crossfade at the middle of each overlap",
                     "xfade_samples": R.XFADE},
        "known_answer": {"file": "reference_window.bin", "sha256": ref_sha,
                         "check": "features -> mask MSE <= 1e-4 after every model load"},
    }
    with open(os.path.join(a.out, "config.json"), "w") as f:
        json.dump(config, f, indent=1)
    print("saved", a.out, "mlmodelc bytes", mlc_bytes)


if __name__ == "__main__":
    main()
