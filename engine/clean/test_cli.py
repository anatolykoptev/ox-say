#!/usr/bin/env python3
"""CLI contract of ox-clean: exit codes, the OS gate, the output rules, signals, the offline rule, the stats line.

Usage: test_cli.py --bin PATH (--models DIR | --no-models) [--clip x.wav] [unittest args]
  DIR is the models directory scripts/fetch-models.sh --clean-only lays out (it holds mossformer2-se-48k/).
  --no-models runs only the tests that need no model (the ones that end before the model is loaded: usage, version,
  the OS gate, the input and output refusals, a missing or unusable models folder); the rest are reported as skipped.
  It is for a machine that cannot run Core ML (the CI Intel VM) and is never a substitute for --models where the model
  can run: the release smoke on Apple Silicon passes --models.
  --clip is a mono 48 kHz float32 WAV with speech (CI passes one); without it the tests generate a synthetic voice-like
  clip, so no recording is needed. Needs no network and no Python packages.

Exit codes: 0 ok, 1 processing, 2 usage, 3 models, 4 input, 5 macOS < 15, 6 output; every failure line ends in
[reason=<token>]. Fixtures are written here with `struct`, so nothing binary is committed. The slow and failing runs use the binary's
test-only knobs OX_CLEAN_TEST_SLOW_MS and OX_CLEAN_TEST_FAIL_AFTER_WINDOWS (see Sources/ox-clean/main.swift); they are
inert unless set. Mutations (plan Task 8): each test names the one it kills.
"""
import argparse
import array
import functools
import hashlib
import math
import os
import random
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest

BIN = MODELS = CLIP = None
NO_MODELS = False
RATE = 48000
_cache = {}


def needs_models(test):
    """Marks a test that loads the model: skipped under --no-models, run (and able to fail) otherwise."""
    @functools.wraps(test)
    def wrapper(self, *a, **k):
        if NO_MODELS:
            self.skipTest("needs the model (--no-models)")
        return test(self, *a, **k)
    return wrapper


def run(*args, env=None, timeout=600):
    e = {k: v for k, v in os.environ.items() if not k.startswith("OX_CLEAN_")}
    e.update(env or {})
    return subprocess.run([BIN, *args], capture_output=True, text=True, env=e, timeout=timeout)


def reason(stderr):
    """The machine-readable token at the end of a failure line."""
    m = re.search(r"\[reason=([a-z0-9_]+)\]\s*$", stderr)
    return m.group(1) if m else None


def wav_bytes(samples=(), rate=RATE, channels=1, fmt=3, bits=32, data=None, data_size=None, riff_size=None):
    """A canonical WAV. `samples` are float32 (fmt 3) or int16 (fmt 1); `data` overrides the payload bytes."""
    if data is None:
        code = "f" if fmt == 3 else "h"
        data = struct.pack(f"<{len(samples)}{code}", *samples)
    align = channels * bits // 8
    fmt_chunk = struct.pack("<HHIIHH", fmt, channels, rate, rate * align, align, bits)
    size = len(data) if data_size is None else data_size
    return (b"RIFF" + struct.pack("<I", 36 + len(data) if riff_size is None else riff_size) + b"WAVE" + b"fmt " + struct.pack("<I", 16) + fmt_chunk
            + b"data" + struct.pack("<I", size) + data)


def float_wav(path, samples):
    with open(path, "wb") as f:
        f.write(wav_bytes(samples))
    return path


def voice_like(seconds, seed):
    """Deterministic voice-like audio: a vibrato harmonic stack under a syllable envelope, plus broadband noise.
    A few seconds are synthesised and tiled, so a long clip costs little."""
    key = ("voice", seconds, seed)
    if key not in _cache:
        rng = random.Random(seed)
        block = 4 * RATE
        base = array.array("f")
        for i in range(block):
            t = i / RATE
            f0 = 140 + 25 * math.sin(2 * math.pi * 0.9 * t) + 10 * math.sin(2 * math.pi * 5.5 * t)
            env = max(0.0, math.sin(2 * math.pi * 2.2 * t)) ** 0.5
            ph = 2 * math.pi * f0 * t
            v = sum(math.sin(k * ph) / k for k in range(1, 9)) * 0.12 * env
            base.append(v + 0.02 * rng.uniform(-1, 1))
        total = seconds * RATE
        out = array.array("f", (base * (total // block + 1))[:total])
        _cache[key] = out
    return _cache[key]


def read_float_wav(path):
    with open(path, "rb") as f:
        raw = f.read()
    assert raw[:4] == b"RIFF" and raw[8:12] == b"WAVE", "not a WAV"
    pos, fmt, payload = 12, None, None
    while pos + 8 <= len(raw):
        cid, size = raw[pos:pos + 4], struct.unpack_from("<I", raw, pos + 4)[0]
        if cid == b"fmt ":
            fmt = struct.unpack_from("<HHIIHH", raw, pos + 8)
        elif cid == b"data":
            payload = raw[pos + 8:pos + 8 + size]
            break
        pos += 8 + size + (size & 1)
    assert fmt and fmt[0] in (3, 0xFFFE) and fmt[1] == 1 and fmt[2] == RATE and fmt[5] == 32, f"not mono 48k float: {fmt}"
    a = array.array("f")
    a.frombytes(payload)
    return a


def si_sdr(est, ref):
    """Scale-invariant SDR in dB of `est` against `ref` (same length)."""
    dot = sum(map(float.__mul__, est, ref))
    energy = sum(map(float.__mul__, ref, ref))
    alpha = dot / energy
    target = [alpha * r for r in ref]
    noise = sum((e - t) ** 2 for e, t in zip(est, target))
    sig = sum(t * t for t in target)
    return 10 * math.log10(sig / noise) if noise > 0 else 200.0


def digest(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def clip_path(tmpdir):
    """The clip the model-needing tests use: --clip, else a generated 30 s voice-like one."""
    if CLIP:
        return CLIP
    p = os.path.join(tmpdir, "clip.wav")
    if not os.path.exists(p):
        float_wav(p, voice_like(30, seed=3))
    return p


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def path(self, name):
        return os.path.join(self.tmp.name, name)

    def clip(self):
        return clip_path(self.tmp.name)

    def long_clip(self):
        """70 s: four windows, so a slowed run has a long middle to be interrupted in."""
        p = self.path("long.wav")
        if not os.path.exists(p):
            float_wav(p, voice_like(70, seed=5))
        return p

    def assertNoOutput(self, out):
        self.assertFalse(os.path.exists(out), f"{out} must not exist")
        self.assertFalse(os.path.exists(out + ".part"), f"{out}.part must not exist")


class Contract(Case):
    # -- usage and version -------------------------------------------------------------------------------------------
    def test_usage_is_2(self):
        self.assertEqual(run().returncode, 2)
        self.assertEqual(run("a.wav", "b.wav").returncode, 2)
        self.assertEqual(run("a.wav", "b.wav", "--models").returncode, 2)
        self.assertEqual(run("a.wav", "b.wav", "--bogus", MODELS).returncode, 2)
        self.assertEqual(run("a.wav", "b.wav", "--models", MODELS, "extra").returncode, 2)
        self.assertEqual(run("--version", "extra").returncode, 2)

    def test_version_names_the_model(self):
        r = run("--version")
        self.assertEqual(r.returncode, 0)
        self.assertRegex(r.stdout, r"^ox-clean 1 \(model [0-9a-f]{8}\)\n$")

    # -- the OS gate: before the input, the models and Core ML -------------------------------------------------------
    # Mutation: Sources/ox-clean/main.swift, delete the `if let why = Platform.refusal()` line -> RED here (the run
    # goes on and exits 0).
    def test_old_macos_is_5(self):
        r = run(self.clip(), self.path("o.wav"), "--models", MODELS, env={"OX_CLEAN_ASSUME_MACOS": "14"})
        self.assertEqual(r.returncode, 5, r.stderr)
        self.assertIn("macOS 15", r.stderr)
        self.assertNoOutput(self.path("o.wav"))

    # -- models ------------------------------------------------------------------------------------------------------
    # Mutation: main.swift, `fail(f.exitCode, f.description)` of the model load -> `fail(.ok, ...)` -> RED.
    def test_missing_models_is_3(self):
        r = run(self.clip(), self.path("o.wav"), "--models", self.path("none"))
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1, "one line on stderr")
        self.assertEqual(reason(r.stderr), "missing")
        self.assertNoOutput(self.path("o.wav"))

    # Fix round 7. Mutation: MaskModel.swift, the errno switch collapsed to "missing" -> RED (the daemon would re-download).
    def test_an_unusable_models_folder_is_3_but_not_a_download_hint(self):
        open(self.path("a-file"), "w").close()
        os.symlink(self.path("loop"), self.path("loop"))
        for name in ("a-file", "loop"):
            r = run(self.clip(), self.path("o.wav"), "--models", self.path(name))
            self.assertEqual(r.returncode, 3, r.stderr)
            self.assertEqual(reason(r.stderr), "unreadable", name)
            self.assertNotIn("download", r.stderr, name)
            self.assertNoOutput(self.path("o.wav"))

    @needs_models
    def test_a_corrupt_known_answer_file_is_3_with_the_sentence(self):
        copy = self.path("models")
        src, dst = os.path.join(MODELS, "mossformer2-se-48k"), os.path.join(copy, "mossformer2-se-48k")
        os.makedirs(dst)
        for name in os.listdir(src):  # the 120 MB model is linked, not copied; only the reference file is ours
            if name != "reference_window.bin":
                os.symlink(os.path.realpath(os.path.join(src, name)), os.path.join(dst, name))
        with open(os.path.join(src, "reference_window.bin"), "rb") as f:
            data = bytearray(f.read())
        frames, feats = struct.unpack_from("<II", data, 8)
        data[24 + 4 * frames * feats + 4 * 1234 + 3] = 0x7F   # the top byte of one expected-mask float
        with open(os.path.join(dst, "reference_window.bin"), "wb") as f:
            f.write(data)
        r = run(self.clip(), self.path("o.wav"), "--models", copy)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("wrong answer on this Mac, so nothing was cleaned", r.stderr)
        self.assertEqual(reason(r.stderr), "known_answer")
        self.assertNoOutput(self.path("o.wav"))

    # -- input: everything that is not a mono 48 kHz float WAV is exit 4 ----------------------------------------------
    # Mutation: main.swift, the WavIO.Failure catch maps to `.failure` instead of `.input` -> RED (the 44.1 k case).
    def test_input_that_is_not_48k_mono_float_is_4(self):
        cases = {
            "44.1k": wav_bytes([0.0, 0.1, -0.1] * 100, rate=44100),
            "stereo": wav_bytes([0.0] * 200, channels=2),
            "int16": wav_bytes([0, 100, -100] * 100, fmt=1, bits=16),
            "not a wav": b"hello, this is not audio" * 10,
            "truncated": wav_bytes([0.1] * 100, data_size=4000),
        }
        for name, blob in cases.items():
            p = self.path("in.wav")
            with open(p, "wb") as f:
                f.write(blob)
            r = run(p, self.path("o.wav"), "--models", MODELS)
            self.assertEqual(r.returncode, 4, f"{name}: {r.stderr}")
            self.assertEqual(len(r.stderr.strip().splitlines()), 1, name)
            self.assertIn(reason(r.stderr), ("not_wav", "unsupported_format", "truncated"), name)
            self.assertNoOutput(self.path("o.wav"))

    def test_a_missing_empty_or_unreadable_input_is_4(self):
        r = run(self.path("nope.wav"), self.path("o.wav"), "--models", MODELS)
        self.assertEqual(r.returncode, 4, r.stderr)
        open(self.path("zero.wav"), "wb").close()
        self.assertEqual(run(self.path("zero.wav"), self.path("o.wav"), "--models", MODELS).returncode, 4)
        float_wav(self.path("empty.wav"), [])   # a valid header with no samples
        r = run(self.path("empty.wav"), self.path("o.wav"), "--models", MODELS)
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertIn("no audio", r.stderr)
        os.mkdir(self.path("dir.wav"))   # a directory is not a file we can read
        self.assertEqual(run(self.path("dir.wav"), self.path("o.wav"), "--models", MODELS).returncode, 4)
        self.assertNoOutput(self.path("o.wav"))

    # Fix round 7. Mutation: main.swift, the S_IFREG guard removed -> RED (the FIFO case hangs into the timeout, /dev/zero
    # is read forever or fails as "not a WAV").
    def test_a_device_or_fifo_input_is_4_not_a_regular_file(self):
        os.mkfifo(self.path("fifo.wav"))
        for p in ("/dev/zero", "/dev/null", self.path("fifo.wav")):
            r = run(p, self.path("o.wav"), "--models", MODELS, timeout=30)
            self.assertEqual(r.returncode, 4, f"{p}: {r.stderr}")
            self.assertIn("not a regular file", r.stderr, p)
            self.assertEqual(reason(r.stderr), "not_regular")
        self.assertNoOutput(self.path("o.wav"))

    # Fix round 8. Mutation: WavIO.swift, the 0xFFFFFFFF clamp removed -> RED (exit 4, truncated).
    @needs_models
    def test_a_streaming_wav_with_unknown_sizes_is_read_to_the_end(self):
        x = voice_like(3, seed=2)
        p = self.path("stream.wav")
        with open(p, "wb") as f:
            f.write(wav_bytes(x, data_size=0xFFFFFFFF, riff_size=0xFFFFFFFF))
        r = run(p, self.path("o.wav"), "--models", MODELS)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(read_float_wav(self.path("o.wav"))), len(x))
        with open(p, "wb") as f:   # any other overrun is still a cut-off file
            f.write(wav_bytes(x, data_size=0xFFFFFFFE))
        r = run(p, self.path("o2.wav"), "--models", MODELS)
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertEqual(reason(r.stderr), "truncated")

    @needs_models
    def test_a_non_finite_sample_is_4(self):
        for bad in (float("nan"), float("inf")):
            samples = list(voice_like(3, seed=1))
            samples[1000] = bad
            p = float_wav(self.path("bad.wav"), samples)
            r = run(p, self.path("o.wav"), "--models", MODELS)
            self.assertEqual(r.returncode, 4, r.stderr)
            self.assertIn("not a finite number", r.stderr)
            self.assertNoOutput(self.path("o.wav"))

    # -- the result --------------------------------------------------------------------------------------------------
    STATS = (r"^ox-clean: \d+\.\d s audio in \d+\.\d s \(\d+\.\dx\), load \d+\.\d s, first prediction \d+\.\d s, "
             r"units (cpuAndGPU|cpuOnly), device (.+), floor (\d+)x$")

    @needs_models
    def test_silence_in_silence_out_same_length_and_a_stats_line(self):
        n = 7 * RATE + 123
        p = float_wav(self.path("silence.wav"), [0.0] * n)
        r = run(p, self.path("o.wav"), "--models", MODELS)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = read_float_wav(self.path("o.wav"))
        self.assertEqual(len(out), n)
        self.assertLess(max(map(abs, out)), 1e-6)
        self.assertFalse(os.path.exists(self.path("o.wav.part")))
        m = re.fullmatch(self.STATS, r.stderr.strip())
        self.assertIsNotNone(m, r.stderr)
        units, device, floor = m.groups()
        self.assertEqual(device == "none", units == "cpuOnly", "device is none exactly on cpuOnly")
        want = 50 if os.uname().machine == "arm64" else (2 if units == "cpuOnly" else 5)
        self.assertEqual(int(floor), want, "the per-plan floor")
        for forbidden in ("NeuralEngine", "units all"):
            self.assertNotIn(forbidden, r.stderr)

    @needs_models
    def test_speech_is_changed_but_not_destroyed(self):
        r = run(self.clip(), self.path("o.wav"), "--models", MODELS)
        self.assertEqual(r.returncode, 0, r.stderr)
        x, y = read_float_wav(self.clip()), read_float_wav(self.path("o.wav"))
        self.assertEqual(len(y), len(x))
        self.assertTrue(all(math.isfinite(v) for v in y))
        sdr = si_sdr(y, x)
        self.assertLess(sdr, 60, "the output must differ from the input")
        if CLIP:   # real speech: the cleaned track is the speech with the noise taken out
            self.assertGreater(sdr, 5, f"si_sdr(out, in) = {sdr:.1f} dB: it is noise, not the input cleaned")
        else:      # a synthetic stack of harmonics is not what the model keeps; only "not silent, not the input" holds
            ex, ey = sum(v * v for v in x), sum(v * v for v in y)
            self.assertGreater(ey / ex, 0.01, "the output is nearly silent")

    @needs_models
    def test_it_never_opens_a_socket(self):
        profile = "(version 1)(allow default)(deny network*)"
        e = {k: v for k, v in os.environ.items() if not k.startswith("OX_CLEAN_")}
        r = subprocess.run(["sandbox-exec", "-p", profile, BIN, self.clip(), self.path("o.wav"), "--models", MODELS],
                           capture_output=True, text=True, env=e, timeout=600)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.exists(self.path("o.wav")))

    # -- never over a file that exists --------------------------------------------------------------------------------
    def test_out_equals_in_is_refused_by_path_symlink_and_hard_link(self):
        clip = self.path("in.wav")
        shutil.copyfile(self.clip(), clip)
        before = digest(clip)
        os.symlink(clip, self.path("sym.wav"))
        os.link(clip, self.path("hard.wav"))
        for label, out in (("same path", clip), ("dot path", os.path.join(self.tmp.name, ".", "in.wav")),
                           ("symlink", self.path("sym.wav")), ("hard link", self.path("hard.wav"))):
            r = run(clip, out, "--models", MODELS)
            self.assertEqual(r.returncode, 2, f"{label}: {r.stderr}")
            self.assertRegex(r.stderr, r"same file|is the input", label)
            self.assertEqual(reason(r.stderr), "same_file", label)
            self.assertEqual(digest(clip), before, f"{label}: the input changed")
        self.assertFalse(os.path.exists(clip + ".part"))

    # Output problems are exit 6, so the daemon can tell them from processing errors (1).
    # Mutation: main.swift, the `CLI.exists(outPath)` check -> `.failure` instead of `.output` -> RED.
    def test_an_existing_output_is_6_and_left_alone(self):
        out = self.path("o.wav")
        with open(out, "wb") as f:
            f.write(b"precious")
        r = run(self.clip(), out, "--models", MODELS)
        self.assertEqual(r.returncode, 6, r.stderr)
        self.assertEqual(reason(r.stderr), "out_exists")
        with open(out, "rb") as f:
            self.assertEqual(f.read(), b"precious")
        self.assertFalse(os.path.exists(out + ".part"))

    def test_a_part_file_that_is_not_ours_is_6_and_left_alone(self):
        out = self.path("o.wav")
        with open(out + ".part", "wb") as f:
            f.write(b"someone else's file, not a wav")
        r = run(self.clip(), out, "--models", MODELS)
        self.assertEqual(r.returncode, 6, r.stderr)
        self.assertEqual(reason(r.stderr), "part_foreign")
        with open(out + ".part", "rb") as f:
            self.assertEqual(f.read(), b"someone else's file, not a wav")
        self.assertFalse(os.path.exists(out))

    # Fix round 2. Mutation: main.swift, `reclaim` returns .live for everything it locked -> RED (the retry is refused).
    @needs_models
    def test_a_killed_run_leaves_a_part_that_the_retry_removes(self):
        out = self.path("o.wav")
        p = self.start_slow(out)
        p.send_signal(signal.SIGKILL)
        p.wait(timeout=30)
        self.assertTrue(os.path.exists(out + ".part"), "a SIGKILL leaves the .part (that is the case under test)")
        r = run(self.clip(), out, "--models", MODELS)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.exists(out))
        self.assertFalse(os.path.exists(out + ".part"))

    # Fix round 2. Mutation: WavIO.swift, O_EXLOCK dropped -> RED (the second run takes the live .part for a leftover).
    @needs_models
    def test_a_live_concurrent_run_is_refused_and_not_disturbed(self):
        out = self.path("o.wav")
        first = self.start_slow(out)
        r = run(self.clip(), out, "--models", MODELS)
        self.assertEqual(r.returncode, 6, r.stderr)
        self.assertEqual(reason(r.stderr), "part_live")
        # Fix round 5: the destination is settled BEFORE the model is touched, so even a broken models dir cannot mask it.
        # Mutation: main.swift, `CLI.createPart` moved after the model load -> RED (3 "missing" instead of 6 "part_live").
        r = run(self.clip(), out, "--models", self.path("no-models"))
        self.assertEqual((r.returncode, reason(r.stderr)), (6, "part_live"), r.stderr)
        self.assertTrue(os.path.exists(out + ".part"), "the live run's .part must survive the refused one")
        first.wait(timeout=120)
        self.assertEqual(first.returncode, 0, first.stderr.read())
        self.assertEqual(len(read_float_wav(out)), len(read_float_wav(self.long_clip())))

    def test_a_missing_or_unwritable_output_directory_is_6_before_any_model_time(self):
        started = time.time()
        r = run(self.clip(), self.path("no/such/dir/o.wav"), "--models", MODELS)
        self.assertEqual((r.returncode, reason(r.stderr)), (6, "output_dir"), r.stderr)
        open(self.path("file"), "w").close()
        r = run(self.clip(), self.path("file/o.wav"), "--models", MODELS)   # a file where the directory should be
        self.assertEqual((r.returncode, reason(r.stderr)), (6, "output_dir"), r.stderr)
        os.mkdir(self.path("ro"), 0o555)
        self.addCleanup(os.chmod, self.path("ro"), 0o755)
        r = run(self.clip(), self.path("ro/o.wav"), "--models", MODELS)
        self.assertEqual((r.returncode, reason(r.stderr)), (6, "not_writable"), r.stderr)
        self.assertNotIn("units", r.stderr, "the model must not have been loaded")
        self.assertLess(time.time() - started, 3, "three refusals, none of them paid for a model load")

    # Fix round 5: an unwritable directory is refused before any model time.
    # The .part is created before the slow model load, so a model failure has to remove it.
    # Mutation: main.swift, the model-load failure calls `fail(f)` without `writer: writer` -> RED (a .part is left).
    def test_a_model_failure_removes_the_part_created_before_it(self):
        out = self.path("o.wav")
        e = {k: v for k, v in os.environ.items() if not k.startswith("OX_CLEAN_")}
        p = subprocess.Popen([BIN, self.clip(), out, "--models", self.path("no-models")], env=e, stderr=subprocess.PIPE, text=True)
        _, err = p.communicate(timeout=60)
        self.assertEqual(p.returncode, 3, err)
        self.assertNoOutput(out)

    # Fix round 6. Mutation: main.swift, the `args.outputIsDirectoryPath` check removed -> RED (exit 4/1, or a file made).
    def test_an_output_spelled_as_a_directory_is_6_and_creates_nothing(self):
        os.mkdir(self.path("d"))
        self.clip()   # (the generated clip lives in the same directory)
        before = sorted(os.listdir(self.tmp.name))
        for spelling in (self.path("d") + "/", self.path("d") + "//", self.path("d") + "/.", self.path("d") + "/.."):
            r = run(self.clip(), spelling, "--models", MODELS)
            self.assertEqual((r.returncode, reason(r.stderr)), (6, "out_is_directory"), f"{spelling}: {r.stderr}")
        self.assertEqual(sorted(os.listdir(self.tmp.name)), before)
        self.assertEqual(os.listdir(self.path("d")), [])

    # Fix round 6. Mutation: Arguments.swift, the `--` branch or the any-position --models removed -> RED.
    @needs_models
    def test_models_may_come_first_and_double_dash_ends_the_options(self):
        r = run("--models", MODELS, "--", self.clip(), self.path("a.wav"))
        self.assertEqual(r.returncode, 0, r.stderr)
        r = run(self.clip(), "--models", MODELS, self.path("b.wav"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(run("-x.wav", self.path("c.wav"), "--models", MODELS).returncode, 2)

    # Fix round 1: exFAT has no exclusive rename (ENOTSUP after the whole clean). The image is made, attached and detached
    # here. Mutation: main.swift, the ENOTSUP branch removed -> RED (exit 6 publish_failed after a full run).
    def attach_exfat(self, size_mb):
        if not shutil.which("hdiutil"):
            self.skipTest("hdiutil is not available: cannot build an exFAT disk image")
        dmg, mnt = self.path("x.dmg"), self.path("mnt")
        made = subprocess.run(["hdiutil", "create", "-size", f"{size_mb}m", "-fs", "ExFAT", "-volname", "OXCLEANT", dmg],
                              capture_output=True, text=True)
        if made.returncode != 0:
            self.skipTest(f"hdiutil could not create an exFAT image: {made.stderr.strip()[:200]}")
        os.mkdir(mnt)
        att = subprocess.run(["hdiutil", "attach", "-nobrowse", "-mountpoint", mnt, dmg], capture_output=True, text=True)
        if att.returncode != 0:
            self.skipTest(f"hdiutil could not attach the exFAT image: {att.stderr.strip()[:200]}")
        self.addCleanup(lambda: subprocess.run(["hdiutil", "detach", mnt, "-force"], capture_output=True))
        return mnt

    @needs_models
    def test_output_on_exfat_is_published_by_copy_and_never_overwrites(self):
        mnt = self.attach_exfat(int(os.path.getsize(self.clip()) * 2.5 / 2**20) + 10)   # room for the .part and the copy
        out = os.path.join(mnt, "o.wav")
        r = run(self.clip(), out, "--models", MODELS)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(read_float_wav(out)), len(read_float_wav(self.clip())))
        self.assertFalse(os.path.exists(out + ".part"))
        before = digest(out)
        r = run(self.clip(), out, "--models", MODELS)   # still never over an existing file
        self.assertEqual((r.returncode, reason(r.stderr)), (6, "out_exists"), r.stderr)
        self.assertEqual(digest(out), before)

    # exFAT reports a different st_ino for the same file once it has grown, so "is the path still my file" must compare
    # fresh numbers. Mutation: WavIO.swift, discard() compares the inode recorded at create -> RED (the .part stays).
    @needs_models
    def test_a_failed_run_on_exfat_removes_its_part(self):
        mnt = self.attach_exfat(20)
        out = os.path.join(mnt, "o.wav")
        # (the early free-space check is bypassed: this test is about a run that fails after it started writing)
        r = run(self.long_clip(), out, "--models", MODELS,
                env={"OX_CLEAN_TEST_FAIL_AFTER_WINDOWS": "2", "OX_CLEAN_TEST_FREE_BYTES": str(10**12)})
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertEqual([n for n in os.listdir(mnt) if not n.startswith(".")], [])

    # Mutation: main.swift, `undo` no longer unlinks the temp it created -> RED (a half-copied .copy stays).
    # The early free-space check is bypassed (OX_CLEAN_TEST_FREE_BYTES) so the ENOSPC really happens in the copy.
    @needs_models
    def test_a_copy_that_runs_out_of_space_removes_what_it_made_and_is_disk_full(self):
        mnt = self.attach_exfat(20)   # the 13 MB .part fits; the 13 MB copy beside it does not
        out = os.path.join(mnt, "o.wav")
        r = run(self.long_clip(), out, "--models", MODELS, env={"OX_CLEAN_TEST_FREE_BYTES": str(10**12)})
        self.assertEqual((r.returncode, reason(r.stderr)), (6, "disk_full"), r.stderr)
        self.assertEqual([n for n in os.listdir(mnt) if n == "o.wav" or n.startswith(".o.wav") or n.endswith(".part")], [],
                         "nothing of ours may stay")

    # #474: a full disk mid-WRITE is the same exit 6 / disk_full as mid-copy (it was 1 write_failed).
    # Mutation: main.swift, the `CLI.isDiskFull(error)` line removed -> RED (exit 1, write_failed).
    @needs_models
    def test_a_disk_that_fills_during_the_clean_is_6_disk_full(self):
        mnt = self.attach_exfat(8)   # smaller than the 13 MB .part
        out = os.path.join(mnt, "o.wav")
        r = run(self.long_clip(), out, "--models", MODELS, env={"OX_CLEAN_TEST_FREE_BYTES": str(10**12)})
        self.assertEqual((r.returncode, reason(r.stderr)), (6, "disk_full"), r.stderr)
        self.assertEqual([n for n in os.listdir(mnt) if n == "o.wav" or n.startswith(".o.wav") or n.endswith(".part")], [])

    # #474: the free-space check comes before the model load and counts the copy room where there is no exclusive rename.
    # Mutation: main.swift, the `CLI.spaceRefusal` call removed -> RED (exit 3, the missing models, or a file made).
    def test_too_little_free_space_is_refused_before_the_model_load(self):
        out = self.path("o.wav")
        r = run(self.clip(), out, "--models", self.path("no-models"), env={"OX_CLEAN_TEST_FREE_BYTES": "1000"})
        self.assertEqual((r.returncode, reason(r.stderr)), (6, "disk_full"), r.stderr)
        self.assertIn("MB free", r.stderr)
        self.assertNoOutput(out)

    # Mutation: main.swift, spaceRefusal's `2 * one` -> `one` -> RED on the exFAT volume (the run goes on to the models, exit 3).
    def test_on_exfat_the_free_space_check_wants_room_for_the_copy_too(self):
        mnt = self.attach_exfat(20)   # ~19 MB free: fits one 13 MB result, not two
        out = os.path.join(mnt, "o.wav")
        r = run(self.long_clip(), out, "--models", self.path("no-models"))
        self.assertEqual((r.returncode, reason(r.stderr)), (6, "disk_full"), r.stderr)
        self.assertEqual([n for n in os.listdir(mnt) if n == "o.wav" or n.startswith(".o.wav") or n.endswith(".part")], [])

    # #474: a kill (or power cut) during the exFAT copy must not leave a truncated file under the FINAL name.
    # Mutation: main.swift publishByCopy, create `out` itself with O_EXCL and copy into it (the old way) -> RED (o.wav exists, partial).
    @needs_models
    def test_a_sigkill_during_the_exfat_copy_leaves_no_partial_output(self):
        mnt = self.attach_exfat(int(os.path.getsize(self.long_clip()) * 2.5 / 2**20) + 10)
        out = os.path.join(mnt, "o.wav")
        e = {k: v for k, v in os.environ.items() if not k.startswith("OX_CLEAN_")}
        e["OX_CLEAN_TEST_SLOW_COPY_MS"] = "1500"
        p = subprocess.Popen([BIN, self.long_clip(), out, "--models", MODELS], env=e, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        tmpname = os.path.join(mnt, ".o.wav.copy")
        deadline = time.time() + 300
        while not os.path.exists(tmpname):   # the copy has begun (the old code made `out` itself here)
            if p.poll() is not None:   # (stderr is read only here: reading a live process would block)
                self.fail(f"the run ended before the copy began: {p.stderr.read()}")
            self.assertLess(time.time(), deadline, "the copy never began")
            time.sleep(0.05)
        time.sleep(1.0)   # a chunk or two in
        p.kill()
        p.wait()
        self.assertFalse(os.path.exists(out), f"a partial {out} of {os.path.getsize(out) if os.path.exists(out) else 0} bytes sits under the final name")
        # the next run clears the leftovers and publishes a whole file
        r = run(self.long_clip(), out, "--models", MODELS)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(read_float_wav(out)), len(read_float_wav(self.long_clip())))
        self.assertEqual([n for n in os.listdir(mnt) if n.endswith(".copy") or n.endswith(".part")], [])

    # -- interrupted and failing runs ---------------------------------------------------------------------------------
    def start_slow(self, out, ignore=(), **env):
        e = {k: v for k, v in os.environ.items() if not k.startswith("OX_CLEAN_")}
        e.update({"OX_CLEAN_TEST_SLOW_MS": "600"}, **env)
        def inherit_ignores():   # what `cmd &` in a non-interactive shell hands down
            for sig in ignore:
                signal.signal(sig, signal.SIG_IGN)
        p = subprocess.Popen([BIN, self.long_clip(), out, "--models", MODELS], env=e, stderr=subprocess.PIPE, text=True,
                             preexec_fn=inherit_ignores)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        deadline = time.time() + 120
        # in flight: the .part (or, with the mutation that writes straight to the output, the output) exists
        while not (os.path.exists(out + ".part") or os.path.exists(out)):
            if p.poll() is not None:   # (the message is built only here: reading stderr of a live process would block)
                self.fail(f"the run ended before it started writing: {p.stderr.read()}")
            self.assertLess(time.time(), deadline, "the run never started writing")
            time.sleep(0.05)
        time.sleep(0.8)   # a window or so in
        if p.poll() is not None:
            self.fail(f"the run must still be going; it ended {p.returncode}: {p.stderr.read()}")
        return p

    # Mutation: main.swift, delete `interrupt.install()` (or the unlink in Interrupt.swift) -> RED (the part is left,
    # or the default action kills the process with the .part in place).
    # Fix round 4. SIGQUIT let the run finish with 0 because a process started by `cmd &` in a non-interactive shell
    # inherits SIG_IGN for SIGINT and SIGQUIT and nothing handled SIGQUIT; the children here inherit exactly that.
    # Mutation: Interrupt.swift, SIGHUP/SIGQUIT out of the signal list -> RED (rc 0 or -1/-3).
    @needs_models
    def test_signals_mid_run_remove_the_part_and_fail_even_when_the_shell_ignored_them(self):
        for sig, code in ((signal.SIGTERM, 143), (signal.SIGINT, 130), (signal.SIGHUP, 129), (signal.SIGQUIT, 131)):
            out = self.path(f"o{int(sig)}.wav")
            p = self.start_slow(out, ignore=(signal.SIGINT, signal.SIGQUIT))
            p.send_signal(sig)
            p.wait(timeout=30)
            self.assertEqual(p.returncode, code, f"{sig.name}")
            self.assertNoOutput(out)

    # Mutation F3: main.swift, `let part = outPath + ".part"` -> `let part = outPath` (write straight to the output)
    # -> RED here: the output exists while the run is killed.
    @needs_models
    def test_a_killed_run_leaves_no_output(self):
        out = self.path("o.wav")
        p = self.start_slow(out)
        p.send_signal(signal.SIGKILL)
        p.wait(timeout=30)
        self.assertEqual(p.returncode, -signal.SIGKILL)
        self.assertFalse(os.path.exists(out), "a SIGKILL may leave the .part but never a half-written output")

    # Mutation F6: main.swift, drop `writer?.abandon()` in fail() -> RED here (exit() skips the deinit, so the .part stays).
    @needs_models
    def test_a_failure_after_the_first_window_leaves_nothing(self):
        out = self.path("o.wav")
        r = run(self.long_clip(), out, "--models", MODELS, env={"OX_CLEAN_TEST_FAIL_AFTER_WINDOWS": "1"})
        self.assertEqual((r.returncode, reason(r.stderr)), (1, "test_seam"), r.stderr)
        self.assertIn("OX_CLEAN_TEST_FAIL_AFTER_WINDOWS", r.stderr)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1)
        self.assertNoOutput(out)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    which = ap.add_mutually_exclusive_group(required=True)
    which.add_argument("--models")
    which.add_argument("--no-models", action="store_true")
    ap.add_argument("--clip")
    a, rest = ap.parse_known_args()
    NO_MODELS = a.no_models
    # Without models the tests that still pass a models folder get one that does not exist: every test left running
    # ends before the model is touched, so the folder is only ever named, never opened.
    BIN, MODELS, CLIP = os.path.abspath(a.bin), a.models or os.path.join(tempfile.gettempdir(), "ox-clean-no-models"), a.clip
    unittest.main(argv=[sys.argv[0], *rest])
