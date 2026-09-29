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
- Daemon, CLI and MCP server: `cmd/ox-say`.

## Usage

One binary, `ox-say`, is the daemon, the CLI client and the MCP server.

```
ox-say serve        # run the daemon (launchd starts this)
ox-say say hello                        # speak like `say`
ox-say say -v ben -l Russian -f mp3 -o hi.mp3 "privet"
echo piped | ox-say say                 # text from stdin
ox-say voice add ben ./clip.wav --ref-text "what the clip says"
ox-say voice ls
ox-say voice rm ben
ox-say transcribe meeting.wav           # speech-to-text
ox-say transcribe -e whisper --srt talk.mp4 > talk.srt
ox-say status
```

The daemon owns the `tts-server` child process: it starts the engine on the
first request, stops it after `OX_SAY_IDLE_STOP_SECS` (default 300 s) of
idleness so it does not hold ~2 GB of GPU memory, restarts it after a crash
with backoff, and replays persisted voices into every fresh child.

Speech-to-text runs the separate `ox-stt` child on demand (no resident
process): ffmpeg first normalizes the input to 16 kHz mono WAV, then
Parakeet TDT (default, 25 European languages, auto-detected) or Whisper
large-v3-turbo (99 languages, takes `language`/`prompt` hints) transcribes
it. One transcription runs at a time; while the TTS engine is starting or
ready it holds ~2 GB of GPU memory, so ox-stt automatically runs on the CPU
(`OX_SAY_STT_GPU` overrides). The rule is one-way: a TTS request that starts the
engine while a transcription runs on the GPU is not held back, so the two can
briefly share the card. Transcriptions run one at a time; up to 8 more wait,
further ones get 503.

### HTTP API

Listening on `OX_SAY_ADDR` (default `127.0.0.1:8094`, loopback only):

| Route | Description |
|-------|-------------|
| `POST /v1/audio/speech` | OpenAI-compatible TTS. `input` required; `voice`, `language`, `response_format` (`wav`, `pcm`, `mp3`, `opus` — last two transcoded with ffmpeg), `instructions`, `seed`, `temperature`, `top_k`, `top_p`, `repetition_penalty`, `max_new_tokens` |
| `POST /v1/audio/transcriptions` | OpenAI-compatible STT, multipart: `file` (required, ≤ `OX_SAY_STT_MAX_UPLOAD_MB`), `model` (`parakeet` default; `whisper`/`whisper-1`), `language`, `prompt`, `response_format` (`json` default → `{"text"}`; `text`; `verbose_json` → OpenAI's shape: `duration`, `segments` (`start`/`end`), `words` (`word`/`start`/`end`); `srt`; `vtt`; `ox_json` → ox-stt's own result with words as `w`/`s`/`e`/`p`, what `ox-say transcribe --json` prints), `timestamp_granularities[]` (accepted; words are always returned). Errors: 400 bad input, 413 over the upload cap, 503 model missing or queue full, 504 timeout |
| `GET /v1/audio/voices` | List persisted voices |
| `POST /v1/audio/voices` | `{"name","audio_path","ref_text"}` — clone from a local clip (normalized to 24 kHz mono WAV, max 20 s) |
| `GET /v1/audio/voices/<name>` | Voice metadata |
| `DELETE /v1/audio/voices/<name>` | Remove a voice |
| `GET /status` | Engine state, pid, uptime, restarts, voices, config |
| `GET /health` | Daemon liveness (always 200; engine may be stopped) |

### MCP

The same server exposes MCP tools on `/mcp`: `speak`, `transcribe`,
`voices_list`, `voice_add`, `voice_remove`, `engine_status`. Register with:

```
claude mcp add --transport http --scope user ox-say http://127.0.0.1:8094/mcp
```

### Configuration

Environment variables (flags on `serve` override them):

| Variable | Default | Notes |
|----------|---------|-------|
| `OX_SAY_HOME` | `~/Library/Application Support/ox-say` | Engine, models, voices, run dir |
| `OX_SAY_ADDR` | `127.0.0.1:8094` | Daemon listen address; loopback only, refused otherwise |
| `OX_SAY_ENGINE_PORT` | `8095` | Loopback port for the engine child |
| `OX_SAY_ENGINE_BIN` | `$OX_SAY_HOME/engine/tts-server` | |
| `OX_SAY_MODEL` | `$OX_SAY_HOME/models/qwen-talker-0.6b-base-Q8_0.gguf` | |
| `OX_SAY_CODEC` | `$OX_SAY_HOME/models/qwen-tokenizer-12hz-F32.gguf` | |
| `OX_SAY_MAX_BATCH` | `2` | |
| `OX_SAY_IDLE_STOP_SECS` | `300` | Stop the idle engine after N s; 0 = never |
| `OX_SAY_STARTUP_TIMEOUT_SECS` | `180` | Covers the first-start Metal shader compile |
| `OX_SAY_LANG` | empty | Default language; empty = engine auto-detect |
| `OX_SAY_ENGINE_LOG_DIR` | `~/Library/Logs/ox-say` | Child stdout/stderr go to `engine.log` here |
| `OX_SAY_CACHE_DIR` | `~/Library/Caches/ox-say` | Default output dir for `speak` |
| `OX_SAY_STT_BIN` | `$OX_SAY_HOME/engine/ox-stt` | Speech-to-text binary |
| `OX_SAY_STT_MODEL` | `$OX_SAY_HOME/models/ggml-parakeet-tdt-0.6b-v3-f16.bin` | Parakeet weights |
| `OX_SAY_STT_WHISPER_MODEL` | `$OX_SAY_HOME/models/ggml-large-v3-turbo.bin` | Whisper weights (`--with-whisper` fetch) |
| `OX_SAY_STT_GPU` | `auto` | `auto`: CPU while the TTS engine runs, GPU otherwise; `on`/`off` force |
| `OX_SAY_STT_TIMEOUT_SECS` | `600` | Per-transcription cap (conversion + engine) |
| `OX_SAY_STT_MAX_UPLOAD_MB` | `200` | `file` part cap on the transcriptions route |
| `OX_SAY_STT_MAX_AUDIO_SECS` | `14400` | Longer audio is refused with 400, not cut (a small compressed upload can expand to hours of PCM) |

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

ox-say is MIT. The engines are qwentts.cpp (MIT) and whisper.cpp (MIT), both
with ggml (MIT); `engine/build.sh` copies their license files next to the
binaries. `scripts/fetch-models.sh` downloads model weights from their
publishers, each under its own license:

- Qwen3-TTS 12 Hz talker and tokenizer: Apache-2.0 (Qwen team, Alibaba)
- Parakeet TDT 0.6B v3: CC-BY-4.0 (NVIDIA); attribute NVIDIA when you
  redistribute the weights
- Whisper large-v3-turbo (optional): MIT (OpenAI)
