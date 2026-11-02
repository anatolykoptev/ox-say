#!/usr/bin/env python3
"""CLI contract of ox-diar: exit codes, the OS gate, the offline rule, the JSON.

Usage: test_cli.py --bin PATH --models DIR [--clip x.wav --speakers N] [--engine E] [unittest args]
  DIR holds the model sets scripts/fetch-models.sh lays out (speaker-diarization/ for pyannote,
  nemotron-3-diarization/ for nemotron; the nemotron engine needs only its own directory).
  --engine E (default nemotron) is appended to every diarize call; cases that make no sense for an engine skip
  themselves. --clip is a 16 kHz mono WAV with --speakers voices (CI passes the AMI excerpt: 4); the test turns
  it into the raw s16le file ox-diar takes. Without it the tests that need a real recording are skipped and say
  so.
Needs no network and no Python packages. Mutation hooks: see the plan, Task 20a.
"""
import argparse
import json
import math
import random
import os
import re
import stat
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import wave

BIN = MODELS = CLIP = None
SPEAKERS = 0
ENGINE = "nemotron"


def run(*args, env=None):
    e = dict(os.environ)
    e.pop("OX_DIAR_ASSUME_MACOS", None)
    e.update(env or {})
    return subprocess.run([BIN, *args], capture_output=True, text=True, env=e, timeout=600)


def diar(*args, env=None):
    """A diarize call: the engine under test is named the way the daemon would (the flag is part of the call)."""
    return run(*args, "--engine", ENGINE, env=env)


# What counts as "audio reached the temporary directory". macOS system daemons create files in the shared temporary
# directory at any moment: `com.apple.inputanalyticsd`, `com.apple.ScopedBookmarkAgent`, `com.apple.Maps.mapssyncd`,
# then `com.apple.tipsd/CFNetworkDownload_*.tmp` (about 49 KB) and `com.apple.duetexpertd` on the hosted macos-15 VM.
# Every rule on names or sizes of a shared directory flaked sooner or later, so the oracle looks at CONTENT, which no
# daemon can match: a few short non-silent windows from the start of the clip are turned into byte signatures for the
# encodings a stream or WAV copy would use (int16 little-endian; float32 little-endian scaled by 1/32768 and by
# 1/32767), and a new or grown file at any depth, in any namespace including `com.apple.*`, is suspect when it holds
# one of them. Files are read as they appear and again as they grow (only the new bytes, with an overlap so a
# signature cannot hide on a chunk boundary), so a file that its owner deletes at the end of a run is still judged;
# at most one chunk of one file is in memory. A file we cannot read is suspect only when it belongs to our own uid:
# ox-diar runs as us, so a file it made is readable by us, while an unreadable file of another user's daemon cannot
# be ours. A file already present at the start is judged only for bytes appended during the run.
# What this cannot see: audio at another sample rate, compressed audio, a transformed feature matrix (mel, embedding),
# or a file created and deleted between two polls (a few milliseconds) without ever growing past one poll.
SIG_SAMPLES = 128           # samples per signature window: 256 bytes as int16, 512 as float32
SIG_COUNT = 3               # windows per encoding, all near the start so a run killed after a second still has them
SIG_SEARCH_SECONDS = 10     # how far into the clip to look for non-silent windows
SIG_MIN_PEAK = 1000         # a window needs a sample at least this loud (of 32768) ...
SIG_MIN_DISTINCT = 32       # ... and this many different sample values, so silence and DC offsets never qualify
SCAN_CHUNK = 1 << 20


def _f32_of_ratio(num, den):
    """The float32 nearest to num/den, rounded once (a double in between could round twice), as 4 little-endian bytes."""
    if num == 0:
        return struct.pack("<f", 0.0)
    sign, n = (-1, -num) if num < 0 else (1, num)
    e = n.bit_length() - den.bit_length() - 24  # n/den is in [2**(e+23), 2**(e+25)): scale so the quotient has 24-25 bits
    while True:
        scaled = (n << max(-e, 0)), (den << max(e, 0))
        q, r = divmod(*scaled)
        if 1 << 23 <= q < 1 << 24:
            break
        e += 1 if q >= 1 << 24 else -1
    if 2 * r > scaled[1] or (2 * r == scaled[1] and q & 1):
        q += 1
    return struct.pack("<f", sign * math.ldexp(q, e))


def audio_signatures(pcm):
    """Byte signatures of up to SIG_COUNT non-silent windows near the start of `pcm` (16 kHz mono s16le), in the
    three encodings. Empty when the clip has no such window: the caller must treat that as a failure, never a pass."""
    sigs = []
    limit = min(len(pcm) // 2, SIG_SEARCH_SECONDS * 16000)
    start = 0
    while start + SIG_SAMPLES <= limit and len(sigs) < SIG_COUNT * 3:
        window = struct.unpack_from(f"<{SIG_SAMPLES}h", pcm, start * 2)
        if max(map(abs, window)) >= SIG_MIN_PEAK and len(set(window)) >= SIG_MIN_DISTINCT:
            sigs.append(pcm[start * 2:(start + SIG_SAMPLES) * 2])
            sigs.append(b"".join(_f32_of_ratio(s, 32768) for s in window))
            sigs.append(b"".join(_f32_of_ratio(s, 32767) for s in window))
        start += SIG_SAMPLES
    return sigs


def scan_file(path, sigs, start=0, chunk=SCAN_CHUNK):
    """(found, end): whether a signature occurs in path[start:], and the offset read up to. Reads `chunk` bytes at a
    time with an overlap of the longest signature, so one chunk is all that is ever held."""
    keep = max(map(len, sigs)) - 1
    with open(path, "rb") as f:
        pos = max(0, start - keep)
        f.seek(pos)
        tail = b""
        while True:
            block = f.read(chunk)
            if not block:
                return False, pos
            buf = tail + block
            if any(s in buf for s in sigs):
                return True, pos + len(block)
            tail = buf[-keep:] if keep else b""
            pos += len(block)


class TempWatch:
    """Watches directory trees for files that hold a signature. Create it BEFORE the run (it snapshots what is
    there), call poll() often during the run and once after it; `suspects` maps path -> reason."""

    def __init__(self, roots, sigs, exclude=(), chunk=SCAN_CHUNK):
        self.roots, self.sigs, self.chunk = list(roots), sigs, chunk
        self.exclude = tuple(os.path.realpath(x) for x in exclude)  # compared as whole path components
        self.suspects, self.scanned, self.before = {}, {}, {}
        self.ignored = set()
        for path, st in self._files(record_unreadable=False):
            self.before[path] = (st.st_size, st.st_mtime_ns)

    def _excluded(self, path):
        return any(path == x or path.startswith(x + os.sep) for x in self.exclude)

    def _ours(self, path):
        try:
            return os.lstat(path).st_uid == os.getuid()
        except OSError:
            return False  # gone: nothing left to hold audio

    def _unreadable(self, path, err, record):
        if record and path not in self.ignored and self._ours(path):
            self.suspects[path] = f"cannot be inspected ({err.strerror}) and belongs to this user, so it cannot be shown to hold no audio"

    def _files(self, record_unreadable=True):
        for root in self.roots:
            stack = [root]
            while stack:
                d = stack.pop()
                if self._excluded(d):
                    continue
                try:
                    entries = list(os.scandir(d))
                except FileNotFoundError:
                    continue
                except OSError as err:
                    self._unreadable(d, err, record_unreadable)
                    if not record_unreadable:
                        self.ignored.add(d)
                    continue
                for e in entries:
                    try:
                        st = e.stat(follow_symlinks=False)  # a symlink is not followed
                    except FileNotFoundError:
                        continue
                    except OSError as err:
                        self._unreadable(e.path, err, record_unreadable)
                        continue
                    if stat.S_ISDIR(st.st_mode):
                        stack.append(e.path)
                    elif stat.S_ISREG(st.st_mode):
                        yield e.path, st

    def poll(self):
        for path, st in self._files():
            if path in self.suspects or self._excluded(path):
                continue
            pos = self.scanned.get(path)
            if pos is None:
                old = self.before.get(path)
                if old is None:
                    pos = 0
                elif (st.st_size, st.st_mtime_ns) == old:
                    continue
                else:
                    pos = old[0]  # a file that was already there: only what was appended
            elif st.st_size < pos:
                pos = 0  # truncated and rewritten
            if path in self.scanned and st.st_size == pos:
                continue
            if st.st_size <= pos:
                self.scanned[path] = st.st_size
                continue
            try:
                found, end = scan_file(path, self.sigs, pos, self.chunk)
            except FileNotFoundError:
                continue
            except OSError as err:
                self._unreadable(path, err, True)
                continue
            self.scanned[path] = end
            if found:
                self.suspects[path] = f"holds the audio of the clip ({st.st_size} bytes)"


def synthetic_clip(seconds, seed, silent_seconds=0):
    """Deterministic noise-like 16 kHz mono s16le audio (loud, many distinct values), after `silent_seconds` of zeros."""
    rng = random.Random(seed)
    return bytes(2 * 16000 * silent_seconds) + struct.pack(f"<{16000 * seconds}h", *(rng.randint(-12000, 12000) for _ in range(16000 * seconds)))


def float32_copy(pcm, divisor=32768):
    samples = struct.unpack(f"<{len(pcm) // 2}h", pcm)
    return b"".join(_f32_of_ratio(s, divisor) for s in samples)


class AudioOracle(unittest.TestCase):
    """The content check on generated audio; needs no models and no binary."""

    def setUp(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.tmp = type("Tmp", (), {"name": os.path.realpath(td.name)})  # /var is a symlink to /private/var on macOS
        self.pcm = synthetic_clip(1, seed=1)
        self.sigs = audio_signatures(self.pcm)

    def file(self, name, data):
        p = os.path.join(self.tmp.name, name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)
        return p

    def found(self, data, **kw):
        return scan_file(self.file("x.bin", data), self.sigs, **kw)[0]

    def test_the_float32_rounding_is_the_nearest_float(self):
        from fractions import Fraction
        for d in (32768, 32767):
            for v in (1, -1, 7, 12345, -32768, 32767, 20000, -999, 3):
                got = _f32_of_ratio(v, d)
                bits = struct.unpack("<I", got)[0]
                x = Fraction(v, d)
                f = lambda b: Fraction(struct.unpack("<f", struct.pack("<I", b))[0])
                for nb in (bits - 1, bits + 1):  # the neighbouring floats are never closer than the one chosen
                    self.assertLessEqual(abs(f(bits) - x), abs(f(nb) - x), (v, d))
        self.assertEqual(_f32_of_ratio(3, 32768), struct.pack("<f", 3 / 32768))
        self.assertEqual(_f32_of_ratio(0, 32767), struct.pack("<f", 0.0))

    def test_an_int16_copy_is_found(self):
        self.assertTrue(self.found(self.pcm))

    def test_a_float32_copy_is_found_at_both_scales(self):
        self.assertTrue(self.found(float32_copy(self.pcm, 32768)))
        self.assertTrue(self.found(float32_copy(self.pcm, 32767)))

    def test_a_copy_with_a_header_in_front_is_found(self):
        self.assertTrue(self.found(b"RIFF" + bytes(40) + self.pcm))
        self.assertTrue(self.found(b"\x00" * 4099 + float32_copy(self.pcm)))

    def test_a_partial_copy_holding_the_window_is_found(self):
        first = audio_signatures(self.pcm)[0]
        at = self.pcm.index(first) + len(first) + 10
        self.assertTrue(self.found(self.pcm[:at]))
        self.assertTrue(self.found(float32_copy(self.pcm[:at])))

    def test_a_signature_across_a_chunk_boundary_is_found(self):
        data = bytes(1000) + self.sigs[0] + bytes(1000)
        self.assertTrue(self.found(data, chunk=1000 + len(self.sigs[0]) // 2))
        self.assertTrue(self.found(data, chunk=1))

    def test_random_bytes_and_zeros_are_not_found(self):
        self.assertFalse(self.found(random.Random(5).randbytes(1 << 20)))
        self.assertFalse(self.found(bytes(1 << 20)))

    def test_a_different_clip_is_not_found(self):
        other = synthetic_clip(1, seed=2)
        self.assertFalse(self.found(other))
        self.assertFalse(self.found(float32_copy(other)))

    def test_a_silent_region_is_never_a_signature(self):
        pcm = synthetic_clip(1, seed=3, silent_seconds=2)
        sigs = audio_signatures(pcm)
        self.assertTrue(sigs)
        zeros = (bytes(2 * SIG_SAMPLES), bytes(4 * SIG_SAMPLES))
        self.assertFalse(any(s in zeros for s in sigs))
        self.assertTrue(all(pcm.index(s) >= 2 * 2 * 16000 for s in sigs if len(s) == 2 * SIG_SAMPLES), "the windows start after the silence")
        self.assertEqual(audio_signatures(bytes(2 * 16000 * 3)), [], "a silent clip has no signature, and the test must fail on that, not pass")
        self.assertFalse(scan_file(self.file("silence", bytes(1 << 16)), sigs)[0], "a file of zeros is not a copy of anything")

    def test_there_are_three_windows_per_encoding_near_the_start(self):
        self.assertEqual(len(self.sigs), 9)
        for s in self.sigs[::3]:
            self.assertLess(self.pcm.index(s), 2 * 16000)

    def watch(self, **kw):
        d = os.path.join(self.tmp.name, "watched")
        os.makedirs(d, exist_ok=True)
        return d, TempWatch([d], self.sigs, **kw)

    def test_a_new_file_that_holds_the_audio_is_flagged_in_any_namespace(self):
        d, w = self.watch()
        p = self.file("watched/com.apple.tipsd/deep/er/stream.raw", float32_copy(self.pcm))
        w.poll()
        self.assertIn(p, w.suspects)

    def test_a_file_deleted_after_it_was_judged_stays_flagged(self):
        d, w = self.watch()
        p = self.file("watched/fluidaudio-streaming-x.raw", self.pcm)
        w.poll()
        os.remove(p)
        w.poll()
        self.assertIn(p, w.suspects)

    def test_a_file_that_grows_into_a_copy_is_flagged_when_it_does(self):
        d, w = self.watch()
        p = self.file("watched/stream.raw", b"header")
        w.poll()
        self.assertEqual(w.suspects, {})
        with open(p, "ab") as f:
            f.write(float32_copy(self.pcm))
        w.poll()
        self.assertIn(p, w.suspects)

    def test_daemon_files_of_any_size_are_not_flagged(self):
        d, w = self.watch()
        self.file("watched/com.apple.tipsd/CFNetworkDownload_x.tmp", random.Random(1).randbytes(49 * 1024))
        self.file("watched/com.apple.duetexpertd/state", b"\0" * (1 << 21))
        w.poll()
        self.assertEqual(w.suspects, {})

    def test_a_file_that_was_already_there_and_did_not_change_is_not_flagged(self):
        os.makedirs(os.path.join(self.tmp.name, "watched"))
        p = self.file("watched/old.raw", self.pcm)
        d, w = self.watch()
        w.poll()
        self.assertEqual(w.suspects, {})

    def test_an_excluded_tree_is_not_judged(self):
        d, w = self.watch(exclude=[os.path.join(self.tmp.name, "watched", "mine")])
        self.file("watched/mine/clip.pcm", self.pcm)
        other = self.file("watched/mine2/clip.pcm", self.pcm)  # a sibling whose name merely starts the same is not excluded
        w.poll()
        self.assertEqual(list(w.suspects), [os.path.join(d, "mine2", "clip.pcm")])

    def test_an_unreadable_file_of_ours_is_flagged_and_a_symlink_is_not_followed(self):
        d, w = self.watch()
        p = self.file("watched/locked", b"x")
        os.chmod(p, 0)
        self.addCleanup(os.chmod, p, 0o600)
        outside = self.file("outside.raw", self.pcm)
        os.symlink(outside, os.path.join(d, "link"))
        w.poll()
        if os.access(p, os.R_OK):  # running as root: nothing is unreadable
            self.skipTest("root reads everything")
        self.assertIn(p, w.suspects)
        self.assertNotIn(os.path.join(d, "link"), w.suspects)


class Contract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def path(self, name):
        return os.path.join(self.tmp.name, name)

    def load(self, name):
        with open(self.path(name)) as f:
            return json.load(f)

    def silence(self, seconds):
        p = self.path("silence.pcm")
        with open(p, "wb") as f:
            f.write(struct.pack("<h", 0) * (16000 * seconds))
        return p

    def clip_pcm(self):
        p = self.path("clip.pcm")
        with wave.open(CLIP, "rb") as w:
            assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, 16000), "the clip must be 16 kHz mono s16"
            with open(p, "wb") as f:
                f.write(w.readframes(w.getnframes()))
        return p

    def test_usage_is_exit_2(self):
        self.assertEqual(run().returncode, 2)
        self.assertEqual(run("a.pcm", "b.json").returncode, 2)
        self.assertEqual(run("a.pcm", "b.json", "--models").returncode, 2)
        self.assertEqual(run("a.pcm", "b.json", "--bogus", MODELS).returncode, 2)
        self.assertEqual(run("a.pcm", "b.json", "--models", MODELS, "extra").returncode, 2)

    def test_version_names_the_pins(self):
        r = run("--version")
        self.assertEqual(r.returncode, 0)
        self.assertRegex(r.stdout, r"^ox-diar 1 \(FluidAudio \d+\.\d+\.\d+, models [0-9a-f]{8}\)\n$")

    def test_missing_or_empty_input_is_exit_4(self):
        r = diar(self.path("nope.pcm"), self.path("o.json"), "--models", MODELS)
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertFalse(os.path.exists(self.path("o.json")))
        open(self.path("empty.pcm"), "wb").close()
        r = diar(self.path("empty.pcm"), self.path("o.json"), "--models", MODELS)
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertIn("no audio", r.stderr)

    # The OS gate sits before everything that touches FluidAudio, the input and the models. The variable can only
    # lower the version the gate sees: that is how CI on macOS 15 exercises the refusal.
    # Mutation: Sources/ox-diar/main.swift, delete the `if let why = Platform.refusal(version: version)` line -> RED
    # (the bogus input then gives exit 4, not 5).
    def test_macos_14_is_refused_before_anything_else(self):
        r = diar(self.path("nope.pcm"), self.path("o.json"), "--models", self.path("no-models"),
                 env={"OX_DIAR_ASSUME_MACOS": "14.8"})
        self.assertEqual(r.returncode, 5, r.stderr)
        self.assertIn("macOS 15", r.stderr)
        self.assertFalse(os.path.exists(self.path("o.json")))

    def test_the_assumed_version_cannot_lift_the_gate_over_a_real_one(self):
        r = diar(self.path("nope.pcm"), self.path("o.json"), "--models", MODELS, env={"OX_DIAR_ASSUME_MACOS": "99"})
        self.assertEqual(r.returncode, 4, r.stderr)  # past the gate, stopped by the missing input

    # Offline: a directory without the models is exit 3 at once; FluidAudio would otherwise download.
    # Mutation: Sources/ox-diar/main.swift, delete `ModelHub.offlineMode = true` -> RED on a machine with a network
    # (it fetches ~20 MB and the test takes seconds, or exits 0), and unprovable without one.
    def test_missing_models_are_exit_3_and_never_a_download(self):
        started = time.time()
        r = diar(self.silence(2), self.path("o.json"), "--models", self.path("empty"))
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertLess(time.time() - started, 20)
        fetched = [f for _, _, fs in os.walk(self.path("empty")) for f in fs]
        self.assertEqual(fetched, [], "nothing may be downloaded into the models directory")

    def test_a_directory_without_the_revision_marker_is_exit_3(self):
        self.require_engine("pyannote")  # under nemotron the same tree fails on its own marker instead
        # the marker lives inside the real directory; a copy of the tree without it is the failure we want
        copy = self.path("copy")
        subprocess.run(["ditto", os.path.join(MODELS, "speaker-diarization"), os.path.join(copy, "speaker-diarization")], check=True)
        os.remove(os.path.join(copy, "speaker-diarization", ".fluidaudio-revision"))
        r = diar(self.silence(2), self.path("o.json"), "--models", copy)
        self.assertEqual(r.returncode, 3, r.stderr)

    # --- the nemotron engine's own readiness: the nemotron-3-diarization/ marker alone ---

    def require_engine(self, engine):
        if ENGINE != engine:
            self.skipTest(f"a {engine} case (ENGINE={ENGINE})")

    def nemotron_dir(self):
        d = os.path.join(MODELS, "nemotron-3-diarization")
        self.require_engine("nemotron")
        if not os.path.isdir(d):
            self.skipTest(f"no nemotron set in {MODELS}")
        return d

    def test_nemotron_needs_no_pyannote_set(self):
        # The nemotron readiness check reads nemotron-3-diarization/.ox-say-revision alone: a models dir with
        # no speaker-diarization/ at all still loads and runs.
        copy = self.path("nem-only")
        subprocess.run(["ditto", self.nemotron_dir(), os.path.join(copy, "nemotron-3-diarization")], check=True)
        r = diar(self.silence(2), self.path("o.json"), "--models", copy)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_nemotron_does_not_read_the_pyannote_directory(self):
        # ...and the other direction: a models dir whose only model directory is the pyannote set's is not
        # "models present" for the nemotron engine.
        self.require_engine("nemotron")
        copy = self.path("pyan-only")
        os.makedirs(os.path.join(copy, "speaker-diarization"))
        r = diar(self.silence(2), self.path("o.json"), "--models", copy)
        self.assertEqual(r.returncode, 3, r.stderr)

    def test_a_directory_without_the_nemotron_marker_is_exit_3(self):
        copy = self.path("nem-nomarker")
        subprocess.run(["ditto", self.nemotron_dir(), os.path.join(copy, "nemotron-3-diarization")], check=True)
        os.remove(os.path.join(copy, "nemotron-3-diarization", ".ox-say-revision"))
        r = diar(self.silence(2), self.path("o.json"), "--models", copy)
        self.assertEqual(r.returncode, 3, r.stderr)

    def test_a_nemotron_marker_with_another_revision_is_exit_3(self):
        # Mutation: Sources/ox-diar/main.swift, delete the `marker == Pins.nemotronModelsRevision` comparison ->
        # RED (the set itself is real, so without the check the run exits 0).
        copy = self.path("nem-wrongrev")
        subprocess.run(["ditto", self.nemotron_dir(), os.path.join(copy, "nemotron-3-diarization")], check=True)
        with open(os.path.join(copy, "nemotron-3-diarization", ".ox-say-revision"), "w") as f:
            f.write("0" * 40 + "\n")
        r = diar(self.silence(2), self.path("o.json"), "--models", copy)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertFalse(os.path.exists(self.path("o.json")))

    def test_silence_is_an_empty_result_not_an_error(self):
        r = diar(self.silence(12), self.path("o.json"), "--models", MODELS)
        self.assertEqual(r.returncode, 0, r.stderr)
        d = self.load("o.json")
        self.assertEqual((d["version"], d["speakers"], d["segments"]), (1, [], []))
        self.assertAlmostEqual(d["duration_s"], 12.0, places=2)
        self.assertEqual([n for n in os.listdir(self.tmp.name) if "part" in n.lower() or n.startswith(".")], [])

    def test_a_recording_gives_the_contract(self):
        if not CLIP:
            self.skipTest("no --clip")
        r = diar(self.clip_pcm(), self.path("o.json"), "--models", MODELS)
        self.assertEqual(r.returncode, 0, r.stderr)
        d = self.load("o.json")
        self.assertEqual(sorted(d), ["duration_s", "segments", "speakers", "timing_s", "version"])
        self.assertEqual(len(d["speakers"]), SPEAKERS)
        self.assertEqual([s["id"] for s in d["speakers"]], list(range(SPEAKERS)), "ids are dense, as ParseDiarization needs")
        speech = [s["speech_s"] for s in d["speakers"]]
        self.assertEqual(speech, sorted(speech, reverse=True))
        # pyannote clusters carry the 256-float VBx centroid; the nemotron engine emits no voiceprints (Variant B)
        want_embedding = 256 if ENGINE == "pyannote" else 0
        for s in d["speakers"]:
            self.assertEqual(len(s["embedding"]), want_embedding)
        self.assertNotIn("embed", d["timing_s"], "no embedding pass runs on the nemotron path")
        prev_end = 0.0
        for seg in d["segments"]:
            self.assertGreater(seg["e"], seg["s"])
            self.assertGreaterEqual(seg["s"], prev_end - 1e-6, "exclusive timeline: no overlap")
            self.assertLess(seg["spk"], SPEAKERS)
            prev_end = seg["e"]
        for s in d["speakers"]:
            total = sum(g["e"] - g["s"] for g in d["segments"] if g["spk"] == s["id"])
            self.assertAlmostEqual(total, s["speech_s"], delta=0.01 * len(d["segments"]))

    # The positional form (no --engine; diar() always adds the flag for the engine under test) is the default engine,
    # Nemotron: a real result, the units line of the Nemotron loader, none of pyannote's window log, and no voiceprints.
    # Mutation: Sources/OxDiarCore/Arguments.swift `var engine = Engine.nemotron` -> `.pyannote` -> RED here.
    def test_the_positional_form_is_the_nemotron_engine(self):
        self.require_engine("nemotron")  # the pyannote contract step must not run Nemotron (units asked: Neural Engine)
        if not CLIP:
            self.skipTest("no --clip")
        if not os.path.isdir(os.path.join(MODELS, "nemotron-3-diarization")):
            self.skipTest(f"no nemotron set in {MODELS}")
        r = run(self.clip_pcm(), self.path("o.json"), "--models", MODELS)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(re.search(r"Segmentation timings: windows=(\d+)", r.stderr),
                          "the pyannote pipeline ran\n" + r.stderr[-400:])
        self.assertIsNotNone(re.search(r"compute units \w+\n", r.stderr), "the Nemotron loader did not run\n" + r.stderr[-400:])
        d = self.load("o.json")
        self.assertGreater(len(d["speakers"]), 0)
        for s in d["speakers"]:
            self.assertEqual(len(s["embedding"]), 0, "nemotron emits no voiceprints")

    # The pinned configuration and compute units, read back from the real binary at the call site in main.swift (a
    # unit test can only read Pinned, not what main.swift hands the manager). For pyannote FluidAudio logs how many
    # 10 s windows it ran: with the pinned step ratio 0.1 that is one per second of audio, with the library's
    # default (0.2) one per two seconds (swapping in `OfflineDiarizerConfig()` gave 90 windows on the 180 s clip
    # instead of 180). The expected count is computed from the clip, not from ox-diar. The nemotron units line is
    # logged after the load, read back from the loaded model's own configuration, so a loader handed other units
    # cannot write a clean line over a bad run; OX_DIAR_COMPUTE_UNITS=cpuOnly lowers what the run asks for.
    # Mutation: Sources/ox-diar/main.swift, `OfflineDiarizerManager(config: Pinned.config())` -> `OfflineDiarizerManager()`
    # -> RED (windows=90); `Pinned.mlConfiguration()` -> `MLModelConfiguration()` -> RED (compute units all);
    # Sources/OxDiarCore/Config.swift `effectiveUnits(env:)` -> `.all` -> RED (compute units all); the `computeUnits:`
    # argument of `Nemotron3Models.load` -> `.all` -> RED (the model reports the units Core ML was handed).
    def test_the_pinned_configuration_is_what_runs(self):
        if not CLIP:
            self.skipTest("no --clip")
        pcm = self.clip_pcm()
        seconds = os.path.getsize(pcm) / 2 / 16000
        r = diar(pcm, self.path("o.json"), "--models", MODELS)
        self.assertEqual(r.returncode, 0, r.stderr)
        if ENGINE == "pyannote":
            found = re.search(r"Segmentation timings: windows=(\d+)", r.stderr)
            self.assertIsNotNone(found, "FluidAudio no longer logs its window count: read it from somewhere else\n" + r.stderr[-400:])
            self.assertEqual(int(found.group(1)), math.ceil(seconds), "window step is not the pinned 0.1 of the 10 s window")
        want = "cpuOnly" if ENGINE == "nemotron" and os.environ.get("OX_DIAR_COMPUTE_UNITS") == "cpuOnly" else "cpuAndNeuralEngine"
        self.assertIn(f"compute units {want}\n", r.stderr)
        if want == "cpuAndNeuralEngine":
            # a run that fell back to the CPU must not read as a clean Neural Engine run
            self.assertNotIn("Neural Engine run failed", r.stderr)
            self.assertNotIn("cpu_fallback", self.load("o.json")["timing_s"])

    # OX_DIAR_COMPUTE_UNITS can only lower the nemotron units (CI runners have no Neural Engine). The units line
    # is logged after the load, read back from the loaded model, so a load that fails leaves no line; a stream that
    # fails after a good load has already written its Neural Engine line, and the cpuOnly retry then writes its own. The
    # second half asks for the Neural Engine on a machine that has it; on the CI VM that request is the failure
    # OX_DIAR_COMPUTE_UNITS exists to avoid, so it is skipped when the ambient run is the forced-CPU one.
    def test_nemotron_compute_units_follow_the_env(self):
        self.require_engine("nemotron")
        r = diar(self.silence(2), self.path("o.json"), "--models", MODELS,
                 env={"OX_DIAR_COMPUTE_UNITS": "cpuOnly"})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("compute units cpuOnly\n", r.stderr)
        if os.environ.get("OX_DIAR_COMPUTE_UNITS") == "cpuOnly":
            self.skipTest("the ambient run is the forced-CPU one; the Neural Engine request is what it avoids")
        r = diar(self.silence(2), self.path("o2.json"), "--models", MODELS,
                 env={"OX_DIAR_COMPUTE_UNITS": ""})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("compute units cpuAndNeuralEngine\n", r.stderr)
        self.assertNotIn("Neural Engine run failed", r.stderr)
        self.assertNotIn("cpu_fallback", self.load("o2.json")["timing_s"])

    # The stream's last feed chunk is the short one, and its speech must reach the timeline. The clip with a
    # 7 s cut of its own start appended is 187 s: six full 30 s chunks plus a 7 s tail.
    def test_the_truncated_final_chunk_is_not_dropped(self):
        self.require_engine("nemotron")
        if not CLIP:
            self.skipTest("no --clip")
        with wave.open(CLIP, "rb") as w:
            frames = w.readframes(w.getnframes())
        pcm = self.path("clip-tail.pcm")
        tail = frames[:7 * 16000 * 2]
        with open(pcm, "wb") as f:
            f.write(frames + tail)
        seconds = (len(frames) + len(tail)) // 2 / 16000
        r = diar(pcm, self.path("o.json"), "--models", MODELS)
        self.assertEqual(r.returncode, 0, r.stderr)
        d = self.load("o.json")
        self.assertAlmostEqual(d["duration_s"], seconds, places=2)
        last = max((g["e"] for g in d["segments"]), default=0)
        self.assertGreaterEqual(last, seconds - 0.5, "the speech in the tail chunk never reached the timeline")

    # An output path in a directory that does not exist is a failure before the run, not after twenty seconds of it.
    # Mutation: Sources/ox-diar/main.swift, delete the `guard FileManager.default.fileExists(atPath: outDir` check -> RED.
    def test_a_missing_output_directory_fails_before_the_run(self):
        if not CLIP:
            self.skipTest("no --clip")
        started = time.time()
        r = diar(self.clip_pcm(), self.path("nope/o.json"), "--models", MODELS)
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("output directory", r.stderr)
        self.assertLess(time.time() - started, 2, "the diarization ran before the output path was checked")

    # The audio of a call must never reach a temporary file: FluidAudio's file path streams it to a float32
    # `fluidaudio-streaming-*.raw` file in the user's temporary directory (about 230 MB per hour) and only a `defer`
    # removes it, so a killed process leaves someone's call outside the meeting directory and outside retention.
    # ox-diar reads the channel into memory instead. The test runs it to the end, and again with a SIGKILL a second in,
    # and watches the user's temporary directory (Foundation on macOS takes it from `confstr`,
    # `getconf DARWIN_USER_TEMP_DIR`, not from $TMPDIR, so pointing TMPDIR elsewhere would protect nothing; both are
    # watched) with `TempWatch` above. Why it looks at CONTENT: the first version flagged every new top-level entry,
    # the second every entry outside `com.apple.*` or over a size floor, and system daemons broke both
    # (`com.apple.inputanalyticsd`, `ScopedBookmarkAgent`, `Maps.mapssyncd`, then `tipsd`'s 49 KB
    # `CFNetworkDownload_*.tmp` and `duetexpertd` on the hosted macos-15 VM). A file is suspect only when it holds
    # bytes of the clip itself, as int16 or float32; see the comment on `audio_signatures` for what that cannot see.
    # The test's own scratch directory is excluded (it holds the legitimate PCM copy of the clip).
    # Mutation: Sources/ox-diar/main.swift, write the samples to a WAV beside the output and replace
    # `manager.process(audio: samples)` with `manager.process(thatURL)` -> RED (the killed run leaves its stream file);
    # `StubWritesAudio` below proves the same through this very method with a stub binary.
    def test_no_audio_reaches_the_temporary_directory(self):
        if not CLIP:
            self.skipTest("no --clip")
        tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True, check=True).stdout.strip()
        watched = {os.path.realpath(tmp)}
        if os.environ.get("TMPDIR"):
            watched.add(os.path.realpath(os.environ["TMPDIR"]))
        pcm = self.clip_pcm()
        with open(pcm, "rb") as f:
            sigs = audio_signatures(f.read())
        self.assertTrue(sigs, "the clip has no non-silent window to look for: this test would pass without checking anything")
        watch = TempWatch(sorted(watched), sigs, exclude=[self.tmp.name])
        env = dict(os.environ)
        env.pop("OX_DIAR_ASSUME_MACOS", None)
        for kill_after in (None, 1.0):
            proc = subprocess.Popen([BIN, pcm, self.path("o.json"), "--models", MODELS, "--engine", ENGINE], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            started = time.time()
            while proc.poll() is None:
                watch.poll()
                if kill_after is not None and time.time() - started > kill_after:
                    proc.kill()
                    proc.wait()
                    break
                time.sleep(0.005)
            watch.poll()
            self.assertEqual(sorted(watch.suspects.items()), [],
                             f"ox-diar left audio-suspect files in {sorted(watched)} (kill_after={kill_after})")


class StubWritesAudio(unittest.TestCase):
    """The REAL test method above, run against a stub `--bin` that does what the old FluidAudio path did: write a float32
    copy of the PCM into the user's temporary directory, under a name nothing filters on, and delete it when it exits
    normally. The method must fail on its first assertion, "ox-diar left audio-suspect files", though the file is gone
    by the time the run ends. Needs no models and no ox-diar build."""

    WRITER = (
        "#!/usr/bin/env python3\n"
        "import os, struct, subprocess, sys, time\n"
        "tmp = subprocess.run(['getconf', 'DARWIN_USER_TEMP_DIR'], capture_output=True, text=True).stdout.strip()\n"
        "pcm = open(sys.argv[1], 'rb').read()\n"
        "path = os.path.join(tmp, 'ox-diar-oracle-stub-%d.raw' % os.getpid())\n"
        "with open(path, 'wb') as f:\n"
        "    f.write(struct.pack('<%df' % (len(pcm) // 2), *[s / 32768 for s in struct.unpack('<%dh' % (len(pcm) // 2), pcm)]))\n"
        "time.sleep(1.5)\n"
        "os.remove(path)\n"
    )
    IDLE = "#!/bin/sh\nsleep 1.5\n"

    def run_real_method(self, stub_source):
        global BIN, CLIP
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        clip = os.path.join(tmp.name, "clip.wav")
        with wave.open(clip, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(synthetic_clip(3, seed=9, silent_seconds=1))
        stub = os.path.join(tmp.name, "stub")
        with open(stub, "w") as f:
            f.write(stub_source)
        os.chmod(stub, 0o755)
        was = BIN, CLIP
        BIN, CLIP = stub, clip
        case = Contract("test_no_audio_reaches_the_temporary_directory")
        case.setUp()
        try:
            case.test_no_audio_reaches_the_temporary_directory()
        finally:
            BIN, CLIP = was
            case.tmp.cleanup()
            tdir = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
            for n in os.listdir(tdir):
                if n.startswith("ox-diar-oracle-stub-"):
                    os.remove(os.path.join(tdir, n))  # a stub that was killed leaves its file: this test cleans up after it

    def test_a_float32_copy_deleted_at_exit_fails_the_real_test(self):
        with self.assertRaises(AssertionError) as caught:
            self.run_real_method(self.WRITER)
        self.assertIn("ox-diar left audio-suspect files", str(caught.exception))
        self.assertIn("kill_after=None", str(caught.exception))

    def test_a_stub_that_writes_nothing_passes_the_real_test(self):
        self.run_real_method(self.IDLE)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--models", required=True)
    ap.add_argument("--clip")
    ap.add_argument("--speakers", type=int, default=0)
    ap.add_argument("--engine", default="nemotron", choices=["pyannote", "nemotron"])
    a, rest = ap.parse_known_args()
    BIN, MODELS, CLIP, SPEAKERS, ENGINE = a.bin, a.models, a.clip, a.speakers, a.engine
    unittest.main(argv=[sys.argv[0], *rest])
