# Long-form voiceover (`produce`)
`ox-say produce` turns a whole script, a Reel or a ten-minute YouTube voiceover, into one finished file in
the studio voice ([VoxCPM2](studio-voice.md)). You write the script as plain text; ox-say cuts it
into pieces at sentence ends, speaks each piece, **listens to every piece again** to catch a swallowed
word or a long stall, joins them with natural pauses, sets the loudness, and hands you the audio together
with ready subtitles. It needs the same Mac as the studio voice (Apple Silicon, 24 GB or more) and a saved
voice (see [Studio voice](studio-voice.md) for making one).

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
three modes as [`ox-say say`](studio-voice.md). `auto`, the default, applies the engine's rule: the
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
`--timeout 30m` waits at most that long (`s`, `m`, `h`), then prints the project id and exits with code 4 while the
voiceover keeps going.

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

## `produce` HTTP API

All on `OX_SAY_ADDR`, loopback only. A project id looks like `20261015-120000-a1b2c3`. Unknown JSON fields
are refused.

| Route | Description |
|-------|-------------|
| `POST /v1/produce` | `{"script"` (required, ≤ 40,000 chars)`,"title","voice","style","preset","seed","takes"(1..3; 0 is refused),"clone_mode"("auto"/"reference"/"ultimate"; default auto, ultimate refuses any style),"out_path","overwrite","allow_battery","loudness_lufs"(-40..-5; default from the preset),"inference_timesteps"(integer 1..50, default 10; an explicit 0 is refused)}` → 202 with the project summary. 409 + `running_id` when another voiceover is running. No `cfg_value`. More steps render slower; the time estimate and the render timeout grow with them |
| `GET /v1/produce` | `{"projects":[…]}`: the 20 most recent, newest first, without their chunk lists |
| `GET /v1/produce/<id>` | Summary: `status` (`running`, `waiting_for_dictation`, `paused_on_battery`, `review`, `done`, `failed`, `cancelled`, `interrupted`), `seed`, `progress` (`chunks_done`, `chunks_total`, `eta_s`), `outputs`, `chunks` (status, pick, reasons), `notes` |
| `GET /v1/produce/<id>/chunks` | `{"chunks":[…]}`: every chunk in one read, same element shape as `…/chunks/<n>` |
| `GET /v1/produce/<id>/chunks/<n>` | One chunk (0-based): its text, takes (key, seed, duration, word errors) and `take_files` (key → WAV path) |
| `POST /v1/produce/<id>/resume` | `{"allow_battery"}` → continue an interrupted, cancelled or finished project |
| `POST /v1/produce/<id>/cancel` | Stop a running project; the take in progress finishes and is kept. A project that is not running answers 409 |
| `POST /v1/produce/<id>/chunks/<n>` | `{"action":"regenerate","takes":1..3}` / `{"action":"pick","take":"<key>"}` / `{"action":"edit","text":"…"}` / `{"action":"delivery","style":"…","pause_after":0.05..10 or 0 to clear,"pace":0.85..1.15 or 0 to clear}` (any of them; `"style":""` restores the default); `regenerate` keeps the current pick; `pick` is final (the chunk becomes ok, `user_pick: true`). A chunk number past the end answers 400 with the chunk count |
| `POST /v1/produce/<id>/delivery` | `{"chunks":[{"n":0,"style":"…"},{"n":3,"pause_after":0.6,"pace":1.1}]}` — every entry is checked before anything changes (a bad entry is a 400 and nothing moved), then one relaunch; only chunks whose style changed render, a pause- or pace-only batch only re-assembles. Optional `"loudness_lufs"` (-40..-5) re-targets the whole file's loudness the same way, and is the only change an empty `chunks` list may carry: a loudness-only batch needs a finished project (unfinished chunks answer 409) and renders nothing, it only re-assembles — and when that fails the project keeps the status, target and files it had (or reports `failed` when the previous files could not all be restored: the previous version then stays beside the files as hidden `.<name>.prev-…` copies, which the next successful publish removes), with the reason in its `error`. A publish never makes a published name vanish: it backs each old file up by hard link, renames the new one over it, and removes the backups only after the folder is synced. A daemon that dies mid-run reports the status the project had, with an `error` saying the loudness change may not have applied. A pace on a machine without ffmpeg's `atempo` filter answers 422. A style that would switch the job's clone mode answers 409 (`styling a phrase needs clone_mode reference…`); on a project created with `clone_mode: "ultimate"` any style answers 409 |
| `DELETE /v1/produce/<id>` | Remove the project; `?delete_outputs=true` also deletes its published files |

**Agents (MCP)** use four tools, `produce`, `produce_status`, `produce_edit` and `produce_control`, that
mirror the routes above. `produce` returns at once with the id; poll `produce_status` every ~10 s.

