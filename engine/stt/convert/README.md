# parakeet-ultra -> ggml converter (build-time only)

Rebuilds `ggml-parakeet-ultra-q8_0.bin` — the weights `ox-stt` loads at runtime — from the
published upstream files. Python exists only here and never at user runtime; the output is
uploaded to the HF model repo (`Koptev/parakeet-ultra-ggml`), not committed to git.
`PROVENANCE.md` records the sources, the exact commands and the SHA-256 of the produced bytes;
`manifest.json` and the model card live in the HF repo, not here.

Pipeline: `hf2nemo.py` rewrites moondream's HF-transformers checkpoint back into a NeMo-shaped
`.nemo` archive (a pure key rename; the six `vad_head.*` tensors are dropped, featurizer,
config and tokenizer come from NVIDIA's v3 archive), then whisper.cpp's own
`convert-parakeet-to-ggml.py --use-f32` and `parakeet-quantize` write the ggml file — both
unmodified, at the whisper.cpp commit `build.sh` pins.

## Set up

Run `build.sh` in an empty scratch directory (it downloads ~3.8 GB of inputs and clones and
builds whisper.cpp):

```
bash engine/stt/convert/build.sh
```

Needs Python 3.12 with torch, safetensors, numpy and PyYAML; git, cmake, a C++ toolchain and
the `hf` CLI. The build ran with torch 2.15.0, safetensors 0.8.0, numpy 2.5.5, PyYAML 6.0.3.

## Files

| File | Role |
|---|---|
| `hf2nemo.py` | HF safetensors -> `.nemo`: applies transformers' own NeMo->HF key mapping (Apache-2.0, inverted in-process) to the v3 archive's tensor names, f16->f32 cast, drops `vad_head.*` |
| `build.sh` | the pinned commands of the 2026-11-18 build, reconstructed from its logs |
| `verify_manifest.py` | re-hashes every file listed in `manifest.json` (the HF repo's manifest) |
| `PROVENANCE.md` | sources, converter pins, produced-byte SHA-256s and the checks that ran |
| `LICENSE` | Apache-2.0 for the scripts in this directory |
