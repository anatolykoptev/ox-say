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
- Parakeet TDT 0.6B v3: CC-BY-4.0 (NVIDIA); attribute NVIDIA when you
  redistribute the weights. ox-say uses the q8_0 conversion. On 300 Russian
  and 300 English FLEURS test utterances its WER matched f16 (normalised:
  Russian 5.17% against 5.27%, English 6.00% against 6.03%; with case kept:
  6.81% against 6.84%, 8.13% against 8.15%) at about half the memory (669 MB
  against 1229 MB resident). The other 23 languages were not measured
- Whisper large-v3-turbo (optional): MIT (OpenAI)
- Qwen3.5-9B and Qwen3.5-4B Q4_K_M, the meeting-notes models (downloaded on first use of notes): Apache-2.0
  (Qwen team, Alibaba), the GGUF conversions by Unsloth
- Huihui-Qwen3.8-27B-abliterated UD Q5_K_XL, the optional uncensored notes model: Apache-2.0, the GGUF conversion
  by huihui-ai (an abliterated Qwen3.8 derivative)
- Core ML speaker models for `ox-diar`: CC-BY-4.0. They are Fluid Inference's conversions of
  pyannote's speaker-diarization-community-1 pipeline (pyannote segmentation, WeSpeaker ResNet34-LM embeddings,
  PLDA parameters from BUT Speech@FIT); attribute pyannote, WeSpeaker, BUT Speech@FIT and Fluid Inference when you
  redistribute them (`NOTICE` has the full credit)
- Nemotron 3 Diarization fast128 Core ML models for `ox-diar`'s Nemotron engine: OpenMDW License 1.1
  (NVIDIA, converted to Core ML by Fluid Inference; `NOTICE` has the full credit)
- Forced aligner for `ox-align` (optional, converted by hand, see
  `engine/README.md`): the MMS-300m forced-aligner weights are CC-BY-NC-4.0,
  **non-commercial**; `facebook/wav2vec2-base-960h` is Apache-2.0
