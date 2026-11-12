# Configuration
Environment variables (flags on `serve` override them):

| Variable | Default | Notes |
|----------|---------|-------|
| `OX_SAY_HOME` | `~/Library/Application Support/ox-say` | Engine, models, voices, run dir |
| `OX_SAY_ADDR` | `127.0.0.1:8094` | Daemon listen address; loopback only, refused otherwise |
| `OX_SAY_ENGINE_PORT` | `8095` | Loopback port for the engine child |
| `OX_SAY_ENGINE_BIN` | `<engine dir>/tts-server` | |
| `OX_SAY_MODEL` | `$OX_SAY_HOME/models/qwen-talker-0.6b-base-Q8_0.gguf` | |
| `OX_SAY_CODEC` | `$OX_SAY_HOME/models/qwen-tokenizer-12hz-F32.gguf` | |
| `OX_SAY_MAX_BATCH` | `2` | |
| `OX_SAY_TTS_MODEL` | `qwen3-tts` | Engine for a speech request that names no model and whose voice has no preference: `qwen3-tts` or `voxcpm2` |
| `OX_SAY_VOXCPM2_BIN` | `<engine dir>/audiocpp_server` | The VoxCPM2 engine (audio.cpp's server); Apple Silicon only |
| `OX_SAY_VOXCPM2_MODEL` | `$OX_SAY_HOME/models/voxcpm2-q8_0.gguf` | VoxCPM2 weights (`OX_SAY_WITH_VOXCPM2=1` fetch) |
| `OX_SAY_VOXCPM2_PORT` | `8097` | Loopback port the VoxCPM2 child binds |
| `OX_SAY_NOTES_BIN` | `<engine dir>/ox-llm` | The meeting-notes engine (llama.cpp's llama-server); on the GPU with unified memory (Apple Silicon), on the CPU otherwise |
| `OX_SAY_NOTES_MODEL` | unset (the catalog decides) | The operator's notes-model pin: an absolute path to a `.gguf`, written by the installer. It wins over the user's saved choice in every case. A file name the catalog knows (`Qwen3.5-9B-Q4_K_M.gguf`, `Qwen3.5-4B-Q4_K_M.gguf`, `Huihui-Qwen3.8-27B-abliterated-UD-Q5_K_XL.gguf`) pins that model; any other path is the user's own file — reported as `custom`, never downloaded over and never deleted by ox-say. Unset, the model is the saved choice or the automatic pick (see [Meetings](meetings.md)) |
| `OX_SAY_NOTES_PORT` | `8098` | Loopback port the notes engine binds. Set explicitly, it must differ from the other listeners or the daemon refuses to start; left at the default, a collision turns notes off (`port_blocked` in `/status`) and the rest of the daemon runs |
| `OX_SAY_NOTES_IDLE_STOP_SECS` | `120` | Stop the notes engine after N s idle |
| `OX_SAY_ASSUME_MEMORY_GB` | unset | Test and diagnostic knob. Makes the daemon decide as if the Mac had N GB for ONE thing: whether the large engines (fast voice, studio voice, notes model) take turns, which they do on Apple Silicon below 24 GB (`/status` `memory_mode` is `one_large_engine`, otherwise `shared`). It does not change the memory gates: the studio voice and the notes model still read the real memory. Use it to exercise the turn-taking on a bigger Mac |
| `OX_SAY_DIAR_BIN` | `<engine dir>/ox-diar` | The speaker diarization engine (meeting voices); Apple Silicon, macOS 15 or later |
| `OX_SAY_DIAR_ENGINE` | `nemotron` | Which model separates the voices of a meeting: `nemotron` (Nemotron 3 Diarization fast128 on the Neural Engine) or `pyannote` (the previous pipeline, kept until it is removed). Case and surrounding spaces do not matter; a value that is neither is logged once and the default is used. A Mac whose engine set is not fetched keeps one far-side label (`models_missing`) until `scripts/fetch-models.sh` has run; `nemotron` takes calls up to 6 hours, `pyannote` up to 2. The app records up to 6 hours (a minute less) on either; on `pyannote` a recording over 2 hours keeps one far-side label. `GET /status` shows the engine in use as `config.diar_engine` |
| `OX_SAY_CLEAN_BIN` | `<engine dir>/ox-clean` | The voice-cleanup engine (MossFormer2 on Core ML); its model set (131 MB) is downloaded on first use |
| `OX_SAY_IDLE_STOP_SECS` | `300` | Stop the idle engine after N s; 0 = never |
| `OX_SAY_STARTUP_TIMEOUT_SECS` | `180` | Covers the first-start Metal shader compile |
| `OX_SAY_LANG` | empty | Default language; empty = engine auto-detect |
| `OX_SAY_SEED` | empty | Default seed (0 to 4294967295) for a speech request that passes none, so the voice stays the same between requests; a `seed` in the request wins; empty = every request draws its own |
| `OX_SAY_ENGINE_LOG_DIR` | `~/Library/Logs/ox-say` | Child stdout/stderr go to `engine.log` here |
| `OX_SAY_CACHE_DIR` | `~/Library/Caches/ox-say` | Default output dir for `speak` |
| `OX_SAY_PRODUCE_OUT_DIR` | `~/Movies/ox-say` | Where `produce` publishes a finished voiceover when the request names no `out_path` (provisional default, pending the owner) |
| `OX_SAY_STT_BIN` | `<engine dir>/ox-stt` | Speech-to-text binary |
| `OX_SAY_STT_MODEL` | `$OX_SAY_HOME/models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin` | Parakeet weights |
| `OX_SAY_STT_VAD_MODEL` | `$OX_SAY_HOME/models/ggml-silero-v5.1.2.bin` | Silero VAD model; enables the streaming session routes when present at STT-server spawn |
| `OX_SAY_STT_WHISPER_MODEL` | `$OX_SAY_HOME/models/ggml-large-v3-turbo.bin` | Whisper weights (`--with-whisper` fetch) |
| `OX_SAY_STT_GPU` | `auto` | CLI device under the shared GPU lease: `auto` = GPU only for audio ≤ 5 min while the lease is free (TTS engine down, no GPU run in flight), else CPU (-ng); `on` = GPU whenever the lease is free, any length, else CPU (never waits); `off` forces CPU. With a discrete card the resident server is always CPU-only; with unified memory `auto`/`on` put the server and the CLI on the GPU and `off` puts both on the CPU |
| `OX_SAY_GPU_MEMORY` | `auto` | `auto` = `unified` on Apple Silicon, `discrete` elsewhere. `unified`: TTS and STT share the GPU with no lease. `discrete`: the GPU lease and the CPU-only resident STT server described above |
| `OX_SAY_STT_TIMEOUT_SECS` | `600` | Fixed part of the per-transcription budget: it bounds the HTTP upload and the ffmpeg conversion, and the engine run gets this base plus k×audio duration (k ≈ 0.5 s/s parakeet, 3 s/s whisper — ≥3× the measured CPU rates, GPU runs reuse them). An explicit value is a floor, not a hard cap. At most 86400 |
| `OX_SAY_STT_MAX_UPLOAD_MB` | `200` | `file` part cap on the transcriptions route |
| `OX_SAY_STT_MAX_AUDIO_SECS` | `14400` | Longer audio is refused with 400, not cut (a small compressed upload can expand to hours of PCM). At most 86400 |
| `OX_SAY_STT_SERVER` | `on` | Resident `ox-stt --serve` for parakeet clips ≤ 300 s; `off` = per-call CLI only |
| `OX_SAY_STT_PORT` | `8096` | Loopback port the STT server binds; must differ from `OX_SAY_ENGINE_PORT` and the daemon's port |
| `OX_SAY_STT_IDLE_STOP_SECS` | `600` | Stop the STT server after N s idle; its idle cost is RAM, not VRAM |

`<engine dir>` is the directory of the running daemon when it sits in an app
bundle's `Contents/Helpers`, so the engines travel with the daemon and share
its version; anywhere else it is `$OX_SAY_HOME/engine`. A user-set
`OX_SAY_ENGINE_BIN`, `OX_SAY_STT_BIN`, `OX_SAY_VOXCPM2_BIN`,
`OX_SAY_NOTES_BIN` or `OX_SAY_DIAR_BIN` overrides that for one engine and
defeats the co-versioning, and the installer carries such a variable over from
the installed agent. `GET /status` shows the path each engine resolved to
under `config` (`engine_bin`, `stt_bin`, `voxcpm2_bin`, `notes_bin`,
`diar_bin`) and the diarization engine in use (`diar_engine`).

