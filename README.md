# ox-say

Local text-to-speech for Intel Macs, built for machines with a discrete AMD
GPU (MacBook Pro 2019 class, Radeon Pro 5300M/5500M/5600M). It runs the
Qwen3-TTS 12 Hz models through [qwentts.cpp](https://github.com/ServeurpersoCom/qwentts.cpp)
on Metal: about 0.55x real time on a Radeon Pro 5500M, first audio in about
100 ms, voice cloning from a short reference clip.

Upstream ggml does not run correctly on discrete (non-unified-memory) Metal
GPUs. `engine/patches/ggml` carries the fixes; see [engine/README.md](engine/README.md).

## Status

- Engine: pinned upstream + patches, static `tts-server`, verified on a
  Radeon Pro 5500M.
- Daemon, CLI and MCP server: in progress.

## Build and install the engine

Requirements: macOS on x86_64, Xcode command line tools, CMake, ffmpeg.

```
engine/build.sh                # pinned clone + patches + static Metal build
scripts/install-engine.sh      # -> ~/Library/Application Support/ox-say/engine
scripts/fetch-models.sh        # pinned GGUF weights, SHA-256 verified
```

The first start of a freshly built engine compiles the Metal shaders
(about a minute on a Radeon Pro 5500M); macOS caches them afterwards.

## Licenses

ox-say is MIT. The engine is qwentts.cpp (MIT) with ggml (MIT); the model
weights are Qwen3-TTS (Apache-2.0).
