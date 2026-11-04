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

- Repo `anatolykoptev/ox-say`, `engine/clean/convert/`. The `converter` field of
  `manifest.json` is the commit that last touched that directory (`-dirty` if it had
  uncommitted changes). The bytes below were built from merge commit `35405748e0f22a8813cb7cb30410aca5b0b779c9`
  with a clean tree; the converter is at `3540574` (the `converter` field of `manifest.json`).
  Source fields stay the same: pinned weights, `patches.py` module surgery.
- Command: `convert.py --checkpoint last_best_checkpoint.pt --out out` (default
  `--precision mixed`).
- Environment: Python 3.12, `coremltools==9.0`, `torch==2.7.0`, `torchaudio==2.7.0`,
  `torchvision==0.22.0`, `clearvoice==0.1.2`, `numpy==1.26.4` — the full pinned set is
  `engine/clean/convert/requirements.lock` (`uv pip compile --generate-hashes`; the
  torch pin: latest stable, except torch, capped at coremltools 9.0's tested maximum (2.7.0)).
- Host: Apple M5 Pro, macOS 26.5.1, `xcrun coremlcompiler` of the installed Xcode CLT.

## Produced bytes (SHA-256)

Build of 2026-11-03, `out/` (`.mlmodelc` total 119,512,598 bytes):

| file | SHA-256 |
|---|---|
| `MossFormer2_SE_48K.mlmodelc/analytics/coremldata.bin` | `019a117d1b12476d342ce787954cd065e97d7977c8575b0b4a64ba1cd6f6a919` |
| `MossFormer2_SE_48K.mlmodelc/coremldata.bin` | `45f9c86c73f7e4fcb9eb552789bbdeb11274c9de235dd637bc018b1f8a6aa2a5` |
| `MossFormer2_SE_48K.mlmodelc/metadata.json` | `795e65fd7adda75bfe4e62912c899592a0ece1c45b19beb4a39468a622c34b9b` |
| `MossFormer2_SE_48K.mlmodelc/model.mil` | `6db168e889ed29a8c36c4fd9429872cf1a01b241368af0f5e33baa853c8141f5` |
| `MossFormer2_SE_48K.mlmodelc/weights/weight.bin` | `a240669911aade7aa87991de27e09d0c3d56d7d9fa491a7df180725fe3250446` |
| `MossFormer2_SE_48K.mlpackage/Data/com.apple.CoreML/model.mlmodel` | `ea95014826eb0951ae7908a7e8eae7ab14cda60df3ec027ecb57898a4ddd0d0e` |
| `MossFormer2_SE_48K.mlpackage/Data/com.apple.CoreML/weights/weight.bin` | `a240669911aade7aa87991de27e09d0c3d56d7d9fa491a7df180725fe3250446` |
| `MossFormer2_SE_48K.mlpackage/Manifest.json` | `be1decd4045d6973df013e961f9d050205bcf71c022a42dc964e40f590b67a16` |
| `config.json` | `639b015f07dda17e176b0c0473241bf507f8688127d52e681d6af0f44b373f0c` |
| `manifest.json` | `49e9ae2faabea3259737ea6b315d4558c27ff83af2580329c1ec855cd15a12bd` |
| `reference_window.bin` | `29fcb372069103a8337c0e19e32f2e983bc709ea45185a662213a26ee7435beb` |

## Gate results at build time

- `verify.py` on this build gates the shipped `.mlmodelc` (loaded through `CompiledMLModel`) and
  the `.mlpackage`, and checks both `weights/weight.bin` SHA-256 values against the manifest:
  cpuAndGPU known-answer **PASS** on each (mask MSE 3.456e-08 vs the stored reference; both seeded
  fixtures PASS at ~2-4e-08, run on the `.mlmodelc`); cpuOnly reported
  as the known defect (MSE 5.532e-03, not supported, never gated).
- Byte-reproducibility of `weight.bin` across two conversions: **yes** —
  `test_conversion_is_reproducible` runs `convert.py` twice and compares SHA-256
  of `weights/weight.bin` (it does not compare `Manifest.json`/`model.mlmodel`,
  which may embed build metadata).
- Parity and speed evidence (same conversion recipe and selector) is in the model card's
  Evaluation section.
