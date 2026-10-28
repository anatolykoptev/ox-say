# ox-say

Local speech for **Macs** — natively on Apple Silicon's GPU, and on Intel Macs' AMD GPU:
- text-to-speech with voice cloning;
- speech-to-text with word timestamps;
- dictation: hold ⌃Space (⌥Space when ⌃Space is taken) in any app, speak,
  and the text is typed where the cursor is (a menu-bar app, see [Dictation](#dictation)).

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

| | Engine | On a Radeon Pro 5500M | On an Apple M5 Pro |
|---|---|---|---|
| Text-to-speech, voice cloning from a short clip | Qwen3-TTS 12 Hz via [qwentts.cpp](https://github.com/ServeurpersoCom/qwentts.cpp) | faster than real time (about 0.55× RTF), first audio in about 100 ms | faster than real time (about 0.22× RTF), first audio byte in about 30–35 ms (Qwen3-TTS 1.7B: 0.27–0.28× RTF) |
| Studio-quality voiceover with emotion, voice design and loudness control (opt-in, Apple Silicon, see [Studio voice](#studio-voice-voxcpm2)) | VoxCPM2 via [audio.cpp](https://github.com/ShugoAI/audio.cpp) | not available | about real time (0.58× RTF warm), 48 kHz |
| Speech-to-text with word timestamps | Parakeet TDT v3 (25 European languages) or Whisper large-v3-turbo (99 languages) via whisper.cpp | 6 minutes of audio in about 18 s | 6 minutes of audio in about 2.5 s on Metal |
| `ox-align` engine tool: per-frame CTC emissions for a wav2vec2 checkpoint ([engine/README.md](engine/README.md)) — not exposed by the daemon | optional hand-converted GGUF (the MMS aligner weights are CC-BY-NC; the installer fetches none) | emissions match the transformers oracle within tolerance | not measured |

Apple Silicon numbers: [docs/performance.md](docs/performance.md).

## Intel Macs and Apple Silicon

The modern local speech stacks have left Intel Macs behind:
- PyTorch stopped publishing macOS x86_64 wheels after 2.2.
- MLX runs only on Apple Silicon.
- [VoiceStudio's install guide](https://github.com/debpalash/VoiceStudio/blob/main/docs/install/macos.md)
  states that its local backend cannot run on Intel Macs.
- Stock ggml gives wrong results on discrete, non-unified-memory Metal GPUs.

ox-say carries the fixes (`engine/patches/ggml`, see [engine/README.md](engine/README.md)). It
builds static binaries, so a 2019–2020 MacBook Pro with a Radeon Pro 5300M/5500M/5600M runs
current speech models on its GPU.

On Apple Silicon the same engines build natively for arm64 and run on Metal. The GPU shares the
Mac's memory, so the TTS engine and speech-to-text run on it side by side, with no lease
(`OX_SAY_GPU_MEMORY`, see [Usage](#usage)). The ggml patches are carried there too; on unified
memory they are inert or plain bug fixes ([engine/README.md](engine/README.md#apple-silicon)).
Measurements: [docs/performance.md](docs/performance.md).

ox-say itself is Apache-2.0, and the default models are Apache-2.0 and CC-BY-4.0 (see
[Licenses](#licenses)).

## Status

- Engines: pinned upstream plus patches, static `tts-server`, `ox-stt`, `ox-align` and `ox-llm`
  (the meeting-notes model server), verified on a Radeon Pro 5500M and an Apple M5 Pro. Speaker
  diarization (`ox-diar`) is a separate Core ML engine for Apple Silicon.
- Daemon, CLI and MCP server: `cmd/ox-say`.
- Releases: one macOS package per architecture, `ox-say-macos-arm64.tar.gz` (built on GitHub's
  `macos-15` runner) and `ox-say-macos-x86_64.tar.gz` (built on `macos-15-intel`), with one combined
  `SHA256SUMS`. `get.sh` picks the package for the hardware it runs on; a release cut before the
  arm64 package existed has no arm64 asset, and `get.sh` then says so.

## Studio voice (VoxCPM2)

This is the voice to use when you want a **lively, emotional voiceover** (in Russian, or one of 29 other
languages) for a Reel, a YouTube video or a podcast. It sounds like a person reading with feeling. The
default fast voice (Qwen3-TTS) is better for short notices. You can use both: you pick one for each line.

**What you need.** A Mac with Apple Silicon and 24 GB of memory or more. It is an opt-in install that adds
about 3 GB. Run the installer once more with the switch on:

```sh
curl -fsSL https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh | OX_SAY_WITH_VOXCPM2=1 sh
```

Check it with `ox-say status`: the `voxcpm2` line says `ready` or `stopped` (it starts when you first use
it and rests when idle), or says in plain words why it cannot run. Intel Macs cannot run it: the model
does not fit a 4 GB card and would be far too slow on the processor. Everything else keeps working there.

**The way to a lively voice.** Do not clone a flat recording and hope: a flat reading gives a flat
copy. Instead:

1. **Describe** the voice you want, in words, and hear a few versions (takes):
   ```sh
   ox-say voice design "A warm, deep male narrator in his forties, native Russian speaker, calm documentary voice-over" \
     -t "Добро пожаловать. Сегодня я расскажу о свете." -n 3
   ```
   It prints each take's file path and seed, and the exact command to keep one. Each take takes about as
   long as it plays; the first one after a pause also waits 10–40 s for the model to load. Keep the text
   to one or two sentences (up to 200 characters): the voice you save is made from that take.
2. **Listen** to the takes (`--play` plays them) and pick the one you like.
3. **Save** it under a name: `ox-say voice save narrator '<take path>'`.
4. **Use** it, with a style for the feeling you want:
   ```sh
   ox-say say -m voxcpm2 -v narrator -i "excited and joyful, lively pace" -o line.wav "Честно говоря, я и сам не верил, что это сработает."
   ```

Your own recording works too (`ox-say voice add me clip.wav`), with the same warning: the clone is as
expressive as the clip. A calm, flat reading will not become excited. Change a voice's engine or default
style later with `ox-say voice set narrator --style "calm and warm, slow"`.

**Styles.** `-i` (`instructions`) says *how* to speak. Write a few short English words separated by commas:
the feeling, the pace, the loudness. It works for text in any language. Examples:
- `excited and joyful, lively pace, smiling voice`
- `calm and warm, slow, close to the mic`
- `sad and tender, quiet`
- `angry and frustrated, loud, sharp emphasis`

With a saved voice, the style changes the delivery and keeps the voice. A voice can carry a default style
(`--style` on `voice add` or `voice set`) that is used when you give none. Do not start your text with a
bracket `(` when a style is in effect, from `-i` or from the voice's saved style: the engine reads it as a
style, and the call is refused.

**Seeds.** The same words come out a little differently every time, and the feeling varies most. For a line
that matters, make 2–3 takes with different `--seed` numbers and keep the best. `ox-say say` prints the seed it used (and any warning) on the error stream, so it never lands in your
audio or output file. The same seed on the same Mac and the same build gives the same take again.

**Length.** One call takes up to **1000 characters** (about 75 seconds). For a longer script use
[`ox-say produce`](#long-form-voiceover-produce), which does the splitting, checking and joining for you.

**Loudness.** `--loudness -16` (or `loudness_lufs`) sets the finished file to a standard level: -16 for online
video and podcasts, -14 for music streaming, -23 for broadcast. The level is one constant gain, with a
true-peak limiter at -1.5 dBTP; 2-3 second takes land within 0.2 LU (measured -16.0 to -16.2 at -16). A very
peaky take gets a warning that the limiter worked hard, and a take too quiet to raise (more than +25 dB) is
returned unchanged with a warning.

**Quality knobs, for the curious.** Leave them alone unless a take goes wrong. `--cfg` (default 2.0; above 0 and
at most 5) is how strictly the voice follows the text and style; higher is stricter, too high sounds strained.
`--steps` (default 10; a whole number from 1 to 50) is the number of refinement steps; more costs time and was
measured not to help. `--clone-mode` chooses how the voice is copied:
- `auto` (default) makes the most faithful copy, continuing the voice's own recording, only when the voice has
  its transcript, **no style is in effect** (neither `-i` nor the voice's saved style) and your text is in the
  same alphabet as that transcript. Otherwise it copies the timbre only.
- `reference` always copies the timbre only and lets a style steer the delivery.
- `ultimate` needs the voice's transcript and no style at all. With `-i`, or with a voice that has a saved
  style, it is refused: use `--clone-mode reference`, clear the voice's style (`ox-say voice set <name> --style ""`),
  or drop `-i`.

**Safety nets.** The engine stops a take that runs away, and ox-say warns you when a take is much longer than
its text needs (it may contain babble): make another with a different seed.

**If something is wrong.**
- `ox-say status` says `unavailable`: read the reason. "Not installed" or "model not downloaded": run the installer
  with `OX_SAY_WITH_VOXCPM2=1`.
- It crashed at start: read `~/Library/Logs/ox-say/voxcpm2.log`. Usual causes: a damaged model file, or
  port 8097 taken (`OX_SAY_VOXCPM2_PORT`).
- A warning about a long take: make another with a different seed, or shorten the line.
- A request for `voxcpm2` on a Mac that cannot run it is answered with the reason; a saved voice that prefers
  it speaks with the fast voice and says so (`ox-say say` prints the warning, and names any studio-only options
  it ignored).

**Rules of use.** The VoxCPM2 model card forbids impersonation, fraud and disinformation, and asks that
AI-generated speech be labelled as such. Please do.

**Make it the default.** `OX_SAY_TTS_MODEL=voxcpm2` makes the studio voice the default for the CLI, MCP agents
and OpenAI clients that do not name a model. The daemon runs under launchd, which does not read your shell, so set it
when you run the installer; it is written into the daemon's LaunchAgent and kept on later re-runs:

```sh
curl -fsSL https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh | OX_SAY_TTS_MODEL=voxcpm2 sh
```

(From a source checkout: `OX_SAY_TTS_MODEL=voxcpm2 scripts/install.sh`.) To go back, run the installer once with
`OX_SAY_TTS_MODEL=` (empty). The dictation app's Speak Selection always asks for the fast voice, so it is not
affected.

## Long-form voiceover (`produce`)

`ox-say produce` turns a whole script, a Reel or a ten-minute YouTube voiceover, into one finished file in
the studio voice ([VoxCPM2](#studio-voice-voxcpm2)). You write the script as plain text; ox-say cuts it
into pieces at sentence ends, speaks each piece, **listens to every piece again** to catch a swallowed
word or a long stall, joins them with natural pauses, sets the loudness, and hands you the audio together
with ready subtitles. It needs the same Mac as the studio voice (Apple Silicon, 24 GB or more) and a saved
voice (see [Studio voice](#studio-voice-voxcpm2) for making one).

```sh
ox-say produce script.txt -v narrator --preset reels
```

**Writing the script.**
- A **blank line starts a new paragraph**; the pause between paragraphs is longer than between sentences.
- `[pause 0.8s]` puts exactly that much silence at that spot (`[pause 300ms]` works too; a bare `[pause]`
  is 0.6 s). Use it before a punchline or between sections.
- `[style: excited and joyful, lively pace]` at the **very start of a paragraph** changes how that
  paragraph is spoken (a few short English words, comma-separated, the same as `-i`). Without it the
  paragraph uses `-i`, or the voice's saved style.
- **Any other text in square brackets is an error**, and ox-say says where: it will not read `[music]`
  aloud by accident.

```text
Вы когда-нибудь замечали, что лучшие идеи приходят в душ?

[style: excited and joyful, lively pace, smiling voice]
Вот три приёма, которые работают у меня каждый день!

[pause 0.8s]
Сохраните это видео, чтобы не забыть.
```

Numbers are turned into words before they are spoken, and the check hears them like any other word. Only a
number you deliberately leave as digits is not checked (the project notes say so), so listen to those
lines. Write a number as words if you want to be sure. Abbreviations such as «т.е.» may be read letter by letter. Write them out.

**Choosing a preset** (`--preset`):

| Preset | For | Loudness target | Pauses (sentence / paragraph) | Takes per piece |
|---|---|---|---|---|
| `youtube` (default) | YouTube, podcasts | −16 LUFS | 0.30 s / 0.70 s | 1 |
| `reels` | Reels, Shorts, TikTok | −14 LUFS | 0.20 s / 0.45 s (tighter) | 2: the better one is used |
| `voice-under-music` | a voice over a music bed | −18 LUFS | 0.30 s / 0.70 s | 1 |

The loudness is reached with one constant gain plus a true-peak limiter at −1.5 dBTP, so peaks never pass
that ceiling. When the limiter has to cut the loudest peaks by more than 6 dB, the summary notes "loudness needed
a peak limiter: the loudest peaks were pulled down by several dB to hold the true-peak ceiling, so very peaky
speech may sound slightly squashed". Measured: 33-second and 30-second `reels` runs −14.2 and −14.3 LUFS against
−14, the 11-minute `youtube` run −16.1 against −16. A take that would need more than +25 dB (hiss, near silence)
is refused instead of boosting its noise.

`--takes 1..3` overrides the takes per piece (more takes cost proportionally more time).
`--seed N` makes the whole voiceover reproducible; ox-say prints the seed it used.

`--clone-mode auto|reference|ultimate` picks how the voice is copied for the whole voiceover — the same
three modes as [`ox-say say`](#studio-voice-voxcpm2). `auto`, the default, applies the engine's rule: the
job continues the voice's own recording (`ultimate`) when the voice has its transcript, no style is set
anywhere and the script shares its alphabet, else every piece copies the timbre (`reference`). `reference`
pins the job to timbre copying: a per-piece style may steer, and a style change below can never hit the
mode conflict — this is the mode the Reel editor creates its projects in. `ultimate` pins the job to
continuing the recording: a style at create (`-i`, a `[style: …]` line, the voice's own saved style) is
refused, and a per-piece style later is refused too.

**Where the files go.** With `-o ~/Movies/reel/reel.wav` the files land next to that path; otherwise in
`~/Movies/ox-say/<title>/` (`-t "my title"` names the folder and the files: the title lowercased, letters and
digits joined by hyphens, at most 32 characters, e.g. `my-title`; without `-t` they are named after the
project id. This default folder is a provisional choice: change it with `OX_SAY_PRODUCE_OUT_DIR`, an
absolute path, then restart the daemon). An existing file is never replaced
unless you pass `--overwrite`. You get five files with the same name:

| File | What it is |
|---|---|
| `name.wav` | the voiceover: 48 kHz, mono, near the preset's loudness target |
| `name.srt`, `name.vtt` | subtitles, ready for a video editor |
| `name.words.json` | the time of every word, for animated captions |
| `name.manifest.json` | a copy of the project record: the settings, the pieces, the takes |

**Listening to a flagged piece.** When the run ends, ox-say tells you if it is `done` (exit code 0) or
`review` (exit code 3). *Review* means the file is complete, but some pieces failed the automatic check three
times in a row: a stall of more than 1.5 s inside the speech, or words that do not match the script. The
check rejects broken audio; it does not judge whether the delivery is good, so a `done` voiceover is still
worth a listen. For each flagged piece ox-say prints what was wrong and the commands to use:

```sh
ox-say produce status 20261015-120000-a1b2c3 --chunk 1      # its takes: file paths to open and listen to
ox-say produce chunk 20261015-120000-a1b2c3 1 --regen 2     # render 2 more takes of this piece
ox-say produce chunk 20261015-120000-a1b2c3 1 --pick <take> # use that take
ox-say produce chunk 20261015-120000-a1b2c3 1 --text "…"    # replace the piece's words (one piece, no brackets)
```

**Tuning the delivery.** `--style` changes how a piece is spoken, `--pause` the silence after it and
`--pace` its speed — a rate of 0.85–1.15 (1.1 faster, 0.9 slower, 0 back to normal), stretched with
ffmpeg's `atempo` — without recreating the voiceover:

```sh
ox-say produce chunk 20261015-120000-a1b2c3 1 --style "excited, lively"   # re-renders only this piece
ox-say produce chunk 20261015-120000-a1b2c3 1 --pause 1.2                 # only re-assembles, no render
ox-say produce chunk 20261015-120000-a1b2c3 1 --pace 1.1                  # only re-assembles, no render
ox-say produce chunk 20261015-120000-a1b2c3 1 --style ""                  # back to the voiceover's default
```

A pace needs ffmpeg with the `atempo` filter on this machine; without it the change is refused and
nothing moves.

A style the previous take used is kept: switching back is instant. On a voiceover whose voice runs in
`ultimate` clone mode (a clone voice with no style anywhere), styling a piece is refused — it would
re-render every piece; set a style at create (`-i`, or `[style: …]` in the script) or create the
voiceover with `--clone-mode reference` to run in `reference` mode, where a per-piece style is allowed.
A voiceover created with `--clone-mode ultimate` refuses a per-piece style outright.

**Picking is final.** `--pick` means you listened and accept that take: the piece becomes OK even if the take
failed the automatic check, the manifest marks it `user_pick`, and once no piece is left in review the
project turns `done`. (A take that is completely silent cannot be accepted.)

**Regenerating does not switch to the new take by itself:** your current pick stays until you choose.
After `--regen`, ox-say lists the new takes with their files and prints the exact `--pick` command for
each. Every change rebuilds the file in seconds, because only that piece is touched.

**Exit codes** (the run, `resume`, `chunk`, and `status`): 0 done, 3 review, 1 failed, cancelled or
interrupted, 2 wrong usage (an unknown or misplaced flag is refused with its name, never ignored).
`status` of a project that is still going exits 0.

**Closing the laptop.** If anything interrupts a run (the Mac shuts down, ox-say restarts, you cancel), the project is kept.
`ox-say produce resume <id>` continues it; only the missing pieces are made again, and the result is the
same as an uninterrupted run. `ox-say produce ls` lists your projects, `ox-say produce cancel <id>` stops
one (the take being made finishes and is kept), `ox-say produce rm <id>` deletes a project's working files
(the finished files stay unless you add `--delete-outputs`).

**Battery.** On battery or in Low Power Mode, the job pauses (`ox-say produce status` says *paused: on
battery*) so a long render does not drain the Mac. Plug in, or continue anyway with
`ox-say produce resume <id> --allow-battery` (`--allow-battery` on the first command does the same).
**Dictation always goes first:** while you are dictating or using Speak Selection, the voiceover waits
(*waiting for dictation*) and carries on afterwards. While paused on battery the command keeps waiting for
the end; `--no-wait` returns at once with the project id, so you can close the terminal and check later.

**How long it takes.** On a quiet Mac the engine makes speech at about 0.55 times real time (a lab measurement
on an M5 Pro: 10 s of speech in about 5.5 s). A voiceover takes longer than that for three reasons: every
piece is made once per take you ask for (`reels` asks for 2), a piece that fails the check is made again
(up to three tries), and the first piece after a rest waits 10–40 s for the model to load. Measured runs
(M5 Pro, AC power, one voice; another heavy job shared the Mac for part of the long run, so treat them as
upper bounds):
- A 33-second Reel (`reels`, 2 takes per piece): 48 s on a warm model, 62 s on a cold one.
- An 11.2-minute voiceover (`youtube`, 64 pieces): 12.7 minutes. The engine made 93 takes with 941 s of
  speech to deliver 670 s, because the 7 pieces that kept failing the check were tried three times each and
  a few others once more. The rest of that run, after an interruption at piece 11, took 10 minutes.
- Estimates, not measured: a 60-second Reel about 1.5–2 minutes; a 10-minute `youtube` voiceover about 11–12
  minutes; `--takes 2` on a long script roughly half as long again.

The status line shows the time left while it works. The engine uses about 3–4 GB of memory while it runs
(4.1 GB peak in the long run above).

**Limits.**
- **One voiceover at a time.** Starting a second one while one is running is refused and names the
  running one.
- One voice per voiceover, a recording of at most 30 s. Numbers left as digits are not checked (see above).
- About 40,000 characters per project (roughly 48 minutes of speech). Split longer books in parts.
- Apple Silicon with 24 GB or more only; the same disk space as the working takes (a free-space check
  runs first).
- After you replace the engine or the model **by hand**, restart the daemon: the engine's identity is read
  once per start, so without a restart the old takes would still be reused.
- The VoxCPM2 model card forbids impersonation, fraud and disinformation, and asks that AI-generated
  speech be labelled as such. Please do.

### `produce` HTTP API

All on `OX_SAY_ADDR`, loopback only. A project id looks like `20261015-120000-a1b2c3`. Unknown JSON fields
are refused.

| Route | Description |
|-------|-------------|
| `POST /v1/produce` | `{"script"` (required, ≤ 40,000 chars)`,"title","voice","style","preset","seed","takes"(1..3; 0 is refused),"clone_mode"("auto"/"reference"/"ultimate"; default auto, ultimate refuses any style),"out_path","overwrite","allow_battery"}` → 202 with the project summary. 409 + `running_id` when another voiceover is running. No `cfg_value`, steps or loudness: the preset carries them |
| `GET /v1/produce` | `{"projects":[…]}`: the 20 most recent, newest first, without their chunk lists |
| `GET /v1/produce/<id>` | Summary: `status` (`running`, `waiting_for_dictation`, `paused_on_battery`, `review`, `done`, `failed`, `cancelled`, `interrupted`), `seed`, `progress` (`chunks_done`, `chunks_total`, `eta_s`), `outputs`, `chunks` (status, pick, reasons), `notes` |
| `GET /v1/produce/<id>/chunks/<n>` | One chunk (0-based): its text, takes (key, seed, duration, word errors) and `take_files` (key → WAV path) |
| `POST /v1/produce/<id>/resume` | `{"allow_battery"}` → continue an interrupted, cancelled or finished project |
| `POST /v1/produce/<id>/cancel` | Stop a running project; the take in progress finishes and is kept. A project that is not running answers 409 |
| `POST /v1/produce/<id>/chunks/<n>` | `{"action":"regenerate","takes":1..3}` / `{"action":"pick","take":"<key>"}` / `{"action":"edit","text":"…"}` / `{"action":"delivery","style":"…","pause_after":0.05..10 or 0 to clear,"pace":0.85..1.15 or 0 to clear}` (any of them; `"style":""` restores the default); `regenerate` keeps the current pick; `pick` is final (the chunk becomes ok, `user_pick: true`). A chunk number past the end answers 400 with the chunk count |
| `POST /v1/produce/<id>/delivery` | `{"chunks":[{"n":0,"style":"…"},{"n":3,"pause_after":0.6,"pace":1.1}]}` — every entry is checked before anything changes (a bad entry is a 400 and nothing moved), then one relaunch; only chunks whose style changed render, a pause- or pace-only batch only re-assembles. A pace on a machine without ffmpeg's `atempo` filter answers 422. A style that would switch the job's clone mode answers 409 (`styling a phrase needs clone_mode reference…`); on a project created with `clone_mode: "ultimate"` any style answers 409 |
| `DELETE /v1/produce/<id>` | Remove the project; `?delete_outputs=true` also deletes its published files |

**Agents (MCP)** use four tools, `produce`, `produce_status`, `produce_edit` and `produce_control`, that
mirror the routes above. `produce` returns at once with the id; poll `produce_status` every ~10 s.

## Usage

One binary, `ox-say`, is the daemon, the CLI client and the MCP server.

```
ox-say serve        # run the daemon (launchd starts this)
ox-say say hello                        # speak like `say`
ox-say say -v ben -l Russian -f mp3 -o hi.mp3 "privet"
echo piped | ox-say say                 # text from stdin
ox-say say -m voxcpm2 -i "excited, lively pace" --seed 9 --loudness -16 -o hi.wav "..."   # studio voice
ox-say voice add ben ./clip.wav --ref-text "what the clip says"
ox-say voice design "A clear, pleasant female narrator in her thirties" -t "Привет." -n 3   # describe a voice
ox-say voice save narrator <take path>  # keep a take
ox-say voice set narrator --style "calm and warm, slow"   # change a voice's engine/style
ox-say voice ls
ox-say voice rm ben
ox-say produce script.txt -v narrator --preset reels   # a whole voiceover from a script (see "Long-form voiceover")
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
multi-second model load a per-call `ox-stt` pays every time. On an Intel
Mac the server runs on the CPU — spawned with `-ng` — so it never takes GPU
memory from the TTS engine; on Apple Silicon it runs on the GPU (below).
Its idle cost is ~0.7 GB of RAM, and
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

How the GPU is shared depends on its memory. `OX_SAY_GPU_MEMORY=auto` (the
default) picks `unified` on Apple Silicon and `discrete` elsewhere. With
`unified`, the TTS engine and the resident STT server run on the GPU at the
same time, nothing is arbitrated, and `OX_SAY_STT_GPU=off` is the way to
put speech-to-text on the CPU. With `discrete` (an Intel Mac's AMD card)
the rest of this section applies. On the per-call CLI path `auto` and `on`
then behave the same: the GPU at any length. The 5-minute cap below bounds
how long a GPU run can hold a 4 GB card away from the TTS engine, and with
unified memory nothing waits.

On a discrete card, the single GPU is arbitrated by a lease the daemon
shares between the two consumers. A per-call `ox-stt` that runs without
`-ng` holds it for the whole run, and a TTS engine start must wait for it
before spawning — the engine then keeps it until the child has actually
exited, so the brief window where the supervisor already reports stopped
but the process is still tearing down is covered too. On the CLI path
`OX_SAY_STT_GPU=auto` prefers CPU over contention — and caps how long it
will hold the card: it takes the lease only when free AND the decoded
audio is at most 5 minutes, so a `speak` that needs the engine
mid-transcription waits out a short GPU run at worst (the tool's timeout
is about 5 minutes). Longer audio runs with `-ng` without touching the
lease. `on` lifts the length cap but, like `auto`, only takes a free lease
and otherwise runs on the CPU — a transcription never waits for the GPU.
With `on`, a `speak` that needs the engine can wait out a long GPU run.
`off` never touches the card. On a discrete card `OX_SAY_STT_GPU=on` does
not opt the resident server into the GPU — a process that holds GPU memory
for its whole lifetime cannot take part in a per-run lease, so the server
is always `-ng` there. Transcriptions run one at a time; up to 8 more
wait, further ones get 503.

### HTTP API

Listening on `OX_SAY_ADDR` (default `127.0.0.1:8094`, loopback only):

| Route | Description |
|-------|-------------|
| `POST /v1/audio/speech` | OpenAI-compatible TTS. `input` required; `voice`, `language`, `response_format` (`wav`, `pcm`, `mp3`, `opus` — last two transcoded with ffmpeg), `model` (`qwen3-tts` or `voxcpm2`; absent = the voice's engine, then `OX_SAY_TTS_MODEL`), `instructions`, `seed`, `loudness_lufs` (-40..-5, normalizes the take), voxcpm2 only: `cfg_value`, `inference_timesteps`, `clone_mode` (`auto`/`reference`/`ultimate`; input up to 1000 chars); qwen3-tts only: `temperature`, `top_k`, `top_p`, `repetition_penalty`, `max_new_tokens`; its input (up to 5000 chars) over 600 chars is spoken in pieces cut at sentence ends, on one seed, and answered as one buffered take, and a take that does not end inside its frame budget (or inside `max_new_tokens`) is a 502, never a cut audio (`/status` `tts_faults` counts them). A voxcpm2 or normalized answer is a finished take with `X-Ox-Say-Model`, `X-Ox-Say-Seed` and `X-Ox-Say-Warning` headers |
| `POST /v1/audio/transcriptions` | OpenAI-compatible STT, multipart: `file` (required, ≤ `OX_SAY_STT_MAX_UPLOAD_MB`), `model` (`parakeet` default; `whisper`/`whisper-1`), `language`, `prompt`, `response_format` (`json` default → `{"text"}`; `text`; `verbose_json` → OpenAI's shape: `duration`, `segments` (`start`/`end`), `words` (`word`/`start`/`end`); `srt`; `vtt`; `ox_json` → ox-stt's own result with words as `w`/`s`/`e`/`p`, what `ox-say transcribe --json` prints), `timestamp_granularities[]` (accepted; words are always returned). Errors: 400 bad input, 413 over the upload cap, 500 engine failure, 503 model missing or queue full, 504 timeout |
| `GET /v1/audio/voices` | List persisted voices |
| `POST /v1/audio/voices` | `{"name","audio_path","ref_text"}` plus optional `engine`, `style`, `designed_from` — clone from a local clip (normalized to 24 kHz mono WAV, max 20 s) |
| `POST /v1/audio/voices/design` | `{"description","text","takes"(1..4),"seed"}` → takes rendered with voxcpm2 (no reference voice), each with path, seed, duration and a suggested name |
| `POST /v1/audio/voices/design/save` | `{"name","take","replace"}` → keeps a take returned by design as a voice; the daemon records the description, seed and transcript itself |
| `GET /v1/audio/voices/<name>` | Voice metadata |
| `PATCH /v1/audio/voices/<name>` | `{"engine","style"}` — change a voice's preferred engine and default style; a given `""` clears, an absent field stays |
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
`voices_list`, `voice_add`, `voice_update`, `voice_remove`, `voice_design`, `voice_design_save`,
`engine_status`, and the long-form voiceover tools `produce`, `produce_status`, `produce_edit`, `produce_control`. Each tool's description tells an agent when to use it, the units and limits, and what
to call next; the VoxCPM2 quality options (`model`, `instructions`, `cfg_value`, `inference_timesteps`,
`seed`, `loudness_lufs`) are on `speak` only, and `clone_mode` is on `speak` and `produce` (the same
`auto`/`reference`/`ultimate` set, judged by the same rules). Register with:

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
| `OX_SAY_TTS_MODEL` | `qwen3-tts` | Engine for a speech request that names no model and whose voice has no preference: `qwen3-tts` or `voxcpm2` |
| `OX_SAY_VOXCPM2_BIN` | `$OX_SAY_HOME/engine/audiocpp_server` | The VoxCPM2 engine (audio.cpp's server); Apple Silicon only |
| `OX_SAY_VOXCPM2_MODEL` | `$OX_SAY_HOME/models/voxcpm2-q8_0.gguf` | VoxCPM2 weights (`OX_SAY_WITH_VOXCPM2=1` fetch) |
| `OX_SAY_VOXCPM2_PORT` | `8097` | Loopback port the VoxCPM2 child binds |
| `OX_SAY_DIAR_BIN` | `$OX_SAY_HOME/engine/ox-diar` | The speaker diarization engine (meeting voices); Apple Silicon, macOS 15 or later |
| `OX_SAY_IDLE_STOP_SECS` | `300` | Stop the idle engine after N s; 0 = never |
| `OX_SAY_STARTUP_TIMEOUT_SECS` | `180` | Covers the first-start Metal shader compile |
| `OX_SAY_LANG` | empty | Default language; empty = engine auto-detect |
| `OX_SAY_SEED` | empty | Default seed (0 to 4294967295) for a speech request that passes none, so the voice stays the same between requests; a `seed` in the request wins; empty = every request draws its own |
| `OX_SAY_ENGINE_LOG_DIR` | `~/Library/Logs/ox-say` | Child stdout/stderr go to `engine.log` here |
| `OX_SAY_CACHE_DIR` | `~/Library/Caches/ox-say` | Default output dir for `speak` |
| `OX_SAY_PRODUCE_OUT_DIR` | `~/Movies/ox-say` | Where `produce` publishes a finished voiceover when the request names no `out_path` (provisional default, pending the owner) |
| `OX_SAY_STT_BIN` | `$OX_SAY_HOME/engine/ox-stt` | Speech-to-text binary |
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

## Dictation

`app/dictation` is a menu-bar app: hold ⌃Space (⌥Space when macOS or another app owns
⌃Space), speak, release, and the text appears where the cursor is, in any app. The daemon transcribes it, so nothing
leaves the Mac. While you speak, a pill at the bottom of the screen shows bars
that move with your voice; Esc cancels. **Keyboard Shortcuts** in the menu
switches the key to ⌥Space, and **Settings** turns on toggle mode (press to
start, press again to stop). **Studio** in the same menu makes long
voiceovers from a text file and designs new voices (it needs the studio
voice, which the menu installs on request); **About OxSay** shows the version.

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

What happens to sound while you hold the key is the **Settings → Sound While
Dictating** submenu, with three choices. **Pause Music**: Apple
Music and Spotify are paused if they are playing and resume from the same
spot when you let go, cancel with Esc, or the recording ends; a player that
was already paused stays paused, and one that is not running is never
launched. The first time, macOS asks to let OxSay control Music or Spotify
(System Settings → Privacy & Security → Automation). **Lower All Sound**
(the default): everything the Mac plays — Music, a browser, YouTube — keeps playing but
fades to a fraction of its volume while you dictate, then fades back to
exactly the level it had, even over a volume you changed during the dictation.
If the app is killed mid-dictation the output stays quiet until you raise it.
It uses CoreAudio's output volume, so no permission prompt.
**Don't Touch** leaves every sound alone.

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

The same app speaks selected text in any app — pick the way that reaches it:
press the **Speak Selection** key (⌃⌥Space by default, change it under **Keyboard Shortcuts** in the app's menu) with
text selected, or open the right-click menu (or the app's menu) → Services →
**Speak Selection** («Озвучить выделенное»). The key works everywhere: it asks
the focused element for its selection through Accessibility first, and only
falls back to a ⌘C-and-restore when that gives nothing — the clipboard ends
up untouched, and a password field or an unrestorable clipboard blocks the
copy instead of risking it. The Services menu depends on the app handing its
selection to Services, so some Electron apps will not show the item.

The selection goes to the daemon's `/v1/audio/speech`, and the synthesized
wav plays through the app's audio player — nothing leaves the Mac. While the
daemon synthesizes, the pill reads "Speaking…"; the first use after an engine
stop waits out a cold start of about 15 s. Once playback starts the pill turns
into playback controls — pause/resume, the position counter and stop.

The **Voice** submenu has a **Russian** and an **English** section that pick a voice per
language: **Default voice** follows the daemon's configured default,
**Random each time** always rolls a new engine voice, and any cloned voice
registered on the daemon (`ox-say voice list`) can be picked by name. The
text's script decides which pick a request sends — Cyrillic gets the Russian
pick, Latin the English one, anything else leaves the voice to the daemon.
Picking a voice speaks a sample phrase in that voice right away. The
configured default resolves per language too: `OX_SAY_VOICE_RU` for Russian,
`OX_SAY_VOICE_EN` for English, then `OX_SAY_VOICE` for everything else — the
request's `language` field wins, otherwise the input's script decides
(Cyrillic is Russian, Latin is English). The same resolution applies to
`ox-say say` and the MCP `speak` tool — `-v default` or
`"voice": "default"` asks for a random voice explicitly. A new request
while one is in flight supersedes it; a new playback stops the previous one.

**Check for Updates…** compares the installed version with the latest
GitHub release; a newer tag offers a one-click install of the signed
package (the same `get.sh` as the manual install) and relaunches the app.

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
  `outcome=delivered path=stream recorded_s=11.30 release_to_text_ms=2057 tail_s=0.30 segments_before_release=0 session_create_ms=3 delivery=paste id=12`.
  - `path`: `stream`, `fallback` (the session failed and the recording was sent whole) or `one-shot`.
  - `tail_s`: audio not yet acknowledged when the key was released.
  - `session_create_ms`: time to open the session. It is large when the STT server had to start, and `none` when no session opened (the one-shot path, a failed create, or a create still in flight at release).
  - `delivery`: how the text reached the user — `paste`, `typed` (keystrokes, while the clipboard held a copy from another device), or `clipboard` plus `clipboard_reason=accessibility|secure_input|focus_moved`. `none` when the dictation was empty or failed.

  When a paste was posted, a second line follows once it settles: `paste settled id=12 read=yes|no`. The `id` is the same as on that dictation's line, so two quick dictations do not interleave. A paste also settles early, when the next dictation starts or the app quits. `read=no` means no app had read the clipboard by the time it settled — the paste probably went nowhere; any app counts as a read, a clipboard manager too.

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
→ Accessibility looks enabled but no longer applies. While that is the state
the app's menu offers **Allow pasting… (Accessibility is off)** at the top: it
resets this app's own Accessibility entry (`tccutil reset Accessibility
<bundle id>`) so the permission prompt can store a grant matching the running
build, then raises the permission prompt and opens the Accessibility pane (the
prompt can stay silent for an app that is already listed; the pane is where the
switch is). The menu row stays greyed while the reset runs, and a reset that
hangs is stopped after 10 s and reported as a failure. If the item is missing or the reset
fails, remove OxSayDictation with − in the pane and add it again. The same
happens once when updating from ox-say 0.1.x, whose app was signed ad hoc. See
the header of `app/dictation/build.sh`.

## Install

Requirements: macOS 13.3 or later on Apple Silicon, or on an Intel Mac with AVX2; Xcode command line tools, CMake, Go, ffmpeg
(`brew install cmake go ffmpeg`).
Telling the voices of a group call apart (`ox-diar`) needs macOS 15 or later on Apple Silicon; building it from source also needs Xcode 26 (Swift 6.2).
A source install on an older Mac or with older tools skips it and meetings come out with one label for the other side
(`OX_SAY_WITH_DIAR=1` builds it anyway; the Apple Silicon release package carries it, the Intel one does not).

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
`OX_SAY_WITH_VOXCPM2=1 scripts/install.sh` also builds audio.cpp's server and
fetches the VoxCPM2 model (Q8_0, about 3 GB), the quality text-to-speech engine.
It needs Apple Silicon with 24 GB of memory or more: elsewhere the installer
says so and fetches nothing. Without the variable a source install does not
build the engine at all; a release package for Apple Silicon always carries the
binary, and the same variable fetches the model.

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

Requirements: macOS 13.3 or later on Apple Silicon, or on an Intel Mac with AVX2; Xcode command line tools, CMake, ffmpeg.

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

The optional VoxCPM2 engine, [audio.cpp](https://github.com/ShugoAI/audio.cpp), is Apache-2.0 (ShugoAI LLC)
with its own vendored dependencies; `NOTICE` lists our patches to it.

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
- Forced aligner for `ox-align` (optional, converted by hand, see
  `engine/README.md`): the MMS-300m forced-aligner weights are CC-BY-NC-4.0,
  **non-commercial**; `facebook/wav2vec2-base-960h` is Apache-2.0
