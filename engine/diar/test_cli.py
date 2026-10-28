#!/usr/bin/env python3
"""CLI contract of ox-diar: exit codes, the OS gate, the offline rule, the JSON.

Usage: test_cli.py --bin PATH --models DIR [--clip x.wav --speakers N] [unittest args]
  DIR holds speaker-diarization/ (scripts/fetch-models.sh --diar-only DEST, then DEST/diar).
  --clip is a 16 kHz mono WAV with --speakers voices (CI passes the AMI excerpt: 4); the test turns it into the raw
  s16le file ox-diar takes. Without it the tests that need a real recording are skipped and say so.
Needs no network and no Python packages. Mutation hooks: see the plan, Task 20a.
"""
import argparse
import json
import math
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


def run(*args, env=None):
    e = dict(os.environ)
    e.pop("OX_DIAR_ASSUME_MACOS", None)
    e.update(env or {})
    return subprocess.run([BIN, *args], capture_output=True, text=True, env=e, timeout=600)


# What may appear in the shared temporary directory while ox-diar runs without being its audio. macOS system daemons
# create their own per-daemon directories there at any moment: `com.apple.inputanalyticsd`,
# `com.apple.ScopedBookmarkAgent` and `com.apple.Maps.mapssyncd` all showed up in real CI runs (diar, macos-15) and
# failed a test that flagged every new entry. The rule: a new top-level entry is audio-suspect unless its name starts
# with `com.apple.` AND it holds no regular file of AUDIO_FLOOR bytes or more, found recursively. A killed FluidAudio
# stream file is float32 PCM, about 64 KB per second of 16 kHz audio, so 32 KB is half a second of it. Outside the
# `com.apple.` namespace the rule is name-agnostic, as before. What cannot be checked counts against the entry: a
# directory that cannot be listed under a `com.apple.` entry is suspect, and so is a file whose size cannot be read.
AUDIO_FLOOR = 32 * 1024
SYSTEM_PREFIX = "com.apple."


def audio_suspect(path):
    """Why `path` (a new top-level entry of a temporary directory) may hold audio, or None when it is a daemon's."""
    if not os.path.basename(path).startswith(SYSTEM_PREFIX):
        return f"{path}: a new entry outside {SYSTEM_PREFIX}*"
    pending = [path]
    while pending:
        p = pending.pop()
        try:
            st = os.lstat(p)  # lstat: a symlink is not followed, so one cannot hide or fake a big file
            if stat.S_ISDIR(st.st_mode):
                pending.extend(os.path.join(p, n) for n in os.listdir(p))
            elif stat.S_ISREG(st.st_mode) and st.st_size >= AUDIO_FLOOR:
                return f"{p}: a regular file of {st.st_size} bytes (floor {AUDIO_FLOOR})"
        except FileNotFoundError:
            continue  # the daemon removed it while we looked: nothing is left to hold audio
        except OSError as e:
            return f"{p}: cannot be inspected ({e.strerror}), so it cannot be shown to hold no audio"
    return None


class AudioSuspectRule(unittest.TestCase):
    """The classification above on fake trees; needs no models and no binary."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def make(self, rel, size=0):
        p = os.path.join(self.tmp.name, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(b"\0" * size)
        return os.path.join(self.tmp.name, rel.split("/")[0])

    def test_a_daemon_directory_with_small_files_passes(self):
        self.assertIsNone(audio_suspect(self.make("com.apple.inputanalyticsd/state.db", 4096)))
        self.assertIsNone(audio_suspect(self.make("com.apple.ScopedBookmarkAgent/a/b/c.plist", AUDIO_FLOOR - 1)))
        os.makedirs(os.path.join(self.tmp.name, "com.apple.Maps.mapssyncd"))
        self.assertIsNone(audio_suspect(os.path.join(self.tmp.name, "com.apple.Maps.mapssyncd")))

    def test_a_big_file_in_a_daemon_directory_fails_at_any_depth(self):
        self.assertIn("1048576", audio_suspect(self.make("com.apple.fake/x.bin", 1 << 20)))
        self.assertIsNotNone(audio_suspect(self.make("com.apple.deep/a/b/c/d.raw", AUDIO_FLOOR)))

    def test_a_big_daemon_file_directly_in_the_directory_fails(self):
        self.assertIsNotNone(audio_suspect(self.make("com.apple.loose", AUDIO_FLOOR)))

    def test_any_name_outside_the_system_namespace_fails_even_when_empty(self):
        self.assertIsNotNone(audio_suspect(self.make("fluidaudio-x.raw", 0)))
        self.assertIsNotNone(audio_suspect(self.make("apple.com.x/y", 1)))
        self.assertIsNotNone(audio_suspect(self.make("Com.apple.x/y", 1)))

    def test_an_unreadable_big_file_fails(self):
        d = self.make("com.apple.locked/big", AUDIO_FLOOR)
        os.chmod(os.path.join(d, "big"), 0)
        self.assertIsNotNone(audio_suspect(d))

    def test_an_unlistable_directory_fails(self):
        d = self.make("com.apple.sealed/inner/f", 1)
        os.chmod(os.path.join(d, "inner"), 0)
        self.addCleanup(os.chmod, os.path.join(d, "inner"), 0o700)
        self.assertIn("cannot be inspected", audio_suspect(d))

    def test_a_symlink_is_not_followed(self):
        big = self.make("outside.bin", AUDIO_FLOOR * 2)
        os.makedirs(os.path.join(self.tmp.name, "com.apple.link"))
        os.symlink(big, os.path.join(self.tmp.name, "com.apple.link", "l"))
        self.assertIsNone(audio_suspect(os.path.join(self.tmp.name, "com.apple.link")))

    def test_an_entry_that_vanished_passes(self):
        self.assertIsNone(audio_suspect(os.path.join(self.tmp.name, "com.apple.gone")))


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
        r = run(self.path("nope.pcm"), self.path("o.json"), "--models", MODELS)
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertFalse(os.path.exists(self.path("o.json")))
        open(self.path("empty.pcm"), "wb").close()
        r = run(self.path("empty.pcm"), self.path("o.json"), "--models", MODELS)
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertIn("no audio", r.stderr)

    # The OS gate sits before everything that touches FluidAudio, the input and the models. The variable can only
    # lower the version the gate sees: that is how CI on macOS 15 exercises the refusal.
    # Mutation: Sources/ox-diar/main.swift, delete the `if let why = Platform.refusal(version: version)` line -> RED
    # (the bogus input then gives exit 4, not 5).
    def test_macos_14_is_refused_before_anything_else(self):
        r = run(self.path("nope.pcm"), self.path("o.json"), "--models", self.path("no-models"),
                env={"OX_DIAR_ASSUME_MACOS": "14.8"})
        self.assertEqual(r.returncode, 5, r.stderr)
        self.assertIn("macOS 15", r.stderr)
        self.assertFalse(os.path.exists(self.path("o.json")))

    def test_the_assumed_version_cannot_lift_the_gate_over_a_real_one(self):
        r = run(self.path("nope.pcm"), self.path("o.json"), "--models", MODELS, env={"OX_DIAR_ASSUME_MACOS": "99"})
        self.assertEqual(r.returncode, 4, r.stderr)  # past the gate, stopped by the missing input

    # Offline: a directory without the models is exit 3 at once; FluidAudio would otherwise download.
    # Mutation: Sources/ox-diar/main.swift, delete `ModelHub.offlineMode = true` -> RED on a machine with a network
    # (it fetches ~20 MB and the test takes seconds, or exits 0), and unprovable without one.
    def test_missing_models_are_exit_3_and_never_a_download(self):
        started = time.time()
        r = run(self.silence(2), self.path("o.json"), "--models", self.path("empty"))
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertLess(time.time() - started, 20)
        fetched = [f for _, _, fs in os.walk(self.path("empty")) for f in fs]
        self.assertEqual(fetched, [], "nothing may be downloaded into the models directory")

    def test_a_directory_without_the_revision_marker_is_exit_3(self):
        # the marker lives inside the real directory; a copy of the tree without it is the failure we want
        copy = self.path("copy")
        subprocess.run(["ditto", os.path.join(MODELS, "speaker-diarization"), os.path.join(copy, "speaker-diarization")], check=True)
        os.remove(os.path.join(copy, "speaker-diarization", ".fluidaudio-revision"))
        r = run(self.silence(2), self.path("o.json"), "--models", copy)
        self.assertEqual(r.returncode, 3, r.stderr)

    def test_silence_is_an_empty_result_not_an_error(self):
        r = run(self.silence(12), self.path("o.json"), "--models", MODELS)
        self.assertEqual(r.returncode, 0, r.stderr)
        d = self.load("o.json")
        self.assertEqual((d["version"], d["speakers"], d["segments"]), (1, [], []))
        self.assertAlmostEqual(d["duration_s"], 12.0, places=2)
        self.assertEqual([n for n in os.listdir(self.tmp.name) if "part" in n.lower() or n.startswith(".")], [])

    def test_a_recording_gives_the_contract(self):
        if not CLIP:
            self.skipTest("no --clip")
        r = run(self.clip_pcm(), self.path("o.json"), "--models", MODELS)
        self.assertEqual(r.returncode, 0, r.stderr)
        d = self.load("o.json")
        self.assertEqual(sorted(d), ["duration_s", "segments", "speakers", "timing_s", "version"])
        self.assertEqual(len(d["speakers"]), SPEAKERS)
        self.assertEqual([s["id"] for s in d["speakers"]], list(range(SPEAKERS)), "ids are dense, as ParseDiarization needs")
        speech = [s["speech_s"] for s in d["speakers"]]
        self.assertEqual(speech, sorted(speech, reverse=True))
        for s in d["speakers"]:
            self.assertEqual(len(s["embedding"]), 256)
        prev_end = 0.0
        for seg in d["segments"]:
            self.assertGreater(seg["e"], seg["s"])
            self.assertGreaterEqual(seg["s"], prev_end - 1e-6, "exclusive timeline: no overlap")
            self.assertLess(seg["spk"], SPEAKERS)
            prev_end = seg["e"]
        for s in d["speakers"]:
            total = sum(g["e"] - g["s"] for g in d["segments"] if g["spk"] == s["id"])
            self.assertAlmostEqual(total, s["speech_s"], delta=0.01 * len(d["segments"]))

    # The pinned configuration and compute units, read back from the real binary at the call site in main.swift (a
    # unit test can only read Pinned, not what main.swift hands the manager). FluidAudio logs how many 10 s windows it
    # ran: with the pinned step ratio 0.1 that is one per second of audio, with the library's default (0.2) one per two
    # seconds (swapping in `OfflineDiarizerConfig()` gave 90 windows on the 180 s clip instead of 180). The
    # expected count is computed from the clip, not from ox-diar. The compute units are logged by main.swift from the
    # configuration it passes to the model loader.
    # Mutation: Sources/ox-diar/main.swift, `OfflineDiarizerManager(config: Pinned.config())` -> `OfflineDiarizerManager()`
    # -> RED (windows=90); `Pinned.mlConfiguration()` -> `MLModelConfiguration()` -> RED (compute units all).
    def test_the_pinned_configuration_is_what_runs(self):
        if not CLIP:
            self.skipTest("no --clip")
        pcm = self.clip_pcm()
        seconds = os.path.getsize(pcm) / 2 / 16000
        r = run(pcm, self.path("o.json"), "--models", MODELS)
        self.assertEqual(r.returncode, 0, r.stderr)
        found = re.search(r"Segmentation timings: windows=(\d+)", r.stderr)
        self.assertIsNotNone(found, "FluidAudio no longer logs its window count: read it from somewhere else\n" + r.stderr[-400:])
        self.assertEqual(int(found.group(1)), math.ceil(seconds), "window step is not the pinned 0.1 of the 10 s window")
        self.assertIn("compute units cpuAndNeuralEngine\n", r.stderr)

    # An output path in a directory that does not exist is a failure before the run, not after twenty seconds of it.
    # Mutation: Sources/ox-diar/main.swift, delete the `guard FileManager.default.fileExists(atPath: outDir` check -> RED.
    def test_a_missing_output_directory_fails_before_the_run(self):
        if not CLIP:
            self.skipTest("no --clip")
        started = time.time()
        r = run(self.clip_pcm(), self.path("nope/o.json"), "--models", MODELS)
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("output directory", r.stderr)
        self.assertLess(time.time() - started, 2, "the diarization ran before the output path was checked")

    # The audio of a call must never reach a temporary file: FluidAudio's file path streams it to a float32
    # `fluidaudio-streaming-*.raw` file in the user's temporary directory (about 230 MB per hour) and only a `defer`
    # removes it, so a killed process leaves someone's call outside the meeting directory and outside retention.
    # ox-diar reads the channel into memory instead. The test runs it to the end, and again with a SIGKILL a second in,
    # and classifies every new entry in that directory with `audio_suspect` above, and in $TMPDIR when that is a
    # different directory. (Foundation on macOS takes its temporary directory from `confstr`
    # (`getconf DARWIN_USER_TEMP_DIR`), not from $TMPDIR, so pointing TMPDIR elsewhere would protect nothing; both are
    # watched.) The rule is name-agnostic outside `com.apple.*` (a rename of FluidAudio's stream file, or another
    # library's copy, must not slip past a name filter) and size-aware inside it, because system daemons create their
    # own directories there while the test runs (`com.apple.inputanalyticsd`, `com.apple.ScopedBookmarkAgent`,
    # `com.apple.Maps.mapssyncd` in real CI runs). Entries are classified when first seen and again at the end.
    # Mutation: Sources/ox-diar/main.swift, write the samples to a WAV beside the output and replace
    # `manager.process(audio: samples)` with `manager.process(thatURL)` -> RED (the killed run leaves its stream file,
    # which is not `com.apple.*`).
    def test_no_audio_reaches_the_temporary_directory(self):
        if not CLIP:
            self.skipTest("no --clip")
        tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True, check=True).stdout.strip()
        watched = {os.path.realpath(tmp)}
        if os.environ.get("TMPDIR"):
            watched.add(os.path.realpath(os.environ["TMPDIR"]))
        mine = lambda: {os.path.join(d, n) for d in watched for n in os.listdir(d)}
        before = mine()
        verdicts = {}

        def judge(paths):
            for q in paths:
                if verdicts.get(q) is None:
                    verdicts[q] = audio_suspect(q)
        pcm = self.clip_pcm()
        env = dict(os.environ)
        env.pop("OX_DIAR_ASSUME_MACOS", None)
        for kill_after in (None, 1.0):
            proc = subprocess.Popen([BIN, pcm, self.path("o.json"), "--models", MODELS], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            started = time.time()
            while proc.poll() is None:
                judge(mine() - before)
                if kill_after is not None and time.time() - started > kill_after:
                    proc.kill()
                    proc.wait()
                    break
                time.sleep(0.005)
            judge(mine() - before)
            suspects = sorted(v for v in verdicts.values() if v)
            self.assertEqual(suspects, [], f"ox-diar left audio-suspect files in {sorted(watched)} (kill_after={kill_after})")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--models", required=True)
    ap.add_argument("--clip")
    ap.add_argument("--speakers", type=int, default=0)
    a, rest = ap.parse_known_args()
    BIN, MODELS, CLIP, SPEAKERS = a.bin, a.models, a.clip, a.speakers
    unittest.main(argv=[sys.argv[0], *rest])
