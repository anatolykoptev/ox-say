# PROVENANCE

How `ggml-parakeet-ultra-q8_0.bin` was produced, so the bytes can be rebuilt and checked. Build
date 2026-11-18 (inputs downloaded 08:47 UTC, outputs written 08:55-08:56 UTC).

## Sources

| input | where | revision | SHA-256 |
|---|---|---|---|
| ultra weights | `moondream/parakeet-ultra` `model.safetensors` (1,255,353,386 bytes; 729 tensors: 356 F16, 349 F32, 24 I64) | `73175eb7aeb0d82f1e2a6b53b3aabc10a90bcd0b` (last modified 2026-09-23) | `c9608f36d0ab956c14bfcc525479b0746b3b42a56f6949ec85c14eb7466717dc` |
| ultra config | same repo, `config.json` | same | `e747b85e1bdfd300c8b8ac63bac8dd5221f8fe9bc275b48d06c735fcd6971b6e` |
| ultra tokenizer | same repo, `tokenizer.json` | same | `bd321b096832a3f270bd3b2a88823957920f1a5c5ada71114a26ea729d0cbe91` |
| v3 NeMo archive | `nvidia/parakeet-tdt-0.6b-v3` `parakeet-tdt-0.6b-v3.nemo` (2,509,332,480 bytes) | `541d1f99c6b0c3cd0b11a95167540bb8edefd82b` (last modified 2026-08-05) | `3cbdc85877e668ca7b82d0d56770eb1fac76691f55d6b97545e8d61ca588d10d` |
| v3 HF weights | same repo, `model.safetensors` (723 tensors) | same | `3a2026366188c8c68598edbbff92f8d11590a08e0ae2e6775544e7b07d6a5e11` |
| v3 config, tokenizer | same repo, `config.json`, `tokenizer.json` | same | identical SHA-256 to the two ultra files above |

Revisions come from the Hugging Face download cache metadata of the downloaded files
(`.cache/huggingface/download/*.metadata`); on 2026-11-18 both were also the current `main` of their
repositories according to the Hub API. The 723 v3 tensors and the 723 non-`vad_head` ultra tensors
have the same names.

## Converter

- Scripts: `convert/hf2nemo.py` (ours), then whisper.cpp's own `models/convert-parakeet-to-ggml.py`
  and `parakeet-quantize`, both unmodified. `convert/build.sh` lists the commands.
- whisper.cpp commit `6e4ab854f67f743900934a703d5603419384c961` (2026-09-28, "cli : fix incorrect
  error code when files are failing (#4080)"). It is **not** a release tag: it is 182 commits after
  `v1.9.4` and 142 commits before `v1.9.5` (`d1be6fde11ac6e0407606b4e42fe72d34add8037`). GitHub's
  compare of this commit with `v1.9.5` lists no change to `models/convert-parakeet-to-ggml.py`,
  `examples/parakeet-quantize/` or the CPU quantization code in `ggml/`; it lists `src/parakeet.cpp`
  as modified with 0 added and 0 removed lines (a mode change or an unrendered diff; not inspected).
  Whether v1.9.5 gives the same bytes was not rebuilt.
- The whisper.cpp checkout used had uncommitted edits, all under `ggml/src/ggml-metal/` (OxSay's Metal
  patches). `parakeet-quantize` was built with `GGML_METAL=OFF` (CPU-only), so they were not compiled in.
- `hf2nemo.py` applies transformers' own NeMo-to-HF key mapping (tables from
  `convert_nemo_to_hf.py` at transformers commit `f36c750069f0aef45179207a680b592f138450ec`, Apache-2.0)
  to the 723 NeMo tensor names of the v3 archive, asserts the mapping is injective, and inverts
  it. The mapping is a rename only. ultra's 356 float16 tensors are cast to float32 (exact). The six
  `vad_head.*` tensors have no destination and are dropped. `featurizer.fb`, `featurizer.window`,
  `model_config.yaml` and the tokenizer files stay those of the v3 archive. The resulting archive has 725
  tensors (723 + the two featurizer tensors), which is what the whisper.cpp converter reports loading.
- Steps and arguments (reconstructed from the logs, see `convert/build.sh`): `hf2nemo.py` →
  `convert-parakeet-to-ggml.py --use-f32` → `parakeet-quantize <f32> <out> q8_0`. The converter's
  default is float16; `--use-f32` is what keeps the 349 float32 ultra tensors from being rounded.
  The quantizer log lists 721 tensors, 273 of them written as `q8_0`, 448 kept as `f32`.
- Environment (read from the virtualenv that sat beside the build, not from a record of the run):
  Python 3.12.15, torch 2.15.0, safetensors 0.8.0, numpy 2.5.5, PyYAML 6.0.3.
- Host: MacBook Pro, Apple M5 Pro, 48 GB, macOS 26.5.1.

## Produced bytes (SHA-256)

| file | bytes | SHA-256 |
|---|---|---|
| `ggml-parakeet-ultra-q8_0.bin` (published) | 668,757,119 | `fa28ec8c6afd9893da9829ec9f2fa908a60bc0fbebd37fd60bbd2f0953076fb2` |
| `ultra-f32.bin` (intermediate, not published) | 2,508,463,079 | `53dcd33662d2cba5b88e84ff705f88a2292249dbdf379618e505ce296efdecd6` |

## Checks run on the build

1. **Round trip on v3 (an oracle the author did not choose).** The same pipeline, applied to NVIDIA's
   v3 *Hugging Face* weights instead of ultra's, was run through all three steps.
   - Its `f32` output is byte-identical to `ggml-parakeet-tdt-0.6b-v3-f32.bin` of
     `ggml-org/parakeet-GGUF`: SHA-256 `b17956ca991a7f084c978a8a9d4c9785864260b6dd9b72f884344759d913ae7f`
     on both sides.
   - Its `q8_0` output is byte-identical to `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` of the same repo:
     SHA-256 `4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e` (SHA-1
     `0271fffe0d96faa791d97348837857c9a0092b33`). The local files were hashed on 2026-11-18; the
     ggml-org values are the Hub's LFS object hashes for revision
     `35156454d1a39de06863303dd209fd2bed6ee079`.
2. **What the round trip cannot show.** ultra's six `vad_head.*` tensors and the float16-to-float32
   cast exist only on the ultra side, and moondream publishes no NeMo checkpoint of ultra to compare
   against. The cast is exact by construction and the dropped tensors are simply absent; the
   transcripts below are the remaining evidence that the weights landed in the right places.
3. **Known-answer run** on whisper.cpp's `samples/jfk.wav` with OxSay's `ox-stt` — see the model card
   and the `known_answer` entry of `manifest.json`.
4. **`convert/verify_manifest.py`** re-hashes every file listed in `manifest.json`.

## Not established

- Which ox-say commit the installed `ox-stt` binary (SHA-256
  `93eaf72b0db82306ce323bac3cac55ff18d25295b15dc26bda6f3fd149647bf7`, installed 2026-11-17) was
  built from.
- That the preprocessor of ultra equals v3's: moondream publishes no preprocessor configuration or
  filterbank, so v3's is assumed. The outputs are consistent with it; there is no direct proof.
- Behaviour with `parakeet-cli`: it was not built or run for this release.
- The exact shell history of the build (the commands in `convert/build.sh` are reconstructed).
