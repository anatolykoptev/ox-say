# Engines and platforms

Local speech for **Macs** — natively on Apple Silicon's GPU, and on Intel Macs' AMD GPU:
- text-to-speech with voice cloning;
- speech-to-text with word timestamps;
- dictation: hold ⌃Space (⌥Space when ⌃Space is taken) in any app, speak,
  and the text is typed where the cursor is (a menu-bar app, see [Dictation](dictation.md));
- meetings: record a call (both sides), get a transcript, notes and the other people's voices told
  apart, all on the Mac (see [Meetings](meetings.md)).

The engine build also produces `ox-align`, a wav2vec2 tool that emits
per-frame CTC emissions — the first phase of a forced aligner (see
[engine/README.md](../engine/README.md)); the daemon, CLI and MCP expose no
alignment.

It is one small daemon with an OpenAI-compatible HTTP API, an MCP server for coding agents, and a
`say`-like CLI. There is no Python, no PyTorch, no Electron and no cloud.


## What it does
| | Engine | On a Radeon Pro 5500M | On an Apple M5 Pro |
|---|---|---|---|
| Text-to-speech, voice cloning from a short clip | Qwen3-TTS 12 Hz via [qwentts.cpp](https://github.com/ServeurpersoCom/qwentts.cpp) | faster than real time (about 0.6× RTF), first audio in about 110–250 ms | faster than real time (about 0.22× RTF), first audio byte in about 30–35 ms (Qwen3-TTS 1.7B: 0.27–0.28× RTF) |
| Studio-quality voiceover with emotion, voice design and loudness control (opt-in, Apple Silicon, see [Studio voice](studio-voice.md)) | VoxCPM2 via [audio.cpp](https://github.com/ShugoAI/audio.cpp) | not available | about real time (0.58× RTF warm), 48 kHz |
| Speech-to-text with word timestamps | Parakeet TDT v3 (25 European languages) or Whisper large-v3-turbo (99 languages) via whisper.cpp | 5 minutes of audio in about 27 s on the CPU, which the Intel daemon uses for its resident server (about 12.5 s on Metal while the GPU is free) | 6 minutes of audio in about 2.5 s on Metal |
| Meetings: call recording, transcript, structured notes, far-side speakers (see [Meetings](meetings.md)) | Parakeet TDT v3 for the transcript, Qwen3.5-4B via llama.cpp (`ox-llm`) for the notes, FluidAudio / Nemotron 3 Diarization on Core ML (`ox-diar`) for the voices | transcript and notes; notes run on the CPU and are slow, voices are not told apart | transcript, notes and voices |
| `ox-align` engine tool: per-frame CTC emissions for a wav2vec2 checkpoint ([engine/README.md](../engine/README.md)) — not exposed by the daemon | optional hand-converted GGUF (the MMS aligner weights are CC-BY-NC; the installer fetches none) | emissions match the transformers oracle within tolerance | not measured |

Apple Silicon numbers: [docs/performance.md](performance.md).

## Intel Macs and Apple Silicon
The modern local speech stacks have left Intel Macs behind:
- PyTorch stopped publishing macOS x86_64 wheels after 2.2.
- MLX runs only on Apple Silicon.
- [VoiceStudio's install guide](https://github.com/debpalash/VoiceStudio/blob/main/docs/install/macos.md)
  states that its local backend cannot run on Intel Macs.
- Stock ggml gives wrong results on discrete, non-unified-memory Metal GPUs.

ox-say carries the fixes (`engine/patches/ggml`, see [engine/README.md](../engine/README.md)). It
builds static binaries, so a 2019–2020 MacBook Pro with a Radeon Pro 5300M/5500M/5600M runs
current speech models on its GPU.

On Apple Silicon the same engines build natively for arm64 and run on Metal. The GPU shares the
Mac's memory, so the TTS engine and speech-to-text run on it side by side, with no lease
(`OX_SAY_GPU_MEMORY`, see [Usage](usage.md)). The ggml patches are carried there too; on unified
memory they are inert or plain bug fixes ([engine/README.md](../engine/README.md#apple-silicon)).
Measurements: [docs/performance.md](performance.md).

ox-say itself is Apache-2.0, and the default models are Apache-2.0 and CC-BY-4.0 (see
[Licenses](licenses.md)).

## Status
- Engines: pinned upstream plus patches, static `tts-server`, `ox-stt`, `ox-align` and `ox-llm`
  (the meeting-notes model server), verified on a Radeon Pro 5500M and an Apple M5 Pro. Speaker
  diarization (`ox-diar`) is a separate Core ML engine for Apple Silicon.
- Daemon, CLI and MCP server: `cmd/ox-say`.
- Menu-bar app (`app/dictation`): dictation, speak selection, Studio and Meetings, with a main window for
  recordings, settings and voices.
- Releases: one macOS package per architecture, `ox-say-macos-arm64.tar.gz` (built on GitHub's
  `macos-15` runner) and `ox-say-macos-x86_64.tar.gz` (built on `macos-15-intel`), with one combined
  `SHA256SUMS`. `get.sh` picks the package for the hardware it runs on; a release cut before the
  arm64 package existed has no arm64 asset, and `get.sh` then says so.

