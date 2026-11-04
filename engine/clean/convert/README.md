# MossFormer2_SE_48K -> Core ML converter (build-time only)

Converts the pinned PyTorch checkpoint into the Core ML model `ox-clean` loads at runtime.
Python exists only here and never at user runtime; the output is uploaded to the HF model
repo (`Koptev/mossformer2-se-48k-coreml`) at release time, not committed to git.

Design: fixed 20 s window, features `[1,2496,180]` -> mask `[1,2496,961]`; **mixed**
precision (an fp32 region selected by dataflow; pure fp16 returns an all-zero
mask); **cpuAndGPU only** — on cpuOnly the Core ML CPU fp16 runtime renders the first
~64 frames of each window as garbage on macOS 26.5.1 (measured 2026-11-03 on an M5 Pro:
cpuOnly mask MSE 5.5e-3 against 3.5e-8 on cpuAndGPU).

## Pins

`coremltools==9.0` (latest stable, 2025-11-10); its `_deps/__init__.py` caps torch at
`_TORCH_MAX_VERSION = "2.7.0"`, so `torch==2.7.0`/`torchaudio==2.7.0`/`torchvision==0.22.0`
is the tested trio. Pin reason: latest stable, except torch, capped at coremltools 9.0's
tested maximum (2.7.0); a newer torch can silently mis-convert. `clearvoice==0.1.2`, `numpy==1.26.4`, Python 3.12.
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

A conversion is a multi-GB job (torch plus the model), so run these commands one at a time and
at low priority (`nice -n 15`). `CKPT` is the pinned checkpoint from HF
`alibabasglab/MossFormer2_SE_48K` at revision `eff8c97925c8bec812af707814b3e5d777fd4503`
(`last_best_checkpoint.pt` or its directory; both files' SHA-256 are verified — ClearVoice would
otherwise download unpinned weights):

```
CKPT=/path/to/checkpoints/MossFormer2_SE_48K/last_best_checkpoint.pt
nice -n 15 .venv/bin/python -B convert.py --checkpoint "$CKPT" --out out
nice -n 15 .venv/bin/python -B verify.py out --checkpoint "$CKPT"
```

`convert.py` writes `MossFormer2_SE_48K.mlpackage` (the source of truth),
`MossFormer2_SE_48K.mlmodelc/`, `manifest.json`, `config.json` and `reference_window.bin`.
`verify.py` gates the artifact that ships: it checks the SHA-256 of `weights/weight.bin` inside the
`.mlmodelc` and inside the `.mlpackage` against the manifest, prints the cpuAndGPU known-answer
result for the compiled `.mlmodelc` (loaded through `CompiledMLModel`) and for the `.mlpackage`
(both gated, and the two masks must agree), the cpuOnly line (reported, never gated), the
stored-mask-vs-PyTorch check and two seeded fixture windows (run on the `.mlmodelc`). The known-answer
check passes only at mask MSE <= 1e-4 AND p99.9 <= 0.05 AND no NaN (`known_answer_ok` in
`verify.py`; the engine applies the same rule). A fixture passes only on grade PASS: WARN is
printed as WARN and makes the exit code non-zero. Exit 1 on a gated FAIL or WARN, 2 on
integrity/usage errors. `verify.py` needs both the `.mlmodelc` and the `.mlpackage`.

## Tests

```
OX_CLEAN_CHECKPOINT="$CKPT" nice -n 15 .venv/bin/python -B -m pytest test_convert.py
```

Thirteen tests: the pinned checkpoint hash, manifest shape/precision + 125 MiB budget + verify,
byte-reproducibility of `weight.bin`, `verify.py` exiting 1 on a model built with
`--mask-gain 2.0` (the test hook), the manifest's recorded SHA-256 of the reference, the
1e-4 MSE limit (stored mask + uniform noise) and the p99.9 rule (stored mask x0.9), no conversion, the
`known_answer_ok` rule, `read_reference` rejecting a truncated or mis-sized file, verify failing on a
stale or corrupted `.mlmodelc` next to a good `.mlpackage` (no conversion), and `load_net` taking a
relative checkpoint directory and removing its staging directory.
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
  the compile fails after ~20 min and falls back with 0 ops on the ANE).
- The fixture windows are seeded synthetic signals, not real speech. verify generates its own; they cover the conversion,
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
| `verify.py` | the conversion gate + the engine's known-answer check |
| `test_convert.py` | the suite above |
| `probe.swift` | the native speed / MLComputePlan op-share probe |
| `requirements.in`, `requirements.lock` | the pinned venv |
