# PROVENANCE

How this Core ML build of `MossFormer2_SE_48K` was produced, so the hosted bytes can be
rebuilt and checked.

## Source

- **Weights:** `alibabasglab/MossFormer2_SE_48K` on Hugging Face, revision
  `eff8c97925c8bec812af707814b3e5d777fd4503` (26 Nov 2024). Files:
  - `last_best_checkpoint.pt` — SHA-256 `03692b9f773bbd6bb43b9c5a41f96b1e28affd66e13796b7bec66ad3d8b227c6`
  - `last_best_checkpoint` — SHA-256 `315744c841441f8831cb2f896e06102b4d864776bf272febaa30c639c903e1c0`
- **Network code:** `clearvoice==0.1.2` (ClearerVoice-Studio) exactly as its loader runs it;
  the converter applies `engine/clean/convert/patches.py` as module surgery, never edits the
  installed package.

## Converter

- Repo `anatolykoptev/ox-say`, `engine/clean/convert/`. The build ran on the
  Task-1 working tree on top of commit `ffbb45a` (field `converter` in
  `manifest.json`); the converter source itself lands in the commit that adds
  this file.
- Command: `convert.py --checkpoint last_best_checkpoint.pt --out out` (default
  `--precision mixed`).
- Environment: Python 3.12, `coremltools==9.0`, `torch==2.7.0`, `torchaudio==2.7.0`,
  `torchvision==0.22.0`, `clearvoice==0.1.2`, `numpy==1.26.4` — the full pinned set is
  `engine/clean/convert/requirements.lock` (`uv pip compile --generate-hashes`; the
  torch 2.7.0 pin follows coremltools 9.0's `_TORCH_MAX_VERSION`, the written exception
  to "latest stable").
- Host: Apple M5 Pro, macOS 26.5.1, `xcrun coremlcompiler` of the installed Xcode CLT.

## Produced bytes (SHA-256)

Build of 2026-11-03, `out/` (`.mlmodelc` total 119,512,598 bytes):

| file | SHA-256 |
|---|---|
| `MossFormer2_SE_48K.mlmodelc/analytics/coremldata.bin` | `cfc2c9d7fafd2605981d9460da2bd45538adcfaf891717b320c40c69c198464e` |
| `MossFormer2_SE_48K.mlmodelc/coremldata.bin` | `3ad172aeee2bf3cf6107b4e3fefcfbdd13c18197fd298660e683950435a52235` |
| `MossFormer2_SE_48K.mlmodelc/metadata.json` | `795e65fd7adda75bfe4e62912c899592a0ece1c45b19beb4a39468a622c34b9b` |
| `MossFormer2_SE_48K.mlmodelc/model.mil` | `6db168e889ed29a8c36c4fd9429872cf1a01b241368af0f5e33baa853c8141f5` |
| `MossFormer2_SE_48K.mlmodelc/weights/weight.bin` | `a240669911aade7aa87991de27e09d0c3d56d7d9fa491a7df180725fe3250446` |
| `MossFormer2_SE_48K.mlpackage/Data/com.apple.CoreML/model.mlmodel` | `0d3b8944992631c500d116adbdde961d1f95eaee85f87313d20fd77a730692ac` |
| `MossFormer2_SE_48K.mlpackage/Data/com.apple.CoreML/weights/weight.bin` | `a240669911aade7aa87991de27e09d0c3d56d7d9fa491a7df180725fe3250446` |
| `MossFormer2_SE_48K.mlpackage/Manifest.json` | `aa41a8e60934c7f9f58ef82aff1892061cc3ead2a65f17a3c41c72d3992e498c` |
| `config.json` | `714759a5eb1f13ccdef2a1127dc8ce8b10c9374decfe89b9aceb1bdca451ee7b` |
| `manifest.json` | `ebeee9345315036223abba5356a02c1255f4b9089102c93ee12fc970a704fa01` |
| `reference_window.bin` | `29fcb372069103a8337c0e19e32f2e983bc709ea45185a662213a26ee7435beb` |

## Gate results at build time

- `verify.py` on this build: cpuAndGPU known-answer **PASS** (mask MSE 3.456e-08
  vs the stored reference; both seeded fixtures PASS at ~2-4e-08); cpuOnly reported
  as the known defect (MSE 5.532e-03, not supported, never gated).
- Byte-reproducibility of `weight.bin` across two conversions: **yes** —
  `test_conversion_is_reproducible` runs `convert.py` twice and compares SHA-256
  of `weights/weight.bin` (it does not compare `Manifest.json`/`model.mlmodel`,
  which may embed build metadata).
- Parity and speed evidence (Task 0b, same conversion recipe and selector):
  `~/deploy/krolik-server/reports/ox-say/mossformer2-coreml-0b-20s-2026-11-03.md`.
