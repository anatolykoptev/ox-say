# Licenses
ox-say's own code is Apache-2.0 (see `LICENSE`; `NOTICE` carries the
required third-party notices). The engines it builds are MIT:

- qwentts.cpp, with the ServeurpersoCom fork of ggml;
- whisper.cpp, with its vendored ggml;
- cpp-httplib and yyjson, vendored by qwentts.cpp;
- llama.cpp (the `ox-llm` meeting-notes engine), with its own ggml.

The optional VoxCPM2 engine, [audio.cpp](https://github.com/ShugoAI/audio.cpp), is Apache-2.0 (ShugoAI LLC)
with its own vendored dependencies; `NOTICE` lists our patches to it. The speaker engine `ox-diar` is built on
[FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0, Fluid Inference).

`engine/build.sh` copies all their license files next to the binaries.
`engine/patches/` modify ggml and qwentts.cpp: our lines are Apache-2.0,
and the upstream lines they contain stay MIT. The test clips in
`engine/align/testdata/` are LibriSpeech, CC-BY-4.0 (see its README).

`scripts/fetch-models.sh` downloads the model weights from Hugging Face.
They are GGUF conversions of the publishers' weights, each under the
publisher's license:

- Qwen3-TTS 12 Hz talker and tokenizer: Apache-2.0 (Qwen team, Alibaba)
- VoxCPM2 (optional): Apache-2.0 (OpenBMB); the GGUF conversion comes from audio.cpp. The model
  card forbids impersonation, fraud and disinformation and asks that AI-generated speech be labelled
- parakeet-ultra q8_0 (speech-to-text, default): CC-BY-4.0 — Moondream's
  post-trained parakeet-tdt-0.6b-v3 (NVIDIA, same licence); attribute NVIDIA
  and Moondream when you redistribute the weights. The ggml conversion is ours
  (`engine/stt/convert/`, Apache-2.0; its PROVENANCE.md records the bytes),
  published at Koptev/parakeet-ultra-ggml. On our evals it beat the previous
  default, NVIDIA v3's q8_0 (CC-BY-4.0, the ggml-org conversion — still usable
  through `OX_SAY_STT_MODEL`): accented-English WER 18.85% → 16.53%, native
  5.03% → 4.89%, Russian 1.46% → 0.97%, at about the same speed and size
  (669 MB)
- parakeet-ultra f16 (speech-to-text, optional): the same model and licence as the q8_0 file above, unquantised
  (1.26 GB), published in the same repo. Opt in with `OX_SAY_STT_MODEL` or
  `scripts/fetch-models.sh --with-parakeet-f16` (see [Configuration](configuration.md#parakeet-ultra-f16)). On our
  synthetic Russian-accented English set its WER is 15.67% against 16.53% for q8_0 (paired bootstrap −0.86 points,
  95% interval −1.57 to −0.26); native English and Russian are unchanged, and it is about twice as slow per clip
- Whisper large-v3-turbo (optional): MIT (OpenAI)
- Qwen3.5-9B and Qwen3.5-4B Q4_K_M, the meeting-notes models (downloaded on first use of notes): Apache-2.0
  (Qwen team, Alibaba), the GGUF conversions by Unsloth
- Huihui-Qwen3.8-27B-abliterated UD Q5_K_XL, the optional uncensored notes model: Apache-2.0, the GGUF conversion
  by huihui-ai (an abliterated Qwen3.8 derivative)
- Nemotron 3 Diarization fast128 Core ML models for `ox-diar`: OpenMDW License 1.1
  (NVIDIA, converted to Core ML by Fluid Inference; `NOTICE` has the full credit)
- Forced aligner for `ox-align` (optional, converted by hand, see
  `engine/README.md`): the MMS-300m forced-aligner weights are CC-BY-NC-4.0,
  **non-commercial**; `facebook/wav2vec2-base-960h` is Apache-2.0
