#!/usr/bin/env python3
"""Oracle test: ox-align ggml emissions vs Hugging Face Wav2Vec2ForCTC.

Runs `ox-align` and HF transformers on the same WAV and compares the
per-frame log-softmax emissions.

The oracle runs HF twice: in float64 (the reference) and in float32
(`hf32_err = max |HF_f32 - HF_f64|`). The per-case gate is then
`max(base_tol, 2 * hf32_err)` — a gate under float32 noise cannot be met by
any correct implementation on any backend. Base tolerances: 2e-3 for f32
GGUFs, 5e-3 for f16. Argmax agreement stays >= 99.5%.

Reference emissions are cached in --ref-dir. Each cached ref carries a JSON
sidecar with the WAV's sha256, the checkpoint's `source_sha256` (read from
the GGUF via `ox-align --info`), WIN/CTX, the normalize mode and hf32_err.
Every field is compared before a cached ref is used — any mismatch is a
FAIL, never a silent recompute or reuse. torch/transformers are imported
only when a ref must be computed, so `--refs-only` runs on hosts with numpy
but no HF stack (the target Mac).

Mutation hooks (each check names the mutation that must turn it RED):
  F6  missing-GGUF FAIL replaced by `continue`   -> empty --models-dir exits 0
  F11 pos-conv drops the first frame, not last   -> oracle RED, numeric delta
  F12 wrong per-group kernel slice stride        -> oracle RED, numeric delta
  F13 sidecar comparison skipped                 -> --refs-only on a modified
                                                  copy of the clip passes
  F14 --no-normalize made a no-op                -> the raw case is RED

Test audio: engine/align/testdata/clip-{short,long}.wav — LibriSpeech
test-clean utterances 1089-134686-{0000,0001,0002} (CC-BY-4.0,
https://www.openslr.org/12) fetched via huggingface.co/datasets/Narsil/
asr_dummy (1.flac/2.flac/3.flac). See testdata/README.md.

Usage:
  python3 test_oracle.py --ox-align build/engine/align-build/ox-align \
      --models-dir build/models --testdata engine/align/testdata \
      --ref-dir build/ref [--backend cpu|gpu] [--refs-only] [--quick]

HF checkpoints are needed next to the GGUFs in --models-dir (e.g.
models-dir/wav2vec2-base-960h/config.json) unless --refs-only is given.
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

import numpy as np

MODELS = ["wav2vec2-base-960h", "mms-300m-1130-forced-aligner"]
BASE_TOL = {"f32": 2e-3, "f16": 5e-3}
ARGMAX_MIN = 0.995

SR, WIN, CTX = 16000, 30, 2


class RefError(Exception):
    pass


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def gguf_source_sha256(ox_align: str, gguf: str) -> str:
    r = subprocess.run([ox_align, "-m", gguf, "--info"],
                       capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise RefError(f"ox-align --info failed on {gguf}: {r.stderr[-400:]}")
    sha = json.loads(r.stdout).get("source_sha256")
    if not sha:
        raise RefError(f"{gguf} has no ox_align.source_sha256 key "
                       "(rebuild it with convert_wav2vec2.py)")
    return sha


def hf_emissions(model_dir: str, wav_path: str, normalize: bool,
                 dtype: str) -> np.ndarray:
    """HF Wav2Vec2ForCTC emissions with the reference windowing."""
    import soundfile as sf
    import torch
    from transformers import Wav2Vec2ForCTC

    np_dtype = np.float64 if dtype == "float64" else np.float32
    model = Wav2Vec2ForCTC.from_pretrained(model_dir).eval()
    if dtype == "float64":
        model = model.double()
    prep = os.path.join(model_dir, "preprocessor_config.json")
    if not os.path.exists(prep):
        prep = os.path.join(model_dir, "feature_extractor_config.json")
    do_norm = normalize and json.load(open(prep)).get("do_normalize", True)

    x, sr = sf.read(wav_path, dtype="float64")
    assert sr == SR, f"{wav_path}: expected {SR} Hz, got {sr}"

    ctx, win = CTX * SR, WIN * SR
    xp = np.pad(x, (ctx, ctx + (-len(x) % win)))
    outs = []
    with torch.no_grad():
        for i in range((len(xp) - 2 * ctx) // win):
            seg = xp[i * win: i * win + win + 2 * ctx].astype(np_dtype)
            if do_norm:
                seg = (seg - seg.mean()) / np.sqrt(seg.var() + 1e-7)
            lg = model(torch.from_numpy(seg)[None]).logits[0].numpy()
            outs.append(lg[int(CTX * 50): int(CTX * 50) + WIN * 50])
    e = np.concatenate(outs)[: int(np.ceil(len(x) / 320))]
    m = e.max(-1, keepdims=True)
    return e - m - np.log(np.exp(e - m).sum(-1, keepdims=True))


def ref_for(ox_align: str, models_dir: str, testdata: str, ref_dir: str,
            model: str, clip: str, normalize: bool, gguf: str,
            refs_only: bool) -> tuple:
    """(reference emissions, hf32_err). Fail-closed on any staleness."""
    tag = "norm" if normalize else "raw"
    npy = os.path.join(ref_dir, f"{model}-{clip}-{tag}-f64.npy")
    side = npy + ".json"
    wav = os.path.join(testdata, clip)
    want = {
        "wav_sha256": sha256_file(wav),
        "source_sha256": gguf_source_sha256(ox_align, gguf),
        "win": WIN,
        "ctx": CTX,
        "normalize": normalize,
    }
    if os.path.exists(npy):
        if not os.path.exists(side):
            raise RefError(f"{npy} has no provenance sidecar; "
                           "delete it to recompute")
        meta = json.load(open(side))
        bad = [f"{k}: sidecar={meta.get(k)!r} want={v!r}"
               for k, v in want.items() if meta.get(k) != v]
        if "hf32_err" not in meta:
            bad.append("hf32_err missing")
        if bad:
            raise RefError(f"stale reference {npy}: " + "; ".join(bad))
        return np.load(npy), float(meta["hf32_err"])
    if refs_only:
        raise RefError(f"--refs-only and no cached ref at {npy}")
    print(f"  hf-f64+f32 oracle: {model} x {clip} ({tag}) ...", flush=True)
    t0 = time.time()
    model_dir = os.path.join(models_dir, model)
    e64 = hf_emissions(model_dir, wav, normalize, "float64")
    e32 = hf_emissions(model_dir, wav, normalize, "float32")
    n = min(len(e64), len(e32))
    hf32_err = float(np.abs(e32[:n] - e64[:n]).max()) if n else float("inf")
    np.save(npy, e64)
    json.dump({**want, "hf32_err": hf32_err}, open(side, "w"), indent=1)
    print(f"  hf-f64 oracle: {len(e64)} frames in {time.time() - t0:.0f}s "
          f"(hf32_err={hf32_err:.5f}, cached -> {npy})", flush=True)
    return e64, hf32_err


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ox-align", required=True)
    ap.add_argument("--models-dir", required=True)
    ap.add_argument("--testdata", required=True)
    ap.add_argument("--ref-dir", required=True)
    ap.add_argument("--backend", choices=["cpu", "gpu"], default="cpu",
                    help="cpu passes -ng; gpu runs Metal (the Mac)")
    ap.add_argument("--refs-only", action="store_true",
                    help="never compute HF references; stale/missing refs FAIL")
    ap.add_argument("--quick", action="store_true",
                    help="only the short clip on the base model")
    ap.add_argument("--long-only", action="store_true")
    ap.add_argument("--cases",
                    help="substring filter over the case tag, e.g. '/raw'")
    a = ap.parse_args()

    os.makedirs(a.ref_dir, exist_ok=True)

    # (model, ftype, clip, normalize)
    cases = []
    if not a.long_only:
        models = [MODELS[0]] if a.quick else MODELS
        for model in models:
            for ftype in BASE_TOL:
                cases.append((model, ftype, "clip-short.wav", True))
        if not a.quick:
            # multi-window path: ~70 s across three 30 s windows
            cases.append((MODELS[0], "f32", "clip-long.wav", True))
            # raw input, as the production aligner feeds it
            cases.append((MODELS[0], "f32", "clip-short.wav", False))
    else:
        cases.append((MODELS[0], "f32", "clip-long.wav", True))

    failures = []
    executed = 0
    for model, ftype, clip, normalize in cases:
        tag = f"{model}/{ftype}/{clip}" + ("" if normalize else "/raw")
        if a.cases and a.cases not in tag:
            continue
        gguf = os.path.join(a.models_dir, f"{model}-{ftype}.gguf")
        wav = os.path.join(a.testdata, clip)
        if not os.path.exists(gguf):
            print(f"FAIL {tag}: no {gguf}", flush=True)
            failures.append(tag)
            continue
        if not os.path.exists(wav):
            print(f"FAIL {tag}: no {wav}", flush=True)
            failures.append(tag)
            continue
        # validate (or compute) the reference first: a stale ref is a fast
        # FAIL and must not be preceded by a wasted model run
        try:
            ref, hf32_err = ref_for(a.ox_align, a.models_dir, a.testdata,
                                    a.ref_dir, model, clip, normalize, gguf,
                                    a.refs_only)
        except RefError as e:
            print(f"FAIL {tag}: {e}", flush=True)
            failures.append(tag)
            continue
        out = os.path.join(a.ref_dir,
                           f"out-{model}-{ftype}-{clip.replace('.wav', '')}"
                           f"{'-norm' if normalize else '-raw'}.npy")
        cmd = [a.ox_align, "-m", gguf, "-f", wav, "-o", out,
               "-t", "4", "-v"]
        if a.backend == "cpu":
            cmd.append("-ng")
        if not normalize:
            cmd.append("--no-normalize")
        t0 = time.time()
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
        dt = time.time() - t0
        executed += 1
        if r.returncode != 0:
            print(f"FAIL {tag}: ox-align rc={r.returncode}\n"
                  f"{r.stderr[-800:]}", flush=True)
            failures.append(tag)
            continue
        got = np.load(out)
        gate = max(BASE_TOL[ftype], 2 * hf32_err)
        n = min(len(got), len(ref))
        ok_shape = got.shape == ref.shape
        d = np.abs(got[:n] - ref[:n])
        amax = float(d.max()) if n else float("inf")
        agree = float((got[:n].argmax(-1) == ref[:n].argmax(-1)).mean()) \
            if n else 0.0
        ok = ok_shape and amax <= gate and agree >= ARGMAX_MIN
        print(f"{'PASS' if ok else 'FAIL'} {tag}: shape={got.shape} vs "
              f"{ref.shape}  max|d|={amax:.5f} (gate={gate:.5f})  "
              f"argmax={agree:.4f} (>= {ARGMAX_MIN})  {dt:.0f}s", flush=True)
        if not ok:
            failures.append(tag)

    print()
    print(f"executed {executed} case(s)")
    if failures:
        print("FAILURES:", *failures)
        return 1
    if executed == 0:
        print("FAIL: zero cases executed")
        return 1
    print("all oracle checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
