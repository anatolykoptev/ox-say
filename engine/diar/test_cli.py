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
import os
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
        d = self.path("m")
        os.makedirs(d)
        os.symlink(os.path.join(MODELS, "speaker-diarization"), os.path.join(d, "speaker-diarization"))
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

    # The audio of a call must never reach a temporary file: FluidAudio's file path streams it to a float32
    # `fluidaudio-streaming-*.raw` file in the user's temporary directory (about 230 MB per hour) and only a `defer`
    # removes it, so a killed process leaves someone's call outside the meeting directory and outside retention.
    # ox-diar reads the channel into memory instead. The test runs it to the end, and again with a SIGKILL a second in,
    # and looks for new `fluidaudio*` files in that directory. (Foundation on macOS takes that directory from
    # `confstr` (`getconf DARWIN_USER_TEMP_DIR`), not from $TMPDIR, so pointing TMPDIR elsewhere would protect nothing.)
    # Mutation: Sources/ox-diar/main.swift, write the samples to a WAV beside the output and replace
    # `manager.process(audio: samples)` with `manager.process(thatURL)` -> RED (the killed run leaves its stream file).
    def test_no_audio_reaches_the_temporary_directory(self):
        if not CLIP:
            self.skipTest("no --clip")
        tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True, check=True).stdout.strip()
        mine = lambda: {n for n in os.listdir(tmp) if n.startswith("fluidaudio")}
        before = mine()
        pcm = self.clip_pcm()
        env = dict(os.environ)
        env.pop("OX_DIAR_ASSUME_MACOS", None)
        for kill_after in (None, 1.0):
            proc = subprocess.Popen([BIN, pcm, self.path("o.json"), "--models", MODELS], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            started = time.time()
            seen = set()
            while proc.poll() is None:
                seen |= mine() - before
                if kill_after is not None and time.time() - started > kill_after:
                    proc.kill()
                    proc.wait()
                    break
                time.sleep(0.005)
            self.assertEqual(seen | (mine() - before), set(), f"ox-diar wrote audio to {tmp} (kill_after={kill_after})")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--models", required=True)
    ap.add_argument("--clip")
    ap.add_argument("--speakers", type=int, default=0)
    a, rest = ap.parse_known_args()
    BIN, MODELS, CLIP, SPEAKERS = a.bin, a.models, a.clip, a.speakers
    unittest.main(argv=[sys.argv[0], *rest])
