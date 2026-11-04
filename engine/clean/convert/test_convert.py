"""Tests for the MossFormer2_SE_48K Core ML converter (local only, never CI -- torch and a
221 MB checkpoint do not belong on a runner).

  OX_CLEAN_CHECKPOINT=<path to last_best_checkpoint.pt or its dir> \
      .venv/bin/python -B -m pytest engine/clean/convert/test_convert.py

The suite loads torch and Core ML models and a conversion is a multi-GB job, so run one heavy
job at a time and at low priority:
  nice -n 15 env OX_CLEAN_CHECKPOINT=... .venv/bin/python -B -m pytest test_convert.py

OX_CLEAN_MODEL_DIR=<a dir convert.py already wrote> skips the fixture conversion and tests that
directory read-only (also for re-checking a downloaded model dir). verify.py needs the
.mlpackage in that directory; the .mlmodelc alone is not enough.
"""
import hashlib
import json
import os
import pathlib
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
    updated). The mlpackage is symlinked, so the model itself is unchanged: verify's known-answer
    error is then exactly the perturbation, with no conversion."""
    import reference as R
    dst.mkdir()
    os.symlink(src / (MODEL_STEM + ".mlpackage"), dst / (MODEL_STEM + ".mlpackage"))
    m = json.loads((src / "manifest.json").read_text())
    feats, mask = R.read_reference(str(src / m["reference_file"]))
    R.write_reference(str(dst / m["reference_file"]), feats, perturb(mask).astype(np.float32))
    m["reference_sha256"] = hashlib.sha256((dst / m["reference_file"]).read_bytes()).hexdigest()
    (dst / "manifest.json").write_text(json.dumps(m))
    return dst


def _ka_line(stdout):
    return next(l for l in stdout.splitlines() if "known-answer" in l)


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
