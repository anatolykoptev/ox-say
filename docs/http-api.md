# HTTP API

Listening on `OX_SAY_ADDR` (default `127.0.0.1:8094`, loopback only):

| Route | Description |
|-------|-------------|
| `POST /v1/audio/speech` | OpenAI-compatible TTS. `input` required; `voice`, `language`, `response_format` (`wav`, `pcm`, `mp3`, `opus` — last two transcoded with ffmpeg), `model` (`qwen3-tts` or `voxcpm2`; absent = the voice's engine, then `OX_SAY_TTS_MODEL`), `instructions`, `seed`, `loudness_lufs` (-40..-5, normalizes the take), voxcpm2 only: `cfg_value`, `inference_timesteps`, `clone_mode` (`auto`/`reference`/`ultimate`; input up to 1000 chars); qwen3-tts only: `temperature`, `top_k`, `top_p`, `repetition_penalty`, `max_new_tokens`; its input (up to 5000 chars) over 600 chars is spoken in pieces cut at sentence ends, on one seed, and answered as one buffered take, and a take that does not end inside its frame budget (or inside `max_new_tokens`) is a 502, never a cut audio (`/status` `tts_faults` counts them). A voxcpm2 or normalized answer is a finished take with `X-Ox-Say-Model`, `X-Ox-Say-Seed` and `X-Ox-Say-Warning` headers |
| `POST /v1/audio/transcriptions` | OpenAI-compatible STT, multipart: `file` (required, ≤ `OX_SAY_STT_MAX_UPLOAD_MB`), `model` (`parakeet` default; `whisper`/`whisper-1`), `language`, `prompt`, `response_format` (`json` default → `{"text"}`; `text`; `verbose_json` → OpenAI's shape: `duration`, `segments` (`start`/`end`), `words` (`word`/`start`/`end`); `srt`; `vtt`; `ox_json` → ox-stt's own result with words as `w`/`s`/`e`/`p`, what `ox-say transcribe --json` prints), `timestamp_granularities[]` (accepted; words are always returned). Errors: 400 bad input, 413 over the upload cap, 500 engine failure, 503 model missing or queue full, 504 timeout |
| `GET /v1/audio/voices` | List persisted voices |
| `POST /v1/audio/voices` | `{"name","audio_path","ref_text"}` plus optional `engine`, `style`, `designed_from`, `label` (display name, ≤60 characters, no control characters) and `source` (`recorded` or `file`) — clone from a local clip (normalized to 24 kHz mono WAV, max 20 s). Re-adding an existing name keeps its stored `engine`/`style`/`label` (`source` and `designed_from` describe the audio, so they are not kept): an empty or absent value on POST means "unchanged", only PATCH clears |
| `POST /v1/audio/voices/design` | `{"description","text","takes"(1..4),"seed"}` → takes rendered with voxcpm2 (no reference voice), each with path, seed, duration and a suggested name |
| `POST /v1/audio/voices/design/save` | `{"name","take","replace"}` → keeps a take returned by design as a voice; the daemon records the description, seed and transcript itself |
| `GET /v1/audio/voices/<name>` | Voice metadata |
| `PATCH /v1/audio/voices/<name>` | `{"engine","style","label"}` — change a voice's preferred engine, default style and display label; a given `""` clears, an absent field stays; any other field is a 400 |
| `DELETE /v1/audio/voices/<name>` | Remove a voice |
| `GET /status` | Engine and STT-server state, pids, uptime, restarts, voices, config |
| `GET /health` | Daemon liveness (always 200; engine may be stopped) |

Meeting routes (see [Meetings](meetings.md); the app uses them, and so can an agent):

| Route | Description |
|-------|-------------|
| `POST /v1/meetings` | Create a meeting; the app then writes `me.pcm` and `them.pcm` (raw 16 kHz mono) into its directory |
| `GET /v1/meetings` | List meetings |
| `GET /v1/meetings/search?q=` | Find meetings by words in the title, notes or transcript |
| `GET /v1/meetings/<id>` | One meeting: status, notes, transcript |
| `PATCH /v1/meetings/<id>` | `{"title"}` — rename. A meeting still being recorded or processed answers 409 |
| `GET /v1/meetings/<id>/audio` | Both channels mixed into one mono 16 kHz WAV, built as it is read (Range requests work) |
| `POST /v1/meetings/<id>/finish` | End a recording and queue it for the transcript and notes |
| `POST /v1/meetings/<id>/notes` | Retry the notes |
| `GET /v1/meetings/<id>/speakers`, `PATCH …/speakers` | The other side's voices; name, merge and split them in one request |
| `POST /v1/meetings/<id>/voices` | Tell the voices apart again after the voice engine failed |
| `DELETE /v1/meetings/<id>` | Delete a meeting that nothing is working on |
| `GET /v1/meetings/settings`, `PUT …/settings` | `{"retention_days"}`: how long audio is kept — 0 (forever), 7, 30 or 90 |
| `GET /v1/meetings/notes-model` | The notes model in use: resolved `model` (catalog id or `custom`), `source` (`env`, `saved`, `automatic`), `path`, `installed`, and `choices` — one row per catalog model with `installed` and `supported`, and `upstream` on the uncensored row while it is not installed (`available`, `gone`, `unknown`: a background HEAD of its download URL, 404/410 and 401/403 read as `gone`, everything else as `unknown`) |
| `PUT /v1/meetings/notes-model` | `{"id":"<catalog id>"}` or `{"path":"/abs/file.gguf"}` — choose the notes model. `400`: unknown id, relative path, neither field, or an own file that fails the trial load. `409`: the model is busy (a download, or a meeting queued, running or recording). On success the choice is saved, a resident notes engine is stopped and the next notes run loads the new file — no restart |
| `POST /v1/meetings/notes-model/validate` | Try an own notes model without choosing it: `{"path":"/abs/file.gguf"}` → `200` with `{"ok":true,"name","architecture","bytes"}` — the file's own GGUF `general.name`/`general.architecture` — or `{"ok":false,"reason"}`. The check is the one `PUT {"path"}` runs: a v2/v3 GGUF that fits 70% of this Mac's memory, then `ox-llm` really loading it on a private port, answering `/health` and one short completion |
| `POST /v1/meetings/notes-model/install` | Download a notes model: `{"id":"<catalog id>"}` or a bodiless POST for the automatic default (the 9B, or the 4B when the disk cannot hold it — `/status` `notes.fallback` says `disk`). `409`: already installed, already downloading, a disk or memory refusal |

Transcript routes (a file transcribed and kept by the daemon; the app's Transcribe section uses them):

| Route | Description |
|-------|-------------|
| `POST /v1/transcripts` | Multipart like `/v1/audio/transcriptions` (`file` ≤ `OX_SAY_STT_MAX_UPLOAD_MB`, `model`, `language`, `prompt`) plus `title` (≤ 200 characters). Runs the recognizer and keeps the result; `201` with `{"id","title","engine","language","created","seconds"}`. A failed transcription keeps nothing. It queues behind other transcriptions, so a long file delays dictation as `/v1/audio/transcriptions` does |
| `GET /v1/transcripts` | `{"transcripts":[…]}`, newest first |
| `GET /v1/transcripts/<id>?format=` | `text`, `srt`, `vtt`, `json` (default) or `ox_json` |
| `DELETE /v1/transcripts/<id>` | Delete one (`204`) |

Glossary routes (the heard → meant pairs applied to recognised text):

| Route | Description |
|-------|-------------|
| `GET /v1/glossary` | `{"pairs":[…]}` — every pair: `id`, `heard`, `meant`, `status` (`candidate`/`active`/`rejected`), `sightings` (hashes only), `seen`, `added` |
| `POST /v1/glossary` | `{"heard","meant","context"}` — file a pair. The context must contain the heard form and only its hash is kept; `409` when the heard form already maps to another term, `400` on an invalid pair (heard: 1–4 words of letters, digits, spaces, `'` and `-` only; meant: ≤ 4 words, ≤ 60 chars, letters/digits/spaces and `. - + _ ' #` only) |
| `POST /v1/glossary/<id>/approve` | Make the pair active (also reactivates a rejected one). Owner-only — `403` without `Authorization: Bearer <owner token>` |
| `POST /v1/glossary/<id>/reject` | Stop the pair applying; it stays as a tombstone a later `add` cannot reactivate. Owner-only — `403` without `Authorization: Bearer <owner token>` |

Approve and reject are owner-only. The daemon creates `$OX_SAY_HOME/owner.token` on first start
(32 random bytes, hex, mode 0600) and the two routes compare the `Authorization: Bearer` value against
it in constant time. The owner settles pairs through `ox-say vocab ok|rm`, which runs only at a
terminal, shows the pair, and sends the token after a bare `y`. This keeps an agent from approving its
own filings by mistake — it is a guard against our own tools acting eagerly, not against a hostile
local process, which could read the token file anyway.

Active pairs apply to dictation responses (streaming sessions), `/v1/audio/transcriptions`,
`/v1/transcripts` when read (the stored document stays raw, so rejecting a pair restores the
original words), the MCP `transcribe` tool, and meetings transcribed after the pair is active.
Batch results rewrite a match that spans segments: the meant goes into the first spanned
segment, the matched words come out of the later ones (a segment that becomes empty is dropped,
the rest keep their timings), so text, words, SRT and VTT agree. In a streaming session a pair
whose words an `/audio` chunk boundary splits is corrected only in the final `text` of
`/finish` — the per-chunk `segments` texts are rewritten one response at a time and keep what
they decoded.

Model routes (list the models this Mac can run, and install or remove the optional ones):

| Route | Description |
|-------|-------------|
| `GET /v1/models` | `{"models":[…]}` for `qwen3-tts`, `voxcpm2`, `parakeet`, `whisper`, `notes`, `notes:qwen3.5-9b`, `notes:qwen3.5-4b`, `notes:qwen3.8-27b-uncensored` (and `notes:custom` while your own file is the notes model); each row has `id`, `kind` (`speech`, `transcribe`, `notes`), `name`, `bytes`, `installed`, `default` (the daemon's own default for its kind — `notes:qwen3.5-9b` for notes), `optional` (may be installed and removed; false for `qwen3-tts`, `parakeet` and `notes:custom`), `removable` (true only when `DELETE` would succeed: optional, installed, the installer's file name, a plain file in `<home>/models`), `installing` (the notes download is running), `supported` and, when it is false, `reason_code` and `reason`; the `notes:qwen3.8-27b-uncensored` row also carries `upstream` while its file is not installed (`available`, `gone`, `unknown` — whether the download URL still answers; `gone` is only 404/410 or a gated 401/403, a network error or 5xx is `unknown`, and the field is omitted once the file is on disk). The plain `notes` row is the model notes would run on now — the resolved one — kept for clients written before the catalog. `supported` means this Mac can run the model; it does not mean ready now (a model that is not downloaded yet is still supported; `/status` `available` is the ready-now word). `bytes` is the size on disk when installed. For a model that is not installed it is the expected size: exact for every `notes…` row (the catalog's pinned bytes, the same figures `scripts/fetch-models.sh` downloads), approximate for `voxcpm2` (3.0 GB) and `whisper` (1.6 GB), and 0 where unknown (`qwen3-tts`, `parakeet`). One stat per file: cheap enough to call whenever a window opens |
| `DELETE /v1/models/<id>` | Remove an optional model (`voxcpm2`, `whisper`, `notes`, `notes:<catalog id>`) and stop its engine first; `204`. `400`: a required model, `notes:custom`, a file that is not the one the installer writes (`OX_SAY_*_MODEL` pointing at your own file, a symlink, a folder), or a model outside `<home>/models` (managed outside OxSay; `GET` shows `removable: false`). `404`: unknown id or not installed. `409`: in use (a speech, design or produce job for `voxcpm2`; a transcription for `whisper`; a download, a queued, running or recording meeting for `notes` and `notes:<id>`; an engine still serving or starting). Deleting `notes` removes the file the resolution names; deleting `notes:<id>` removes that catalog file (and stops the notes engine when it is the resolved one). `notes` and `notes:<id>` are restored by `POST /v1/meetings/notes-model/install`; `voxcpm2` and `whisper` by `scripts/fetch-models.sh` |

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


## Voice cleanup (`POST /v1/audio/clean`)
An offline file tool, not a dictation route: it never touches meetings or dictation (any path under `<home>/meetings`, including through a symlink or hard link, is 403), and dictation never waits for it. The first request on a Mac without the model starts `fetch-models.sh --clean-only` (one download at a time) and answers 503 `models_downloading`; `/status` `voice_clean` and the `voice_cleanup` row of `GET /v1/models` show the download.

| Route | Description |
|-------|-------------|
| `POST /v1/audio/clean` | `{"in_path":"/abs/in.mov","out_path":"/abs/out.mov","wet":0.85,"stereo":"mid","overwrite":false}` → 200 `{"out_path","video","input_seconds","elapsed_s","wet","stereo","sample_rate","channels","lag_ms","dropped":[{"index","type","codec"}]}`. `wet` absent = 0.85 (a given `0` is honoured). Errors are `{"error":{"message","type","code"[,"reason","reason_code"]}}` with a stable `code`: 400 `invalid_request`, 403 `forbidden_path`, 404 `not_found`, 409 `exists` / `same_file` / `busy` (a cleanup is already running), 422 `no_audio` / `unsupported_channels` / `unsupported_streams` / `too_long`, 502 `engine_failed` / `lag_unverified` / `model_wrong_answer` (the model gave a wrong answer on this Mac; nothing was cleaned) / `engine_input` / `engine_output`, 503 `os_too_old` / `engine_missing` / `models_missing` / `models_downloading` / `models_unusable` / `busy` (dictation or another job is running for over 2 minutes) / `gpu_busy` (Intel) / `models_download_failed` / `unavailable`, 504 `engine_timeout`, 507 `disk_space` |

A cleanup starts when no dictation session, speech, voice design, transcription, voiceover render or meeting processing is running, waiting up to 2 minutes for that (else 503 `busy`). Dictation and live meetings never wait for a cleanup. While a cleanup runs, a voiceover render and the processing of a finished meeting do not start a new step; they wait for it only up to 2 minutes (the producer's `maxYield`) and then carry on. `busy.cleaning` in `/status` is 1 for the whole request. A body with an unknown field or data after the object is 400; a cleanup that outlasts the daemon's 3 hour cap is 504 `engine_timeout`; a failed model download is not retried for a minute (503 `models_download_failed`, with the reason).

On Apple Silicon (unified memory) a cleanup takes no GPU lease and shares the GPU with other jobs for the few seconds it runs. On Intel, voice cleanup and speech share one graphics card and take turns: the cleanup stops an idle speech engine to take the card, waits up to 2 minutes if speech is working (then 503 `gpu_busy`, "The graphics card is busy with speech; try again in a moment."), and a speech request that arrives meanwhile and cannot start the engine fails with 503 `gpu_busy_cleanup` ("Voice cleanup is using the graphics card; speech will be available when it finishes."). That refusal comes after at most 10 seconds of waiting, not when the cleanup ends. A cleanup that finds an idle speech engine recycles it, so the next speech request after the cleanup pays a cold start.

