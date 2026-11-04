"""Tests for the MossFormer2_SE_48K Core ML converter (local only, never CI -- torch and a
221 MB checkpoint do not belong on a runner).

  OX_CLEAN_CHECKPOINT=<path to last_best_checkpoint.pt or its dir> \
      .venv/bin/python -B -m pytest engine/clean/convert/test_convert.py

The suite loads torch and Core ML models and a conversion is a multi-GB job, so run one heavy
job at a time and at low priority:
  nice -n 15 env OX_CLEAN_CHECKPOINT=... .venv/bin/python -B -m pytest test_convert.py

OX_CLEAN_MODEL_DIR=<a dir convert.py already wrote> skips the fixture conversion and tests that
directory read-only (also for re-checking a downloaded model dir). verify.py needs both the
.mlmodelc (the artifact that ships; every gated prediction runs on it) and the .mlpackage (it must
agree), and the manifest's weights SHA-256 for each.
"""
import hashlib
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys

import numpy as np

import pytest

HERE = pathlib.Path(__file__).parent
CKPT = os.environ.get("OX_CLEAN_CHECKPOINT")
pytestmark = pytest.mark.skipif(not CKPT, reason="OX_CLEAN_CHECKPOINT unset")
sys.path.insert(0, str(HERE))

MODEL_STEM = "MossFormer2_SE_48K"


def run(*a, ok=True):
    r = subprocess.run([sys.executable, "-B", str(HERE / a[0]), *a[1:]], capture_output=True, text=True)
    if ok and r.returncode != 0:
        raise AssertionError(f"{a} rc={r.returncode}\n{r.stdout}\n{r.stderr}")
    return r


@pytest.fixture(scope="session")
def model_dir(tmp_path_factory):
    """One shared converted model for the read-only tests; OX_CLEAN_MODEL_DIR tests a prebuilt dir."""
    if os.environ.get("OX_CLEAN_MODEL_DIR"):
        return pathlib.Path(os.environ["OX_CLEAN_MODEL_DIR"])
    d = tmp_path_factory.mktemp("model")
    run("convert.py", "--checkpoint", CKPT, "--out", str(d))
    return d


def test_checkpoint_is_the_pinned_one():
    p = pathlib.Path(CKPT)
    pt = p if p.is_file() else p / "last_best_checkpoint.pt"
    h = hashlib.sha256(pt.read_bytes()).hexdigest()
    assert h == "03692b9f773bbd6bb43b9c5a41f96b1e28affd66e13796b7bec66ad3d8b227c6"


def test_converted_model_matches_pytorch_and_fits_the_budget(model_dir):
    m = json.loads((model_dir / "manifest.json").read_text())
    assert (m["window_samples"], m["frames"], m["features"], m["bins"]) == (960000, 2496, 180, 961)
    assert (m["compute_units"], m["precision"], m["dither"]) == ("cpuAndGPU", "mixed", 1.0)
    size = sum(p.stat().st_size for p in (model_dir / (MODEL_STEM + ".mlmodelc")).rglob("*") if p.is_file())
    assert size <= 125 * 1024 * 1024, size                 # 125 MiB budget (model-size budget)
    out = run("verify.py", str(model_dir), "--checkpoint", CKPT)   # exits 1 above the thresholds
    assert "mse" in out.stdout and "cpuOnly: known defect" in out.stdout


def test_conversion_is_reproducible(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    run("convert.py", "--checkpoint", CKPT, "--out", str(a))
    run("convert.py", "--checkpoint", CKPT, "--out", str(b))
    wa = next((a / (MODEL_STEM + ".mlmodelc")).rglob("weight.bin"))
    wb = next((b / (MODEL_STEM + ".mlmodelc")).rglob("weight.bin"))
    assert hashlib.sha256(wa.read_bytes()).digest() == hashlib.sha256(wb.read_bytes()).digest()


def test_verify_fails_on_a_wrong_model(tmp_path):
    d = tmp_path / "wrong"
    run("convert.py", "--checkpoint", CKPT, "--out", str(d), "--mask-gain", "2.0")
    out = run("verify.py", str(d), "--checkpoint", CKPT, ok=False)   # a doubled mask must exit 1
    assert out.returncode == 1, out.stdout + out.stderr
    assert "FAIL" in out.stdout


def test_reference_file_sha_matches_manifest(model_dir):
    m = json.loads((model_dir / "manifest.json").read_text())
    ref = model_dir / m["reference_file"]
    assert hashlib.sha256(ref.read_bytes()).hexdigest() == m["reference_sha256"]


def _perturbed_model_dir(src, dst, perturb):
    """A model dir whose stored reference mask is replaced by perturb(mask) (manifest sha
    updated). Both artifacts are symlinked, so the model itself is unchanged: verify's known-answer
    error is then exactly the perturbation, with no conversion."""
    import reference as R
    dst.mkdir()
    for ext in (".mlpackage", ".mlmodelc"):
        os.symlink(src / (MODEL_STEM + ext), dst / (MODEL_STEM + ext))
    m = json.loads((src / "manifest.json").read_text())
    feats, mask = R.read_reference(str(src / m["reference_file"]))
    R.write_reference(str(dst / m["reference_file"]), feats, perturb(mask).astype(np.float32))
    m["reference_sha256"] = hashlib.sha256((dst / m["reference_file"]).read_bytes()).hexdigest()
    (dst / "manifest.json").write_text(json.dumps(m))
    return dst


def _ka_line(stdout):
    return next(l for l in stdout.splitlines() if "known-answer" in l)


def _line(stdout, needle):
    return next(l for l in stdout.splitlines() if needle in l)


def _corrupt_compiled_dir(src, dst, how):
    """A model dir whose .mlmodelc is a REAL copy with weights/weight.bin damaged, next to a
    .mlpackage that is a symlink to the good one. how: "zeroed" (same size, all zero) or "onebyte"."""
    dst.mkdir()
    os.symlink(src / (MODEL_STEM + ".mlpackage"), dst / (MODEL_STEM + ".mlpackage"))
    shutil.copytree(src / (MODEL_STEM + ".mlmodelc"), dst / (MODEL_STEM + ".mlmodelc"))
    shutil.copy(src / "manifest.json", dst / "manifest.json")
    shutil.copy(src / "reference_window.bin", dst / "reference_window.bin")
    blob = dst / (MODEL_STEM + ".mlmodelc") / "weights" / "weight.bin"
    data = bytearray(blob.read_bytes())
    if how == "zeroed":
        data = bytearray(len(data))
    else:
        data[len(data) // 2] ^= 0xFF
    blob.write_bytes(bytes(data))
    return dst


def test_verify_gates_the_compiled_model_not_the_package(model_dir, tmp_path):
    # A stale/wrong .mlmodelc next to a correct .mlpackage must fail on the compiled-model line.
    d = _corrupt_compiled_dir(model_dir, tmp_path / "stale", "zeroed")
    out = run("verify.py", str(d), "--fixtures", "0", ok=False)
    assert out.returncode == 1, out.stdout + out.stderr
    assert _line(out.stdout, "compiled .mlmodelc cpuAndGPU known-answer").rstrip().endswith("FAIL"), out.stdout
    assert _line(out.stdout, "package .mlpackage cpuAndGPU known-answer").rstrip().endswith("PASS"), out.stdout
    assert _line(out.stdout, "mlmodelc weights/weight.bin").rstrip().endswith("FAIL"), out.stdout


def test_verify_checks_the_weights_sha_even_when_predictions_pass(model_dir, tmp_path):
    # One flipped byte in the middle of the blob may not move the masks at all; the manifest SHA-256 is the
    # gate that still catches it.
    d = _corrupt_compiled_dir(model_dir, tmp_path / "onebyte", "onebyte")
    out = run("verify.py", str(d), "--fixtures", "0", ok=False)
    assert out.returncode == 1, out.stdout + out.stderr
    assert _line(out.stdout, "mlmodelc weights/weight.bin").rstrip().endswith("FAIL"), out.stdout
    assert _line(out.stdout, "mlpackage weights/weight.bin").rstrip().endswith("PASS"), out.stdout


def test_verify_prints_both_artifact_lines_on_the_good_model(model_dir):
    out = run("verify.py", str(model_dir), "--fixtures", "0")
    assert _line(out.stdout, "compiled .mlmodelc cpuAndGPU known-answer").rstrip().endswith("PASS"), out.stdout
    assert _line(out.stdout, "package .mlpackage cpuAndGPU known-answer").rstrip().endswith("PASS"), out.stdout
    assert _line(out.stdout, ".mlmodelc vs .mlpackage").rstrip().endswith("PASS"), out.stdout


def _load_net_in_subprocess(cwd, tmp_root, arg):
    """load_net(arg) in a fresh interpreter whose cwd is `cwd` (offline: an unpinned download would fail)."""
    code = ("import sys; sys.path.insert(0, %r); import reference as R; net, cv = R.load_net(sys.argv[1]); "
            "print('LOADED', type(net).__name__)" % str(HERE))
    env = {**os.environ, "HF_HUB_OFFLINE": "1", "TMPDIR": str(tmp_root)}
    return subprocess.run([sys.executable, "-B", "-c", code, arg], cwd=cwd, env=env, capture_output=True, text=True)


def _nonstandard_ckpt_dir(dst):
    """A directory outside the checkpoints/MossFormer2_SE_48K layout holding the two pinned files."""
    p = pathlib.Path(CKPT)
    src = p.parent if p.is_file() else p
    dst.mkdir()
    for name in ("last_best_checkpoint.pt", "last_best_checkpoint"):
        os.symlink(src / name, dst / name)
    return dst


def test_load_net_accepts_a_relative_checkpoint_dir_and_cleans_its_staging(tmp_path):
    # A relative dir must be made absolute before it is symlinked under the staging root, and the
    # staging root must not outlive the call.
    work, tmp_root = tmp_path / "cwd", tmp_path / "tmp"
    work.mkdir()
    tmp_root.mkdir()
    _nonstandard_ckpt_dir(work / "weights")
    r = _load_net_in_subprocess(work, tmp_root, "weights")
    assert r.returncode == 0 and "LOADED" in r.stdout, r.stdout + r.stderr
    assert list(tmp_root.iterdir()) == [], list(tmp_root.iterdir())


def test_known_answer_limit_is_1e4_mse(model_dir, tmp_path):
    # Uniform noise +-0.03 on the stored mask: MSE ~3e-4 (above the 1e-4 limit, below grade_mask's
    # 1e-3 FAIL line) while p99.9 stays ~0.03 (under 0.05), so only the MSE rule can reject it.
    # (A scaled mask cannot isolate the MSE rule: its p99.9 breaks 0.05 first.)
    noise = np.random.RandomState(7)
    d = _perturbed_model_dir(model_dir, tmp_path / "noisy",
                             lambda m: m + noise.uniform(-0.03, 0.03, m.shape))
    out = run("verify.py", str(d), "--fixtures", "0", ok=False)
    assert out.returncode == 1, out.stdout + out.stderr
    assert _ka_line(out.stdout).rstrip().endswith("FAIL"), out.stdout


def test_known_answer_limit_includes_p999(model_dir, tmp_path):
    # stored mask x0.9 -> MSE ~3e-5 (under 1e-4) but p99.9 ~7e-2 (over 0.05)
    d = _perturbed_model_dir(model_dir, tmp_path / "x09", lambda m: m * 0.9)
    out = run("verify.py", str(d), "--fixtures", "0", ok=False)
    assert out.returncode == 1, out.stdout + out.stderr
    assert _ka_line(out.stdout).rstrip().endswith("FAIL"), out.stdout


def test_known_answer_ok_is_the_documented_rule():
    import verify
    ok = dict(mse=1e-4, max_abs=1.0, p999=0.05)
    assert verify.known_answer_ok(ok)
    assert not verify.known_answer_ok({**ok, "mse": 1.01e-4})
    assert not verify.known_answer_ok({**ok, "p999": 0.0501})
    assert not verify.known_answer_ok({**ok, "mse": float("nan")})
    assert not verify.known_answer_ok({**ok, "p999": float("nan")})


def test_read_reference_rejects_a_truncated_file(model_dir, tmp_path):
    import reference as R
    m = json.loads((model_dir / "manifest.json").read_text())
    data = (model_dir / m["reference_file"]).read_bytes()
    t, nf, nb, _ = struct.unpack("<4I", data[8:24])
    assert (t, nf, nb) == (2496, 180, 961) and len(data) == 24 + 4 * t * (nf + nb)
    R.read_reference(str(model_dir / m["reference_file"]))                  # the intact file reads
    cut = tmp_path / "cut.bin"
    cut.write_bytes(data[:-4])
    with pytest.raises(AssertionError, match="length"):
        R.read_reference(str(cut))
    bad = tmp_path / "dims.bin"
    bad.write_bytes(data[:8] + struct.pack("<4I", 2496, 180, 960, 0) + data[24:])
    with pytest.raises(AssertionError, match="dims"):
        R.read_reference(str(bad))
