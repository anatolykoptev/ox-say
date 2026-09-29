#!/usr/bin/env python3
"""Oracle test: ox-align ggml emissions vs Hugging Face Wav2Vec2ForCTC.

Runs `ox-align -ng` and HF transformers on the same WAV and compares the
per-frame log-softmax emissions.

The oracle runs in float64 (`model.double()`): HF's own float32 forward pass
deviates ~3e-3 in max log-prob from its float64 result on these models, so a
2e-3 gate is only meaningful against the higher-precision reference.

  f32 GGUF: max |d log-prob| <= 2e-3, frame-argmax agreement >= 99.5%
  f16 GGUF: max |d log-prob| <= 5e-2, frame-argmax agreement >= 99.5%
  (f16 files upcast to f32 at load on the CPU backend — see ox-align.cpp —
  so on CPU f16 results equal f32. On Metal they run native f16 matmuls.)

Mutation hooks (each check names the mutation that must turn it RED):
  F1 grouped positional conv run with groups=1            -> all cases RED
  F2 positional-conv last-frame drop removed              -> all cases RED
  F3 pre-LN model (mms) evaluated as post-LN              -> mms cases RED
  F4 context crop off by one frame                        -> long clip RED
  F5 weight_norm materialized along the wrong dim         -> all cases RED

Test audio: engine/align/testdata/clip-{short,long}.wav — LibriSpeech
test-clean utterances (CC-BY-4.0, https://www.openslr.org/12) fetched via
huggingface.co/datasets/Narsil/asr_dummy (1.flac/2.flac/3.flac); clip-long is
the three utterances concatenated to 70 s to span multiple 30 s windows.

Usage:
  python3 test_oracle.py --ox-align build/align-build/ox-align \
      --models-dir build/models --testdata engine/align/testdata \
      [--ref-dir build/ref] [--quick]

HF checkpoints are needed next to the GGUFs in --models-dir (e.g.
models-dir/wav2vec2-base-960h/config.json). Reference emissions are cached in
--ref-dir so re-runs only pay the ox-align cost.
"""

import argparse
import json
import os
import subprocess
import sys
import time

import numpy as np

MODELS = ["wav2vec2-base-960h", "mms-300m-1130-forced-aligner"]
FTYPES = [("f32", 2e-3), ("f16", 5e-2)]
ARGMAX_MIN = 0.995
CLIPS = ["clip-short.wav", "clip-long.wav"]

SR, WIN, CTX = 16000, 30, 2


def hf_emissions(model_dir: str, wav_path: str) -> np.ndarray:
    """Reference emissions: HF Wav2Vec2ForCTC in float64, reference windowing."""
    import soundfile as sf
    import torch
    from transformers import Wav2Vec2ForCTC

    model = Wav2Vec2ForCTC.from_pretrained(model_dir).double().eval()
    prep = os.path.join(model_dir, "preprocessor_config.json")
    if not os.path.exists(prep):
        prep = os.path.join(model_dir, "feature_extractor_config.json")
    do_norm = json.load(open(prep)).get("do_normalize", True)

    x, sr = sf.read(wav_path, dtype="float64")
    assert sr == SR, f"{wav_path}: expected {SR} Hz, got {sr}"

    ctx, win = CTX * SR, WIN * SR
    xp = np.pad(x, (ctx, ctx + (-len(x) % win)))
    outs = []
    with torch.no_grad():
        for i in range((len(xp) - 2 * ctx) // win):
            seg = xp[i * win: i * win + win + 2 * ctx]
            if do_norm:
                seg = (seg - seg.mean()) / np.sqrt(seg.var() + 1e-7)
            lg = model(torch.from_numpy(seg)[None]).logits[0].numpy()
            outs.append(lg[int(CTX * 50): int(CTX * 50) + WIN * 50])
    e = np.concatenate(outs)[: int(np.ceil(len(x) / 320))]
    m = e.max(-1, keepdims=True)
    return e - m - np.log(np.exp(e - m).sum(-1, keepdims=True))


def ref_for(models_dir: str, testdata: str, ref_dir: str,
            model: str, clip: str) -> np.ndarray:
    path = os.path.join(ref_dir, f"{model}-{clip}-f64.npy")
    if os.path.exists(path):
        return np.load(path)
    print(f"  hf-f64 oracle: {model} x {clip} ...", flush=True)
    t0 = time.time()
    e = hf_emissions(os.path.join(models_dir, model),
                     os.path.join(testdata, clip))
    np.save(path, e)
    print(f"  hf-f64 oracle: {len(e)} frames in {time.time() - t0:.0f}s "
          f"(cached -> {path})", flush=True)
    return e


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ox-align", required=True)
    ap.add_argument("--models-dir", required=True)
    ap.add_argument("--testdata", required=True)
    ap.add_argument("--ref-dir", required=True)
    ap.add_argument("--quick", action="store_true",
                    help="only the short clip on the base model")
    ap.add_argument("--long-only", action="store_true")
    a = ap.parse_args()

    os.makedirs(a.ref_dir, exist_ok=True)

    failures = []
    cases = []
    if not a.long_only:
        for model in ([MODELS[0]] if a.quick else MODELS):
            for ftype, tol in FTYPES:
                cases.append((model, ftype, tol, "clip-short.wav"))
        if not a.quick:
            # multi-window path: ~70 s across three 30 s windows (F4 coverage)
            cases.append((MODELS[0], "f32", 2e-3, "clip-long.wav"))
    else:
        cases.append((MODELS[0], "f32", 2e-3, "clip-long.wav"))

    for model, ftype, tol, clip in cases:
        gguf = os.path.join(a.models_dir, f"{model}-{ftype}.gguf")
        wav = os.path.join(a.testdata, clip)
        if not os.path.exists(gguf):
            print(f"SKIP {model} {ftype}: no {gguf}")
            continue
        out = os.path.join(a.ref_dir, f"out-{model}-{ftype}-{clip}.npy")
        t0 = time.time()
        r = subprocess.run([a.ox_align, "-m", gguf, "-f", wav, "-o", out,
                            "-ng", "-t", "4", "-v"],
                           capture_output=True, text=True)
        dt = time.time() - t0
        if r.returncode != 0:
            print(f"FAIL {model} {ftype} {clip}: ox-align rc={r.returncode}\n"
                  f"{r.stderr[-800:]}")
            failures.append(f"{model}/{ftype}/{clip}")
            continue
        got = np.load(out)
        ref = ref_for(a.models_dir, a.testdata, a.ref_dir, model, clip)
        n = min(len(got), len(ref))
        ok_shape = got.shape == ref.shape
        d = np.abs(got[:n] - ref[:n])
        amax = d.max() if n else float("inf")
        agree = float((got[:n].argmax(-1) == ref[:n].argmax(-1)).mean()) if n else 0.0
        ok = ok_shape and amax <= tol and agree >= ARGMAX_MIN
        print(f"{'PASS' if ok else 'FAIL'} {model}/{ftype}/{clip}: "
              f"shape={got.shape} vs {ref.shape}  max|d|={amax:.5f} "
              f"(<={tol})  argmax={agree:.4f} (>= {ARGMAX_MIN})  {dt:.0f}s",
              flush=True)
        if not ok:
            failures.append(f"{model}/{ftype}/{clip}")

    print()
    if failures:
        print("FAILURES:", *failures)
        return 1
    print("all oracle checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
