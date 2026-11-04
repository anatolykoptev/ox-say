"""Tests for the MossFormer2_SE_48K Core ML converter (local only, never CI -- torch and a
221 MB checkpoint do not belong on a runner).

  OX_CLEAN_CHECKPOINT=<path to last_best_checkpoint.pt or its dir> \
      .venv/bin/python -B -m pytest engine/clean/convert/test_convert.py

Run under the shared suite lock (one heavy ML job at a time):
  /usr/bin/lockf -k -t 3600 ~/tmp/.ox-say-suite.lock nice -n 15 \
      env OX_CLEAN_CHECKPOINT=... .venv/bin/python -B -m pytest test_convert.py

OX_CLEAN_MODEL_DIR=<a dir convert.py already wrote> skips the fixture conversion and tests that
directory read-only (used by the F5 falsification and for re-checking a downloaded model dir).
"""
import hashlib
import json
import os
import pathlib
import subprocess
import sys

import pytest

HERE = pathlib.Path(__file__).parent
CKPT = os.environ.get("OX_CLEAN_CHECKPOINT")
pytestmark = pytest.mark.skipif(not CKPT, reason="OX_CLEAN_CHECKPOINT unset")

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
    assert size <= 125 * 1024 * 1024, size                 # 125 MiB budget (controller decision 6)
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
