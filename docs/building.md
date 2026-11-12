# Build and install the engine
Requirements: macOS 14.2 or later on Apple Silicon, or on an Intel Mac with AVX2; Xcode command line tools, CMake, ffmpeg.

```
engine/build.sh                # pinned clone + patches + static Metal build
scripts/install-engine.sh      # -> ~/Library/Application Support/ox-say/engine
scripts/fetch-models.sh        # pinned GGUF weights, SHA-256 verified
```

The first start of a freshly built engine compiles the Metal shaders
(about a minute on a Radeon Pro 5500M); macOS caches them afterwards.

