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
| `GET /v1/meetings/<id>/live?after=<seq>&limit=<n>` | Live captions of a meeting being recorded: `{"id","segments":[{"seq","channel":"me"\|"them","start","end","text"}],"next","state"}`, oldest first. Poll with `after=<next>` of the last answer: every caption comes exactly once (`seq` counts from 1; `limit` defaults to 500, at most 1000; a bad `after` is `400`). `state`: `enabled`, `recording`, `active` (a worker is captioning), `lagging` (held, behind or the recognizer unreachable), `paused` (`dictation`, `memory` or `power`), `behind_s`, `problem`. A preview, not the record: the final transcript replaces it. Captions stay with the meeting and go with its audio at retention |
| `POST /v1/meetings/<id>/finish` | End a recording and queue it for the transcript and notes |
| `POST /v1/meetings/<id>/notes` | Retry the notes |
| `GET /v1/meetings/<id>/speakers`, `PATCH …/speakers` | The other side's voices; name, merge and split them in one request |
| `POST /v1/meetings/<id>/voices` | Tell the voices apart again after the voice engine failed |
| `DELETE /v1/meetings/<id>` | Delete a meeting that nothing is working on |
| `GET /v1/meetings/settings`, `PUT …/settings` | `retention_days`: how long audio is kept — 0 (forever), 7, 30 or 90; `live_captions`: live captions while recording (the answer carries the effective value and `live_captions_default`: on for Apple Silicon, off for Intel); `meeting_aec`: `on`/`off` — run `ox-aec` echo cancellation on the mic channel before transcription (on by default; a settings file written before the key existed reads as on, `"off"` is the explicit opt-out); `llm_endpoint`: `on`/`off` — the OpenAI-compatible model endpoint for other apps (off when the key was never written, so it fails closed); `llm_endpoint_ctx`: the context the notes child is asked to run with while the endpoint is on (unset = 131072; a PUT accepts the notes context up to 1,048,576 tokens, rounds down to a multiple of 4096 and refuses anything else with 400; the daemon may run less when memory or the model's own limit says so); `llm_endpoint_max_s`: the longest one endpoint request may run (unset = 600; 10–1200). The answer reports the asked context as `llm_endpoint_ctx` and what the child runs with — or would on its next start — as the read-only `llm_endpoint_ctx_effective`, plus `llm_endpoint_url`; **it never carries the key**. Turning `llm_endpoint` `on` and setting `llm_endpoint_ctx` or `llm_endpoint_max_s` need the owner bearer (`Authorization: Bearer <owner.token>`; `401` without it); turning it `off` and every other field do not. Turning it off ends a large-context child at the next safe point (never under a running notes job). `code_vocabulary`: the built-in code vocabulary packs that are on — a list of `python`, `go`, `rust` (default `[]`; an unknown name is a 400; see below). A PUT changes the fields it carries and keeps the rest |
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

Glossary routes (the heard → meant pairs applied to recognised text). `POST /v1/glossary` is also the
`glossary_add` MCP tool — the same code path and answers an agent can act on (`filed` / `sighting` /
`conflict` / `invalid`); see [MCP](mcp.md):

| Route | Description |
|-------|-------------|
| `GET /v1/glossary` | `{"pairs":[…]}` — every pair: `id`, `heard`, `meant`, `status` (`candidate`/`active`/`rejected`), `sightings` (hashes only), `seen`, `added`, and `vetted` when present (the dictionary found the heard form a single non-ordinary word, so it may activate on the evidence of other spellings of its meant form) |
| `POST /v1/glossary` | `{"heard","meant","context"}` — file a pair. The context must contain the heard form and only its hash is kept; `409` when the heard form already maps to another term, `400` on an invalid pair (heard: 1–4 words of letters, digits, spaces, `'` and `-` only; meant: ≤ 4 words, ≤ 60 chars, letters/digits/spaces and `. - + _ ' #` only) |
| `POST /v1/glossary/<id>/approve` | Make the pair active (also reactivates a rejected one). Owner-only — `403` without `Authorization: Bearer <owner token>` |
| `POST /v1/glossary/<id>/reject` | Stop the pair applying; it stays as a tombstone a later `add` cannot reactivate. Owner-only — `403` without `Authorization: Bearer <owner token>` |
| `POST /v1/glossary/<id>/edit` | `{"meant"}` — give the pair another meant form (same validation as `add`; heard and id stay; the sightings are cleared, they vouched for the old meant; a rejected pair comes back as a candidate). Owner-only — `403` without `Authorization: Bearer <owner token>` |
| `DELETE /v1/glossary/<id>` | Remove the pair for good, no tombstone (an agent may file the heard form again as a new candidate). Owner-only — `403` without `Authorization: Bearer <owner token>` |

Approve, reject, edit and purge are owner-only. The daemon creates `$OX_SAY_HOME/owner.token` on first start
(32 random bytes, hex, mode 0600) and these routes compare the `Authorization: Bearer` value against
it in constant time. The owner settles pairs through `ox-say vocab ok|rm|edit|purge` or the app's
Glossary page; the command runs only at a
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

Model endpoint for other apps — the notes model, shared over an OpenAI-compatible
surface, off by default (`llm_endpoint` in the meeting settings). While off, both
routes answer 404 as if they did not exist. Every request needs
`Authorization: Bearer <key>` with the per-install key the daemon writes at
`<run dir>/llm-endpoint.key` (0600, generated on first use; the file is the source
of truth — the daemon must authenticate with the app not running, so there is no
Keychain copy; a file that was group- or other-readable is replaced by a fresh key
at start). It is a third credential: not `owner.token`, not the MCP auth, and
not the notes child's own per-spawn key; the comparison is constant-time. The key
itself is the owner's: no settings answer carries it, and reading, rotating it and
turning the endpoint on need the owner bearer (below). Scheduling: at most one
request runs and two queue (a fourth is refused with `503` before its body is
read); a queued request waits up to 20 s for the model's single decode slot. Admission
— the dictation yield, the memory turn, the slot — runs under one 30 s deadline; a
request that cannot be admitted in it, or arrives while dictation, a meeting
recording or a meeting-notes job is queued or running, gets `503` with
`Retry-After` — voice work and meeting notes are never preempted, and a meeting's
notes call is served before queued endpoint requests. A request that starts the
notes engine cold is exempt from the 30 s: its model load may take up to the normal
startup timeout. One request runs at most `llm_endpoint_max_s` (600 s by default)
and is then ended cleanly; a client that stops reading is cut after 30 s per write.
Dictation uses the separate STT server, which this surface never waits for or
blocks. Only the model is served: OxSay tools, meetings, glossary and MCP
are not reachable through these routes, and request/response bodies are never
logged. `GET /v1/models` dispatches on the header: a request carrying
`Authorization` is answered as below; one without it keeps the internal catalog
above.

| Route | Description |
|-------|-------------|
| `GET /v1/models` (with `Authorization`) | `{"object":"list","data":[{"id","object":"model","created","owned_by":"ox-say"}]}` — exactly one model, `id` the selected notes model's catalog id (`custom` for an own GGUF). `401` on a missing or wrong key |
| `POST /v1/chat/completions` | The JSON body is proxied to the notes engine unchanged — `tools`, `tool_choice`, `chat_template_kwargs`, `reasoning_effort` and sampling fields all reach llama-server — and the answer is streamed back as it arrives (SSE or a plain response), never buffered whole; a client disconnect cancels the upstream request. `401` no/wrong key; `400` a body over 64 MiB or unreadable; `502` the engine unreachable; `503` + `Retry-After: 30` when voice work or another request holds the model |

Key management (the app Settings pane calls these). Both need the owner bearer —
`Authorization: Bearer <owner.token>`, the credential the glossary's owner routes
use; without it, `401` — and both answer with `Cache-Control: no-store`:

| Route | Description |
|-------|-------------|
| `GET /v1/meetings/llm-endpoint/key` | `{"llm_endpoint_key":"<64 hex>"}`: the key in force |
| `POST /v1/meetings/llm-endpoint/key` | Generate and store a fresh endpoint bearer, answer it once. The old key stops working when the new one is published; concurrent rotations leave the file and the daemon agreeing on one key |

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


## Code vocabulary packs

`code_vocabulary` (in `GET`/`PUT /v1/meetings/settings`, shown in `GET /status` as `code_vocabulary`) turns on built-in
vocabulary packs for dictating about code: `python`, `go`, `rust`. A shared review set (idempotent, traceback, TOML, nit,
LGTM, ...) rides with any enabled pack. Packs are JSON files embedded in the daemon (`internal/codevocab/packs`); an entry
is a written form, the spoken forms measured on Parakeet, and a `value` rank (1 = the recogniser heard it wrong, 2 = partly
right). Changing the setting rebuilds the boost list at once, with no restart; packs saved before a restart are boosted from
the first decode.

- **Packs off is the previous behaviour**: the decoder lines and the post-pass pairs are exactly the owner's.
- **Decoder boost.** An enabled pack's written forms and its `safe` spoken forms are appended AFTER every owner line, in value
  order, with the same wire format and ordinary-word filter. A pack never joins an owner's group, never lengthens an owner
  line, and a pack line that names an owner's written or spoken form is dropped. The wire budget is unchanged (3072 B of JSON,
  200 terms) and trims from the tail, so pack lines go first. A `safe` alias that holds a Cyrillic letter never reaches the
  wire — it is post-pass only, so the decoder is never pushed towards Cyrillic and the boost budget sees none of these
  aliases (a pack may carry far more terms than the ~80-term boost guide because of them).
- **Post-pass.** A `safe` heard form must contain at least one token that is not an ordinary English or Russian dictionary
  word (a spoken "dot" between two words also counts); this is checked when the packs load, in both languages: «пай тест»
  and «матч» fail it just as "ice instance" does, while «пайтест» and «кваргс» pass. A purely Cyrillic token qualifies only
  when it is at least five letters long, is not spelled like a capitalised name, and is not a common loanword the
  dictionaries miss («принт», «джойн», «ок», «арк» are out), and a lone alias of any script meets the same length floor.
  A safe alias is rewritten like an active glossary pair — `Аппент.` → `append.`, `реплейс,` → `replace,` — except that a
  pack alias matches its exact folded spelling only: unlike an owner pair it never stems, so «принтами», «стрипа» and
  «из инстансов» stay untouched. A token that mixes Latin and Cyrillic letters is a word of neither dictionary, so aliases
  such as `startс with` pass too; a mixed-script input token has its Cyrillic letters transliterated to Latin only when it
  is predominantly Latin (more Latin than Cyrillic letters) and the alias word it meets is pure Latin — `Quаrgs` meets
  `Quargs`, while predominantly-Cyrillic `rёплейс` folds to nothing and stays "rёплейс". The fold never runs on a
  pure-Latin or pure-Cyrillic word (`starts` stays "starts"), never on the stored alias, and never on an owner pair, and
  text no alias matched is left untouched. Ordinary
  words and phrases are never rewritten (`chords`, `Tokyo`, `trace back`, `beautiful soup`, `go routine`, `сорт`, `матч`,
  `карго`, `токио`). The only joins are an explicit allow-list of code-only compounds: `type error`, `key error`, `value error`,
  `index error`, `attribute error`, `not implemented error`, `stop iteration`, `data class`, `doc string`, `async IO`,
  `monkey patch`, `wait group`. An alias that names two different written forms across packs («мьютекс» for go's `mutex`
  and rust's `Mutex`) is dropped from both packs at load. Corrections run in two passes: every owner pair applies over the
  whole text first, claiming the words it consumes and produces, and pack pairs then match only what is left — a word an
  owner correction touched is never re-matched by a pack pair. Any pack pair that shares a word with an owner pair is
  dropped under the same fold the matcher uses, and a pack decoder line whose spoken form contains an owner spoken form is
  not sent: the owner's pair always wins. Packs are an explicit code mode, so the joins are intended there.
