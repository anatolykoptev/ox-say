# MossFormer2_SE_48K -> Core ML converter (build-time only)

Converts the pinned PyTorch checkpoint into the Core ML model `ox-clean` loads at runtime.
Python exists only here and never at user runtime; the output is uploaded to the HF model
repo (`Koptev/mossformer2-se-48k-coreml`) by the controller, not committed to git.

Design: fixed 20 s window, features `[1,2496,180]` -> mask `[1,2496,961]`; **mixed**
precision (the spike's fp32 region selected by dataflow; pure fp16 returns an all-zero
mask); **cpuAndGPU only** — on cpuOnly the Core ML CPU fp16 runtime renders the first
~64 frames of each window as garbage on macOS 26.5.1 (Task 0b report). Evidence:
`~/deploy/krolik-server/reports/ox-say/mossformer2-coreml-{spike,0b-20s}-2026-11-03.md`.

## Pins

`coremltools==9.0` (latest stable, 2025-11-10); its `_deps/__init__.py` caps torch at
`_TORCH_MAX_VERSION = "2.7.0"`, so `torch==2.7.0`/`torchaudio==2.7.0`/`torchvision==0.22.0`
is the tested trio — the written exception to "latest stable" (Global Constraint 9):
a newer torch can silently mis-convert. `clearvoice==0.1.2`, `numpy==1.26.4`, Python 3.12.
The PyTorch reference runs in the same venv, so the pair under test is the pair that ships.
`requirements.lock` is `uv pip compile --generate-hashes` output (hashes included);
`requirements.in` documents the intent and the regeneration command.

## Set up

```
cd engine/clean/convert
uv venv .venv --python 3.12
uv pip install --python .venv/bin/python -r requirements.lock
```

## Convert + verify

Every command that loads torch or the model is a heavy ML job: run it ONE at a time under
the shared suite lock. `CKPT` is the pinned checkpoint (`last_best_checkpoint.pt` or its
directory; both files' SHA-256 are verified — ClearVoice would otherwise download unpinned
weights):

```
CKPT=~/Developer/ashaki-video/tools/models/clearvoice/checkpoints/MossFormer2_SE_48K/last_best_checkpoint.pt
/usr/bin/lockf -k -t 3600 ~/tmp/.ox-say-suite.lock nice -n 15 \
    .venv/bin/python -B convert.py --checkpoint "$CKPT" --out out
/usr/bin/lockf -k -t 3600 ~/tmp/.ox-say-suite.lock nice -n 15 \
    .venv/bin/python -B verify.py out --checkpoint "$CKPT"
```

`convert.py` writes `MossFormer2_SE_48K.mlpackage` (the source of truth),
`MossFormer2_SE_48K.mlmodelc/`, `manifest.json`, `config.json` and `reference_window.bin`.
`verify.py` prints the cpuAndGPU known-answer result (gated), the cpuOnly line (reported,
never gated), the stored-mask-vs-PyTorch check and two seeded fixture windows; it exits 1
on a gated FAIL and 2 on integrity/usage errors.

## Tests

```
OX_CLEAN_CHECKPOINT="$CKPT" /usr/bin/lockf -k -t 3600 ~/tmp/.ox-say-suite.lock nice -n 15 \
    .venv/bin/python -B -m pytest test_convert.py
```

Five tests: the pinned checkpoint hash, manifest shape/precision + 125 MiB budget + verify,
byte-reproducibility of `weight.bin`, `verify.py` exiting 1 on a model built with
`--mask-gain 2.0` (the test hook), and the manifest's recorded SHA-256 of the reference.
`OX_CLEAN_MODEL_DIR=<dir>` re-runs the read-only tests against a prebuilt directory.

`probe.swift` is the native speed/op-share probe (build `swiftc -O -o /tmp/mf2-probe probe.swift`,
run `WIN_S=20 NEW_S=15 /tmp/mf2-probe out/MossFormer2_SE_48K.mlmodelc FEATS.f32 cpuAndGPU 20`;
FEATS is the raw float32 feature window — bytes 24..1797144 of `reference_window.bin`).

## What the output can and cannot be trusted for

- Trusted: the known-answer check (features -> mask MSE <= 1e-4) on cpuAndGPU, and the
  fixture-window parity vs the fp32 PyTorch reference on this machine.
- `verify.py` compares against the stored reference mask AND freshly computed PyTorch
  masks; a model that only replays the stored mask without the net is not what ships.
- NOT covered: Intel (disabled, unverified), macOS < 26, other chips, the ANE (never use:
  the compile fails after ~20 min).
- The fixture windows are seeded synthetic signals, not real speech. Until Task 4's
  `engine/clean/testdata/` exists, verify generates its own; they cover the conversion,
  not the Swift feature front end.
- Byte-reproducibility of `weight.bin` is checked by the suite; if it ever fails,
  PROVENANCE.md states "not byte-reproducible; the published SHA-256 is authoritative".

## Files

| File | Role |
|---|---|
| `convert.py` | loads the pinned net (SHA-256 checked), applies `patches.py`, traces `[1,2496,180]`, converts to mlprogram, compiles `.mlmodelc`, writes the known-answer reference, `manifest.json`, `config.json` |
| `patches.py` | module surgery: `no_rotary_cache`, `negative_pad`, `einsum_as_matmul`, `mixed_selector` (the fp32 region) — the Apache-2.0 §4(b) change list |
| `reference.py` | ClearVoice loading (SHA-256-verified checkpoint), Kaldi fbank + deltas, the seeded synthetic window, the `reference_window.bin` format (`MF2REF01` + dims + raw f32) |
| `metrics.py` | `si_sdr`, `mask_stats`, the pre-registered PASS/WARN/FAIL graders |
| `verify.py` | the Task 1 gate + the engine's known-answer check |
| `test_convert.py` | the suite above |
| `probe.swift` | the native speed / MLComputePlan op-share probe |
| `requirements.in`, `requirements.lock` | the pinned venv |
