"""verify.py MODEL_DIR [--checkpoint PATH] [--fixtures N]

The gate for the converted model -- the same known-answer check the engine re-runs after
every model load (limit mask MSE <= 1e-4), plus conversion parity on seeded fixture windows.
Needs both artifacts in MODEL_DIR: the compiled .mlmodelc (the one the app and Hugging Face
users load, so the one every gated prediction runs on) and the .mlpackage (it must agree).

  * integrity:  reference_window.bin sha256 must equal manifest.reference_sha256 (exit 2);
  * weights:    weights/weight.bin inside the .mlmodelc and inside the .mlpackage must hash to
    manifest.mlmodelc_weights_sha256 / mlpackage_weights_sha256 (a mismatch is a gated FAIL);
  * known-answer: the mask on the stored features vs the stored mask, on cpuAndGPU (the only
    supported unit set: on cpuOnly the Core ML CPU fp16 runtime renders the first ~64 frames of
    each window as garbage on macOS 26.5.1 -- that result is reported and never gated), gated
    separately on the .mlmodelc and on the .mlpackage; the two masks must also agree under the
    same rule;
  * stored vs PyTorch (--checkpoint given): the stored mask must match a fresh fp32 PyTorch mask
    on the same features;
  * fixtures (--checkpoint given, --fixtures N, default 2): seeded synthetic windows -> fp32
    PyTorch mask vs the .mlmodelc mask on cpuAndGPU, graded by the manifest's precision thresholds.

Verdicts: the known-answer check PASSes only under known_answer_ok() (mask MSE <= 1e-4, p99.9
<= 0.05, no NaN); a fixture PASSes only on grade PASS -- WARN prints WARN and is a failure.
Exit 0 PASS, 1 a gated check failed (FAIL or WARN), 2 usage or integrity error.
"""
import argparse
import hashlib
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import metrics as M
import reference as R

KNOWN_ANSWER_MSE = 1e-4
KNOWN_ANSWER_P999 = 0.05
MODEL_STEM = "MossFormer2_SE_48K"


def known_answer_ok(stats):
    """The model-load known-answer gate; the engine must apply exactly this rule.

    `stats` is metrics.mask_stats(model_mask, stored_mask). Returns True only when ALL hold:
      * mask MSE <= 1e-4          (KNOWN_ANSWER_MSE)
      * mask p99.9 |error| <= 0.05 (KNOWN_ANSWER_P999)
      * every statistic is finite (a NaN anywhere in the mask makes them NaN -> False).
    Anything else is a refusal. There is no WARN band.
    """
    mse, p999, mx = stats["mse"], stats["p999"], stats["max_abs"]
    return bool(np.isfinite(mse) and np.isfinite(p999) and np.isfinite(mx)
                and mse <= KNOWN_ANSWER_MSE and p999 <= KNOWN_ANSWER_P999)


def predict_fn(model_dir, units, artifact="mlmodelc"):
    """A features -> mask callable on one shipped artifact: "mlmodelc" (the compiled model, loaded
    through CompiledMLModel exactly as the app loads it) or "mlpackage"."""
    import coremltools as ct
    path = os.path.join(model_dir, MODEL_STEM + "." + artifact)
    assert os.path.isdir(path), f"{path} missing: verify.py gates both the .mlmodelc and the .mlpackage"
    if artifact == "mlmodelc":
        # CompiledMLModel has no get_spec(): the I/O contract is read from the compiled metadata.
        meta = json.load(open(os.path.join(path, "metadata.json")))[0]
        inn, outn = meta["inputSchema"][0]["name"], meta["outputSchema"][0]["name"]
        assert json.loads(meta["inputSchema"][0]["shape"]) == [1, R.FRAMES20, R.MELS * 3], meta["inputSchema"][0]
        m = ct.models.CompiledMLModel(path, compute_units=units)
    else:
        m = ct.models.MLModel(path, compute_units=units)
        spec = m.get_spec()
        inn = spec.description.input[0].name
        outn = spec.description.output[0].name
        assert tuple(spec.description.input[0].type.multiArrayType.shape) == (1, R.FRAMES20, R.MELS * 3), spec.description.input[0]

    def fn(feats):
        return np.asarray(m.predict({inn: np.asarray(feats, np.float32)[None]})[outn])[0].astype(np.float32)
    return fn


def predict_once(model_dir, units, artifact, feats):
    """(mask or None, error text or None): a load or predict failure is a FAIL line, not a traceback."""
    try:
        return predict_fn(model_dir, units, artifact)(feats), None
    except Exception as e:
        return None, f"{type(e).__name__}: {' '.join(str(e).split())[:160]}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model_dir")
    ap.add_argument("--checkpoint", help="last_best_checkpoint.pt or its directory; enables the PyTorch comparisons")
    ap.add_argument("--fixtures", type=int, default=2,
                    help="seeded synthetic fixture windows vs PyTorch; 0 skips. A fixture passes only "
                         "on grade PASS: WARN prints WARN and makes the exit code 1")
    a = ap.parse_args()
    import coremltools as ct

    man = json.loads(open(os.path.join(a.model_dir, "manifest.json")).read())
    ref_path = os.path.join(a.model_dir, man.get("reference_file", "reference_window.bin"))
    sha = hashlib.sha256(open(ref_path, "rb").read()).hexdigest()
    if sha != man.get("reference_sha256"):
        print(f"FAIL reference file sha256 {sha} != manifest {man.get('reference_sha256')}")
        sys.exit(2)
    feats, stored = R.read_reference(ref_path)
    fails = []
    precision_gate = "fp32" if man.get("precision") == "fp32" else "fp16"

    for art in ("mlmodelc", "mlpackage"):
        key = art + "_weights_sha256"
        if not man.get(key):
            print(f"FAIL manifest lacks {key}: rebuild with convert.py")
            sys.exit(2)
        blob = os.path.join(a.model_dir, R.WEIGHT_BLOBS[art])
        got_sha = R.sha256_file(blob) if os.path.isfile(blob) else "missing"
        ok = got_sha == man[key]
        print(f"{art} weights/weight.bin sha256 {got_sha[:16]} vs manifest {man[key][:16]} -> {'PASS' if ok else 'FAIL'}")
        if not ok:
            fails.append(f"{art} weight.bin sha256 {got_sha} != manifest {man[key]}")

    gpu = ct.ComputeUnit.CPU_AND_GPU
    masks = {}
    for art, label in (("mlmodelc", "compiled .mlmodelc"), ("mlpackage", "package .mlpackage")):
        got, err = predict_once(a.model_dir, gpu, art, feats)
        if err:
            print(f"{label} cpuAndGPU known-answer: could not run ({err}) -> FAIL")
            fails.append(f"{art} known-answer could not run")
            continue
        masks[art] = got
        st = M.mask_stats(got, stored)
        verdict = "PASS" if known_answer_ok(st) and not np.isnan(got).any() else "FAIL"
        if not np.abs(got).any():
            print(f"the {art} returned an all-zero mask (the pure-fp16 signature)")
        print(f"{label} cpuAndGPU known-answer: mse {st['mse']:.3e} max {st['max_abs']:.3e} p99.9 {st['p999']:.3e} -> {verdict}")
        if verdict == "FAIL":
            fails.append(f"{art} cpuAndGPU known-answer mse {st['mse']:.3e}")
    if len(masks) == 2:
        st = M.mask_stats(masks["mlmodelc"], masks["mlpackage"])
        ok = known_answer_ok(st)
        print(f".mlmodelc vs .mlpackage: mse {st['mse']:.3e} max {st['max_abs']:.3e} p99.9 {st['p999']:.3e} -> {'PASS' if ok else 'FAIL'}")
        if not ok:
            fails.append(f".mlmodelc and .mlpackage disagree, mse {st['mse']:.3e}")

    cpu, err = predict_once(a.model_dir, ct.ComputeUnit.CPU_ONLY, "mlmodelc", feats)
    if err:
        print(f"cpuOnly: known defect, not supported -- could not run ({err}) (reported, never gated)")
    else:
        st = M.mask_stats(cpu, stored)
        print(f"cpuOnly: known defect, not supported -- mse {st['mse']:.3e} (reported, never gated)")

    fn = predict_fn(a.model_dir, gpu, "mlmodelc") if a.checkpoint and a.fixtures and "mlmodelc" in masks else None
    if a.checkpoint:
        import torch
        net, _ = R.load_net(a.checkpoint)
        torch_fn = R.torch_mask_fn(net)
        st = M.mask_stats(torch_fn(torch.from_numpy(np.asarray(feats, np.float32))), stored)
        ok = st["mse"] <= 1e-7
        print(f"stored reference vs fp32 PyTorch: mse {st['mse']:.3e} -> {'PASS' if ok else 'FAIL'}")
        if not ok:
            fails.append(f"stored reference mask diverges from the fp32 PyTorch reference, mse {st['mse']:.3e}")
        for i in range(a.fixtures):
            seed, dither = 101 + i, (1.0 if i % 2 == 0 else 0.0)
            fi = R.features(torch.from_numpy(R.synthetic_window(seed) * R.SCALE),
                            dither=dither, seed=seed)
            if fn is None:
                fails.append(f"fixture {i} skipped: the .mlmodelc did not run")
                continue
            st = M.mask_stats(fn(fi.numpy()), torch_fn(fi))
            g = M.grade_mask(st, precision_gate)      # PASS only; WARN is a failure too
            print(f"fixture {i} (seed {seed}, dither {dither}): mse {st['mse']:.3e} max {st['max_abs']:.3e} "
                  f"p99.9 {st['p999']:.3e} -> {g}")
            if g != "PASS":
                fails.append(f"fixture {i} (seed {seed}) {g} mse {st['mse']:.3e}")
    if fails:
        print("FAIL:", "; ".join(fails))
        sys.exit(1)
    print("PASS")


if __name__ == "__main__":
    main()
