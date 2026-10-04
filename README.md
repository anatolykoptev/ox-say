# ox-say

Local speech for **Intel Macs**, running on their AMD GPU:
- text-to-speech with voice cloning;
- speech-to-text with word timestamps;
- dictation: hold ⌃Space in any app, speak, and the text is typed where the
  cursor is (a menu-bar app, see [Dictation](#dictation)).

The engine build also produces `ox-align`, a wav2vec2 tool that emits
per-frame CTC emissions — the first phase of a forced aligner (see
[engine/README.md](engine/README.md)); the daemon, CLI and MCP expose no
alignment.

It is one small daemon with an OpenAI-compatible HTTP API, an MCP server for coding agents, and a
`say`-like CLI. There is no Python, no PyTorch, no Electron and no cloud.

```sh
curl -fsSL https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh | sh
```

The installer:
- downloads a prebuilt release and checks its SHA-256;
- fetches the models (about 2.3 GB, checksummed; the optional Whisper adds 1.6 GB);
- starts the daemon as a LaunchAgent;
- registers the MCP server with Claude Code, if Claude Code is installed;
- runs a speak-and-transcribe self-test;
- installs the dictation app into `~/Applications` and starts it
  (`OX_SAY_NO_DICTATION=1` skips it).

It needs `ffmpeg` (`brew install ffmpeg`) and never uses `sudo`. To build from source instead, run
`scripts/install.sh` (it needs Xcode CLT, `go`, `cmake` and `ffmpeg`).

**Install through your coding agent.** Paste this into Claude Code, Codex or Cursor:

> Install ox-say on this Mac with `curl -fsSL https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh | sh`,
> then show me `ox-say status` and speak one sentence with `ox-say say`.

## What it does

| | Engine | On a Radeon Pro 5500M |
|---|---|---|
| Text-to-speech, voice cloning from a short clip | Qwen3-TTS 12 Hz via [qwentts.cpp](https://github.com/ServeurpersoCom/qwentts.cpp) | faster than real time (about 0.55× RTF), first audio in about 100 ms |
| Speech-to-text with word timestamps | Parakeet TDT v3 (25 European languages) or Whisper large-v3-turbo (99 languages) via whisper.cpp | 6 minutes of audio in about 18 s |
| `ox-align` engine tool: per-frame CTC emissions for a wav2vec2 checkpoint ([engine/README.md](engine/README.md)) — not exposed by the daemon | optional hand-converted GGUF (the MMS aligner weights are CC-BY-NC; the installer fetches none) | emissions match the transformers oracle within tolerance |

## Why Intel Macs

The modern local speech stacks have left Intel Macs behind:
- PyTorch stopped publishing macOS x86_64 wheels after 2.2.
- MLX runs only on Apple Silicon.
- [VoiceStudio's install guide](https://github.com/debpalash/VoiceStudio/blob/main/docs/install/macos.md)
  states that its local backend cannot run on Intel Macs.
- Stock ggml gives wrong results on discrete, non-unified-memory Metal GPUs.

ox-say carries the fixes (`engine/patches/ggml`, see [engine/README.md](engine/README.md)). It
builds static binaries, so a 2019–2020 MacBook Pro with a Radeon Pro 5300M/5500M/5600M runs
current speech models on its GPU.

ox-say itself is Apache-2.0, and the default models are Apache-2.0 and CC-BY-4.0 (see
[Licenses](#licenses)).

## Status

- Engines: pinned upstream plus patches, static `tts-server`, `ox-stt` and `ox-align`, verified on
  a Radeon Pro 5500M.
- Daemon, CLI and MCP server: `cmd/ox-say`.
- Releases: macOS x86_64 packages built on GitHub's Intel macOS runner (`get.sh`).

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

Speech-to-text is served by a resident `ox-stt --serve` child
(`OX_SAY_STT_SERVER=on`, the default): the daemon starts it on the first
parakeet request, it loads the model once and decodes 1 s of silence before
listening on `OX_SAY_STT_PORT`, and a warm transcription skips the
multi-second model load a per-call `ox-stt` pays every time. The server
runs on the CPU — spawned with `-ng` — so it never takes GPU memory from
the TTS engine; its idle cost is ~0.7 GB of RAM, and
`OX_SAY_STT_IDLE_STOP_SECS` (default 600 s) stops it when unused. When a
streaming session opens after a minute or more without a decode, the server
first decodes 1 s of silence on its worker, so a model the OS has paged out
pages back in while you speak rather than after you release the key. Parakeet
clips up to 300 s go to the server whatever the TTS state; a server failure
falls back to the per-call CLI, and audio longer than 300 s stays on the
CLI (a cancelled server decode cannot be killed the way a CLI child is).
Whisper always uses the CLI. When the silero VAD model
(`OX_SAY_STT_VAD_MODEL`) is present, the spawned server is passed `--vad`
and can also host streaming transcription sessions — the daemon proxies
them under `/v1/audio/transcriptions/sessions` (below).

The single GPU is arbitrated by a lease the daemon shares between the two
consumers. A per-call `ox-stt` that runs without `-ng` holds it for the
whole run, and a TTS engine start must wait for it before spawning — the
engine then keeps it until the child has actually exited, so the brief
window where the supervisor already reports stopped but the process is
still tearing down is covered too. On the CLI path `OX_SAY_STT_GPU=auto`
prefers CPU over contention — and caps how long it will hold the card: it
takes the lease only when free AND the decoded audio is at most 5 minutes,
so a `speak` that needs the engine mid-transcription waits out a short GPU
run at worst (the tool's timeout is about 5 minutes). Longer audio runs
with `-ng` without touching the lease. `on` lifts the length cap but,
like `auto`, only takes a free lease and otherwise runs on the CPU — a
transcription never waits for the GPU. With `on`, a `speak` that needs the
engine can wait out a long GPU run. `off` never touches the card. `OX_SAY_STT_GPU=on` no longer opts the resident server into the
GPU — a process that holds GPU memory for its whole lifetime cannot take
part in a per-run lease, so the server is always `-ng`. Transcriptions run
one at a time; up to 8 more wait, further ones get 503.

### HTTP API

Listening on `OX_SAY_ADDR` (default `127.0.0.1:8094`, loopback only):

| Route | Description |
|-------|-------------|
| `POST /v1/audio/speech` | OpenAI-compatible TTS. `input` required; `voice`, `language`, `response_format` (`wav`, `pcm`, `mp3`, `opus` — last two transcoded with ffmpeg), `instructions`, `seed`, `temperature`, `top_k`, `top_p`, `repetition_penalty`, `max_new_tokens` |
| `POST /v1/audio/transcriptions` | OpenAI-compatible STT, multipart: `file` (required, ≤ `OX_SAY_STT_MAX_UPLOAD_MB`), `model` (`parakeet` default; `whisper`/`whisper-1`), `language`, `prompt`, `response_format` (`json` default → `{"text"}`; `text`; `verbose_json` → OpenAI's shape: `duration`, `segments` (`start`/`end`), `words` (`word`/`start`/`end`); `srt`; `vtt`; `ox_json` → ox-stt's own result with words as `w`/`s`/`e`/`p`, what `ox-say transcribe --json` prints), `timestamp_granularities[]` (accepted; words are always returned). Errors: 400 bad input, 413 over the upload cap, 500 engine failure, 503 model missing or queue full, 504 timeout |
| `GET /v1/audio/voices` | List persisted voices |
| `POST /v1/audio/voices` | `{"name","audio_path","ref_text"}` — clone from a local clip (normalized to 24 kHz mono WAV, max 20 s) |
| `GET /v1/audio/voices/<name>` | Voice metadata |
| `DELETE /v1/audio/voices/<name>` | Remove a voice |
| `GET /status` | Engine and STT-server state, pids, uptime, restarts, voices, config |
| `GET /health` | Daemon liveness (always 200; engine may be stopped) |

Streaming transcription sessions — incremental decoding on the resident
`ox-stt --serve` (requires the VAD model; unavailable when it is absent or
`OX_SAY_STT_SERVER=off`):

| Route | Description |
|-------|-------------|
| `POST /v1/audio/transcriptions/sessions` | `{}` → `{"id":"<32 hex>"}`. 429 past 4 live sessions |
| `POST /v1/audio/transcriptions/sessions/<id>/audio` | `application/octet-stream` body: little-endian float32 mono PCM at 16 kHz, ≤ 30 s (1,920,000 bytes) per request → `{"segments","words","pending"}` with what was decoded since the previous call |
| `POST /v1/audio/transcriptions/sessions/<id>/finish` | Waits for pending decodes (up to ~60 s) → final `{"segments","words","done":true,"text"}`, then deletes the session |
| `DELETE /v1/audio/transcriptions/sessions/<id>` | Drop the session without finishing |

Session errors are `{"error":"…"}`:
- 400: an audio body that is not whole float32 samples, holds a non-finite sample, or cannot be read.
- 404: unknown session. This includes a server restart, since sessions do not survive one.
- 413: over the per-chunk cap, or a JSON body over 4 KB.
- 429: past 4 live sessions, or a decode backlog.
- 500: a segment failed to decode or VAD failed, so the session is unusable; or the server could not create a session.
- 501: no VAD model.
- 502: the STT server could not be reached.
- 503: the STT server is off or cooling down.
- 504: `finish` waited too long.

Requests the daemon's guard refuses (403, 415) keep its usual error
shape. On **any** non-200 response a client should keep its own copy of
the recording and fall back to uploading the whole clip to
`POST /v1/audio/transcriptions`.

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
| `OX_SAY_STT_MODEL` | `$OX_SAY_HOME/models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin` | Parakeet weights |
| `OX_SAY_STT_VAD_MODEL` | `$OX_SAY_HOME/models/ggml-silero-v5.1.2.bin` | Silero VAD model; enables the streaming session routes when present at STT-server spawn |
| `OX_SAY_STT_WHISPER_MODEL` | `$OX_SAY_HOME/models/ggml-large-v3-turbo.bin` | Whisper weights (`--with-whisper` fetch) |
| `OX_SAY_STT_GPU` | `auto` | CLI device under the shared GPU lease: `auto` = GPU only for audio ≤ 5 min while the lease is free (TTS engine down, no GPU run in flight), else CPU (-ng); `on` = GPU whenever the lease is free, any length, else CPU (never waits); `off` forces CPU. The resident server is always CPU-only |
| `OX_SAY_STT_TIMEOUT_SECS` | `600` | Fixed part of the per-transcription budget: it bounds the HTTP upload and the ffmpeg conversion, and the engine run gets this base plus k×audio duration (k ≈ 0.5 s/s parakeet, 3 s/s whisper — ≥3× the measured CPU rates, GPU runs reuse them). An explicit value is a floor, not a hard cap. At most 86400 |
| `OX_SAY_STT_MAX_UPLOAD_MB` | `200` | `file` part cap on the transcriptions route |
| `OX_SAY_STT_MAX_AUDIO_SECS` | `14400` | Longer audio is refused with 400, not cut (a small compressed upload can expand to hours of PCM). At most 86400 |
| `OX_SAY_STT_SERVER` | `on` | Resident `ox-stt --serve` for parakeet clips ≤ 300 s; `off` = per-call CLI only |
| `OX_SAY_STT_PORT` | `8096` | Loopback port the STT server binds; must differ from `OX_SAY_ENGINE_PORT` and the daemon's port |
| `OX_SAY_STT_IDLE_STOP_SECS` | `600` | Stop the STT server after N s idle; its idle cost is RAM, not VRAM |

## Dictation

`app/dictation` is a menu-bar app: hold ⌃Space, speak, release, and the text
appears where the cursor is, in any app. The daemon transcribes it, so nothing
leaves the Mac. While you speak, a pill at the bottom of the screen shows bars
that move with your voice; Esc cancels. The menu switches the key to ⌥Space and
turns on toggle mode (press to start, press again to stop).

`get.sh` installs it into `~/Applications`. To build it from source instead:

```
app/dictation/build.sh --install    # needs Xcode; installs ~/Applications/OxSayDictation.app
```

On first launch macOS asks for two permissions: the microphone, and
Accessibility, which lets the app paste into other apps. Without Accessibility
the text is left on the clipboard. The app pastes through the clipboard and puts
your previous clipboard back afterwards, unless something else changed the
clipboard in between. When a password field has focus, it does not paste at all
and leaves the text on the clipboard.

The app finds the daemon at the address the installer gave it (`OX_SAY_ADDR`
in the ox-say LaunchAgent), 127.0.0.1:8094 by default. When something goes
wrong, or the text could not be pasted, the pill says why for a few seconds.

The app streams the microphone into a transcription session while you speak.
Silero VAD cuts the stream at pauses of 400 ms or more, and force-cuts any
segment at 12 s, at the quietest point of its last second. Each segment is
decoded as soon as it closes. On release, only the open tail is left to decode:
the operator's own dictations measured 0.9 s from release to text when the tail
was short, and 2.1 s for an 11 s dictation with no pause long enough to cut.

Accuracy has a cost: segments decode without their neighbours. On FLEURS
utterances of 8 s or more (measured with the f16 model, before q8_0 became the
default), streaming came out 1.6 (Russian) and 2.5 (English) WER points worse
than decoding the whole recording, and punctuation can break at a join ([#88](https://github.com/anatolykoptev/ox-say/issues/88)). A
dictation shorter than 12 s with no long pause is one segment, so it is not
affected.

### Speak selection

The same app registers a macOS service, so selected text can be spoken in any
app: select text, open the right-click menu (or the app's menu) → Services →
**Speak Selection** («Озвучить выделенное»). The selection goes to the daemon's
`/v1/audio/speech`, and the synthesized wav plays through the app's audio
player — nothing leaves the Mac. While the daemon synthesizes, the pill reads
"Speaking…"; the first use after an engine stop waits out a cold start of
about 15 s. Once playback starts the pill turns into playback controls —
pause/resume, the position counter and stop.

The **Speak voice** submenu picks the voice: the engine's default or any cloned
voice registered on the daemon (`ox-say voice list`). A new request while one
is in flight supersedes it; a new playback stops the previous one.

The service registers when LaunchServices scans the app, so it appears after
the first launch of an updated build. Apps that do not hand their selection to
Services (some Electron apps) will not show the item.

### Diagnosing dictation

Three logs describe a dictation without recording what was said:

- **The app writes one line per dictation to the unified log:**

  ```
  /usr/bin/log show --last 1h --style compact --info \
    --predicate 'subsystem == "io.github.anatolykoptev.ox-say.dictation"'
  ```

  A line looks like this:
  `outcome=delivered path=stream recorded_s=11.30 release_to_text_ms=2057 tail_s=0.30 segments_before_release=0 session_create_ms=3`.
  - `path`: `stream`, `fallback` (the session failed and the recording was sent whole) or `one-shot`.
  - `tail_s`: audio not yet acknowledged when the key was released.
  - `session_create_ms`: time to open the session. It is large when the STT server had to start, and `none` when no session opened (the one-shot path, a failed create, or a create still in flight at release).

  In zsh, type `/usr/bin/log`: plain `log` is a shell builtin.
- **The daemon writes one line per closed segment to `~/Library/Logs/ox-say/ox-say.log`:**
  `msg="stt segment" session=<first 8 id chars> dur_s=… cut=pause|cap|finish min_p=… quiet_ms=…`.
  - `cut`: why the segment closed.
  - `min_p`: the lowest speech probability the VAD saw inside the segment.
  - `quiet_ms`: its longest quiet run. A string of `cut=cap` lines with a small `quiet_ms` means the pauses were too short to close a segment.
- **The STT server reports each pre-warm to `~/Library/Logs/ox-say/stt.log`:**
  `ox-stt: pre-warm after <N> s idle took <M> ms`. A resident model decodes that second in about 0.3 s; the higher M is above that, the more of the model had been paged out.

Releases ship the app signed with a Developer ID and notarized, so macOS keeps
its microphone and Accessibility permissions across updates. A build from
source is signed ad hoc unless `OX_SAY_SIGN_IDENTITY` names a Developer ID
identity: macOS then ties the permissions to the exact build and asks again
after every rebuild, and a stale entry in System Settings → Privacy & Security
→ Accessibility looks enabled but no longer applies (remove it and add the app
again). The same happens once when updating from ox-say 0.1.x, whose app was
signed ad hoc. See the header of `app/dictation/build.sh`.

## Install

Requirements: macOS on x86_64, Xcode command line tools, CMake, Go, ffmpeg
(`brew install cmake go ffmpeg`).

```
scripts/install.sh      # engines + models + ox-say + LaunchAgent, then waits for /health
claude mcp add --transport http --scope user ox-say http://127.0.0.1:8094/mcp
```

It installs `ox-say` into `~/.local/bin` (`OX_SAY_BINDIR` overrides; keep it on
your `PATH` for the CLI), the engines and models into
`~/Library/Application Support/ox-say`, logs into `~/Library/Logs/ox-say`, and
the LaunchAgent `io.github.anatolykoptev.ox-say`, which keeps `ox-say serve`
running. The agent is an Interactive launchd job: the daemon and its engines run at
an app's base CPU priority (31) instead of launchd's throttled default (20),
still below the app in front and the window server.
`OX_SAY_WITH_WHISPER=1 scripts/install.sh` also fetches Whisper
large-v3-turbo.

launchd does not read your shell environment: set any `OX_SAY_*` configuration
(see below) when you run the installer, e.g.
`OX_SAY_IDLE_STOP_SECS=600 scripts/install.sh`, and it is written into the
LaunchAgent. Path settings must be absolute. Re-running the installer upgrades
in place; settings of the installed agent carry over unless you set them again
(an empty value drops one). The `ox-say` CLI reads `OX_SAY_ADDR` from your shell,
so export it there too if you installed the daemon on a custom address.

`~/Library/Application Support/ox-say/uninstall.sh` (installed there by the
release installer; in a source checkout it is `scripts/uninstall.sh`) removes
the agent, the binary and the dictation app, and keeps engines, models and
voices; `--purge` removes those too. Undo the MCP registration with
`claude mcp remove --scope user ox-say`.

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

ox-say's own code is Apache-2.0 (see `LICENSE`; `NOTICE` carries the
required third-party notices). The engines it builds are MIT:

- qwentts.cpp, with the ServeurpersoCom fork of ggml;
- whisper.cpp, with its vendored ggml;
- cpp-httplib and yyjson, vendored by qwentts.cpp.

`engine/build.sh` copies all their license files next to the binaries.
`engine/patches/` modify ggml and qwentts.cpp: our lines are Apache-2.0,
and the upstream lines they contain stay MIT. The test clips in
`engine/align/testdata/` are LibriSpeech, CC-BY-4.0 (see its README).

`scripts/fetch-models.sh` downloads the model weights from Hugging Face.
They are GGUF conversions of the publishers' weights, each under the
publisher's license:

- Qwen3-TTS 12 Hz talker and tokenizer: Apache-2.0 (Qwen team, Alibaba)
- Parakeet TDT 0.6B v3: CC-BY-4.0 (NVIDIA); attribute NVIDIA when you
  redistribute the weights. ox-say uses the q8_0 conversion. On 300 Russian
  and 300 English FLEURS test utterances its WER matched f16 (normalised:
  Russian 5.17% against 5.27%, English 6.00% against 6.03%; with case kept:
  6.81% against 6.84%, 8.13% against 8.15%) at about half the memory (669 MB
  against 1229 MB resident). The other 23 languages were not measured
- Whisper large-v3-turbo (optional): MIT (OpenAI)
- Forced aligner for `ox-align` (optional, converted by hand, see
  `engine/README.md`): the MMS-300m forced-aligner weights are CC-BY-NC-4.0,
  **non-commercial**; `facebook/wav2vec2-base-960h` is Apache-2.0
