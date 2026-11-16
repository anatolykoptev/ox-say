"""The contract checks in verify.py's predict_fn must hold under `python -O` (#447).

Needs no checkpoint, torch or coremltools: `reference` (which imports torch) and `coremltools` are replaced by
stubs that hold only the constants and the two constructors predict_fn touches, so the REAL predict_fn and
predict_once run. Each case runs in a child interpreter started with -O, where a bare `assert` is gone.

  python3 -B -m unittest engine/clean/convert/test_verify_guards.py   (or run it directly)
"""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).parent
STEM = "MossFormer2_SE_48K"

CHILD = r"""
import json, sys, types
import numpy as np
ref = types.ModuleType("reference"); ref.FRAMES20 = 2496; ref.MELS = 60
sys.modules["reference"] = ref
ct = types.ModuleType("coremltools"); models = types.SimpleNamespace()
class _Compiled:
    def __init__(self, path, compute_units=None): pass
    def predict(self, feed): return {"out": np.zeros((1, 2496, 961), np.float32)}
class _Package(_Compiled):
    def get_spec(self):
        shape = json.loads(sys.argv[3])
        arr = types.SimpleNamespace(shape=tuple(shape))
        inp = types.SimpleNamespace(name="in", type=types.SimpleNamespace(multiArrayType=arr))
        return types.SimpleNamespace(description=types.SimpleNamespace(input=[inp], output=[types.SimpleNamespace(name="out")]))
models.CompiledMLModel, models.MLModel = _Compiled, _Package
ct.models = models
sys.modules["coremltools"] = ct
sys.path.insert(0, sys.argv[1])
import verify
mask, err = verify.predict_once(sys.argv[2], None, sys.argv[4], np.zeros((2496, 180), np.float32))
print(json.dumps({"ok": mask is not None, "err": err}))
"""


def run_child(model_dir, shape, artifact):
    r = subprocess.run([sys.executable, "-O", "-B", "-c", CHILD, str(HERE), str(model_dir), json.dumps(shape), artifact],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise AssertionError(r.stdout + r.stderr)
    return json.loads(r.stdout.strip().splitlines()[-1])


def compiled_dir(root, shape):
    d = pathlib.Path(root) / (STEM + ".mlmodelc")
    d.mkdir(parents=True)
    meta = [{"inputSchema": [{"name": "in", "shape": json.dumps(shape)}], "outputSchema": [{"name": "out"}]}]
    (d / "metadata.json").write_text(json.dumps(meta))
    return pathlib.Path(root)


class VerifyGuardsUnderOptimize(unittest.TestCase):
    def test_a_compiled_model_of_the_right_shape_runs(self):
        with tempfile.TemporaryDirectory() as t:
            r = run_child(compiled_dir(t, [1, 2496, 180]), [1, 2496, 180], "mlmodelc")
        self.assertTrue(r["ok"], r)

    def test_a_compiled_model_of_the_wrong_shape_is_refused(self):
        with tempfile.TemporaryDirectory() as t:
            r = run_child(compiled_dir(t, [1, 1000, 180]), [1, 2496, 180], "mlmodelc")
        self.assertFalse(r["ok"], "the wrong-shape compiled model ran under -O: the shape check is a stripped assert")
        self.assertIn("unexpected compiled input schema", r["err"])

    def test_a_package_of_the_wrong_shape_is_refused(self):
        with tempfile.TemporaryDirectory() as t:
            (pathlib.Path(t) / (STEM + ".mlpackage")).mkdir()
            r = run_child(t, [1, 1000, 180], "mlpackage")
        self.assertFalse(r["ok"], "the wrong-shape package ran under -O: the shape check is a stripped assert")
        self.assertIn("unexpected package input", r["err"])

    def test_a_missing_artifact_is_a_fail_line_not_a_traceback(self):
        with tempfile.TemporaryDirectory() as t:
            r = run_child(t, [1, 2496, 180], "mlmodelc")
        self.assertFalse(r["ok"])
        self.assertIn("FileNotFoundError", r["err"])


if __name__ == "__main__":
    unittest.main()
