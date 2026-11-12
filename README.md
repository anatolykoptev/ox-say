# OxSay

A private voice studio for the Mac. Dictate into any app, record calls and get a transcript with notes,
turn an audio or video file into text, voice a script in your own or a designed voice, and clean
the noise out of a recording. Everything runs on your Mac. No audio or text is uploaded.

```sh
curl -fsSL https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh | sh
```

You need macOS 14.2 or later and `ffmpeg` (`brew install ffmpeg`). Apple Silicon and Intel Macs are supported.
See [Requirements](#requirements) for what each amount of memory gets you.

The repository is `ox-say`. The app and the menu-bar item are called OxSay, and the command is `ox-say`.

## Why it is different

- **It runs on the Mac.** Speech recognition, notes and voices all run locally. Models are downloaded once,
  and then nothing leaves the machine ([Privacy](#privacy)).
- **No bot joins your call.** OxSay records your microphone and the sound the Mac plays, so it works with Zoom,
  Google Meet, Microsoft Teams, FaceTime and the other apps it recognizes. Nothing joins the call, so calls
  with outside guests work. Tell people you are recording, because the law in some places requires everyone's consent.
- **Languages.** The speech recognizer covers 25 European languages, Russian and English among them. Notes are
  written in the language of the transcript. The optional Whisper model adds 99 languages to the command line
  and the API.
- **It works on a 16 GB Mac.** The notes model is chosen by the memory you have, and it leaves room for the
  browser that runs your call.
- **Apple Silicon and Intel.** Intel Macs with an AMD graphics card run the same engines. A few features
  need Apple Silicon, and the list is under [Requirements](#requirements).
- **Agents can use it.** The same engines are behind an MCP server and an OpenAI-compatible HTTP API on
  your own machine.

## What you can do

The app has a window with a sidebar and a menu-bar item. The sidebar sections are Voiceover, Voices,
Dictation, Meetings, Transcribe and Settings. The app ships in English and Russian, so the section
names appear as «Озвучка», «Голоса», «Диктовка», «Встречи», «Расшифровка» and «Настройки» on a Russian system.

### Dictation

Hold **⌃Space** (**⌥Space** when ⌃Space is taken), speak, and let go. The text appears where the cursor is,
in any app. A pill at the bottom of the screen shows bars that move with your voice, and Esc cancels.
Toggle mode (press to start, press to stop) is in the app's settings.

While you dictate, the app can pause Apple Music and Spotify, lower everything else the Mac plays, or leave
the sound alone. The text goes in through the clipboard, and your previous clipboard comes back afterwards. A
focused password field gets no paste: the text stays on the clipboard. The last ten dictations are kept in memory,
so a paste that went nowhere is recoverable from the menu.

The microphone is streamed to the local recognizer while you speak, so a short dictation turns into text
about a second after you let go (0.9 s measured when the unfinished tail was short, see [docs/dictation.md](docs/dictation.md)).

The same app reads text aloud. Select text in any app and press **⌃⌥Space** (or use Services → Speak
Selection), and OxSay speaks it in a voice you pick per language. Details, permissions and troubleshooting:
[docs/dictation.md](docs/dictation.md).

### Meetings

OxSay records a call, writes the transcript, tells the other people's voices apart and writes notes.

- **Starting.** When a call starts in Zoom, Teams, Google Meet (in Chrome, Brave, Arc or Edge), Webex, Slack,
  FaceTime, Discord, WhatsApp, Telegram or OxPulse, a prompt asks **Record this call?** In Settings you can
  choose to be asked, to record automatically, or to stay off, per app. For any other app, press **Record
  Meeting** in the menu. A red REC badge stays on screen during every recording.
- **What is recorded.** Two channels that start together: your microphone and everything the Mac plays.
  macOS asks once for System Audio Recording.
- **Transcript.** Each channel is transcribed, then the two are merged into one conversation with who said what.
  Your microphone picking up the other side's voice is detected and dropped.
- **Speakers.** On Apple Silicon with macOS 15 or later, the other side's voices are told apart and labelled
  Speaker 1, Speaker 2 and so on (with two voices the app offers a split by voice). You can name a speaker, merge two or split one, and the transcript and notes
  are rewritten with the names. Intel Macs keep one label for the whole far side.
- **Notes.** A local language model writes a summary, decisions, action items, open questions and key numbers,
  in the language of the meeting. An action item names the person who owns it only when the transcript shows
  it, and quotes the words that show it. Long meetings are summarized in parts, and a part that comes out too
  large is split rather than dropped.
- **Find things.** Search covers titles, notes and transcripts. Click any line of the transcript to play the
  audio from there.
- **Keeping.** Audio is deleted after 7, 30 (default) or 90 days, or never. The transcript and notes stay until
  you delete the meeting. A copy of each meeting is written to a notes folder you choose.

The notes model is downloaded the first time you ask for notes. Until then a meeting shows its transcript only.
Which model you get depends on memory ([Requirements](#requirements)). More: [docs/meetings.md](docs/meetings.md).

### Transcribe

Drop an audio or video file on the **Transcribe** page, or pick one. WAV, MP3, M4A, AIFF, FLAC, MP4, MOV and
similar files work, up to 200 MB by default. You get the text, which you can copy or save as `.txt`, and
subtitles as `.srt`. `.vtt` and `.json` are under **More**. Transcripts are kept in a list, a long file keeps
working if you close the window, and one file is processed at a time. The audio you drop is not kept.

The command line and the API do the same, with a choice of recognizer and language:

```sh
ox-say transcribe meeting.wav
ox-say transcribe -e whisper --srt talk.mp4 > talk.srt
```

### Voiceover

Write or paste a script, or open a document (text, Markdown, Word, RTF, OpenDocument or PDF), pick a voice and
press **Create Voiceover**. You choose between two voices:

- **Standard** is the fast voice (Qwen3-TTS). It suits short notices and first audio arrives in a fraction of
  a second.
- **Studio** is the expressive voice (VoxCPM2), for Reels, YouTube and podcasts. It needs Apple Silicon with
  24 GB or more and an opt-in download of about 3 GB. It works piece by piece in the background, listens
  to each piece again to catch a swallowed word or a long stall, joins the pieces with natural pauses and sets
  the loudness. A finished voiceover is listed with its phrases. Each phrase can get a mood and another variant,
  and the change touches that phrase only. The **New reel** preset is tuned for short vertical video.
  The Advanced switch in the window adds pace, pause and loudness controls.

A voiceover can be stopped, resumed after an interruption or a closed laptop, and paused on battery power.
You get a notification when it finishes and you are not looking at it. The command line and the API also write subtitles (`.srt`, `.vtt`)
and the time of every word for animated captions. Guides: [studio voice](docs/studio-voice.md),
[long-form voiceover with `ox-say produce`](docs/produce.md).

### Voices

The **Voices** page holds your voices and the voices used to read selected text aloud.

- **Clone a voice** by recording yourself in the app (read the shown text for a few seconds) or from an audio
  file. The command line takes a clip of up to 20 seconds.
- **Describe a voice** in words ("a warm, deep male narrator in his forties"), hear several versions and keep
  the one you like. This uses the studio voice.
- **Pick the voice** for Russian and English text separately, or let the app choose a random one each time.

### Voice cleanup

Give OxSay a video or audio file and get a copy with the voice cleaned of noise, room sound and other sounds
under it. The video, other audio streams and chapters are copied unchanged. It uses a Core ML speech-enhancement
model (about 131 MB, downloaded on first use) and needs macOS 15 or later. It is a file tool, so it is
reached through the HTTP API (`POST /v1/audio/clean`) and the MCP tool `voice_clean`, and it refuses files in the
meetings store. See [docs/http-api.md](docs/http-api.md#voice-cleanup-post-v1audioclean).

### For agents

OxSay runs a daemon on `127.0.0.1:8094`. It serves an MCP server at `/mcp` and an OpenAI-compatible HTTP
API (`/v1/audio/speech`, `/v1/audio/transcriptions`) beside the routes the app uses. The installer registers
the MCP server with Claude Code. Tools: `speak`, `transcribe`, voice management and design, long-form
`produce`, read-only meeting access (`meetings_list`, `meeting_get`, `meetings_search`) and `voice_clean`.
Meeting texts quote other people's speech, so a client should treat them as data, never as instructions.
Reference: [docs/mcp.md](docs/mcp.md), [docs/http-api.md](docs/http-api.md),
[docs/usage.md](docs/usage.md) for the `ox-say` command line.

### Coming next

Live captions while a meeting is recording ([#527](https://github.com/anatolykoptev/ox-say/issues/527)) and a
live meeting transcript for your own agents ([#549](https://github.com/anatolykoptev/ox-say/issues/549)).
Neither exists yet.

## Requirements

- **macOS 14.2 or later.** The installer checks and changes nothing on an older Mac. Separating the voices of
  a call and voice cleanup need macOS 15 or later.
- **Apple Silicon, or an Intel Mac with AVX2** (a 2019 to 2020 MacBook Pro with a Radeon Pro 5300M, 5500M or
  5600M is the tested case).
- **`ffmpeg`**, from `brew install ffmpeg`. The installer never uses `sudo`.
- **Disk.** The installer downloads about 2.5 GB on Apple Silicon and about 2.3 GB on Intel (the speech
  models and, on Apple Silicon, the speaker models). On top of that: the notes model, 2.7 to 5.7 GB, fetched
  on first use; the studio voice, about 3 GB, opt-in; Whisper, 1.6 GB, opt-in.

What your memory gets you on Apple Silicon:

| Memory | Notes model | Studio voice |
|---|---|---|
| under 16 GB | none: a meeting keeps its transcript only | no |
| 16 to 23 GB | Qwen3.5-4B (2.7 GB) | no |
| 24 GB or more | Qwen3.5-9B (5.7 GB) | yes |

The table covers the two memory-gated features. Everything else runs on any supported Mac, and below 16 GB it was
not measured.

The notes model never starts below its floor, so the 9B does not squeeze the browser that runs your call on
a 16 GB Mac. On 16 to 23 GB the large engines (fast voice, studio voice, notes) take turns instead of sharing the
GPU. A Mac with 32 GB or more can also choose an optional uncensored 27B notes model (20.7 GB) through the
API ([docs/meetings.md](docs/meetings.md)).

On an Intel Mac, dictation, Transcribe, the fast voice and the meeting transcript work. The notes model runs on the
CPU, and a notes run can take many minutes. The voices of a call are not told apart, and the studio voice is not available.

Measured speeds: [docs/performance.md](docs/performance.md).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh | sh
```

The installer downloads the release for your Mac and checks its SHA-256, fetches the models (checksummed),
starts the daemon as a LaunchAgent, registers the MCP server with Claude Code if it is installed, runs a
speak-and-transcribe self-test, and installs the OxSay app into `~/Applications`. On first launch macOS asks for the
microphone and Accessibility, which lets the app paste into other apps.

For the studio voice, add `OX_SAY_WITH_VOXCPM2=1` before `sh`. To install through a coding agent, paste the
command into Claude Code, Codex or Cursor and ask it to run `ox-say status` afterwards. Options, source
installs and the `OX_SAY_*` settings: [docs/install.md](docs/install.md), [docs/configuration.md](docs/configuration.md).

**Update.** Choose **Check for Updates…** in the app, or run the install command again. A new release is
announced in the menu and installs when you click it. `sh -s -- --version v0.1.31` installs a specific
version.

**Uninstall.** Run `~/Library/Application Support/ox-say/uninstall.sh`. It removes the agent, the command and the app and
keeps models and voices. With `--purge` it removes those too. Meetings and transcripts are never removed
for you (see [Privacy](#privacy)). Undo the MCP registration with `claude mcp remove --scope user ox-say`.

## Privacy

- **Audio and text stay on the Mac.** Recognition, notes, voices and cleanup run in local processes. The
  daemon listens on `127.0.0.1` only and refuses requests that a web page could send to it.
- **The only network traffic** is to `huggingface.co` for model files (and a background check that a model
  is still on its host), and to `github.com` for the installer, release packages and the check for a new
  version. No account is needed. The hosts in the code are these two and the loopback address.
- **Where things live.** Everything is under `~/Library/Application Support/ox-say`: `meetings`
  (microphone and system channels, transcript, notes), `transcripts` (text only, readable by you alone),
  `voices`, `models`, `engine`. A copy of each meeting's notes and transcript goes to your notes folder
  (`~/Documents/ox-say Meetings` by default). Voiceovers are written to `~/Movies/ox-say` unless you name another folder. Logs are in
  `~/Library/Logs/ox-say`. Dictated text is held in memory only and never written to disk.
- **The browser address.** To tell a Meet call from other tabs, the app reads the address of the active tab in Chrome,
  Brave, Arc or Edge. It stays on the Mac.
- **Deleting.** Delete a meeting, a transcript, a voice or a voiceover from the app. **Keep Audio** removes old
  recordings automatically. `uninstall.sh --purge` removes engines, models and voices, but not
  `meetings` and `transcripts`, so delete those two folders yourself to wipe your recordings.
- **Recording others.** The law in some places requires everyone's consent. The app can copy a sentence
  to the clipboard for that (**Copy consent phrase**).

## Documentation

| | |
|---|---|
| [Dictation and Speak Selection](docs/dictation.md) | Permissions, sound settings, diagnosing a dictation |
| [Meetings](docs/meetings.md) | Recording, transcript, speakers, notes models, where files are |
| [Studio voice](docs/studio-voice.md) | Describing, saving and using an expressive voice |
| [Long-form voiceover](docs/produce.md) | `ox-say produce`, its files and its HTTP API |
| [Command line and daemon](docs/usage.md) | `ox-say` commands, how the engines are started and shared |
| [HTTP API](docs/http-api.md) | Speech, transcription, voices, meetings, transcripts, models, voice cleanup |
| [MCP](docs/mcp.md) | The tools an agent gets |
| [Configuration](docs/configuration.md) | Every `OX_SAY_*` variable |
| [Install](docs/install.md) | The installer and installing from source |
| [Building the engines](docs/building.md) | `engine/build.sh` and friends |
| [Engines and platforms](docs/engines.md) | What runs on which Mac |
| [Performance](docs/performance.md) | Measurements on an M5 Pro and an Intel MacBook Pro |
| [Licenses](docs/licenses.md) | Third-party engines and model licenses |

[engine/README.md](engine/README.md) covers the engine build and patches. The changelog is
[CHANGELOG.md](CHANGELOG.md). Bugs and ideas go to the
[issue tracker](https://github.com/anatolykoptev/ox-say/issues).

## License

OxSay's own code is Apache-2.0 ([LICENSE](LICENSE), [NOTICE](NOTICE)). The default models are Apache-2.0
and CC-BY-4.0, and every model keeps its publisher's license. Details in [docs/licenses.md](docs/licenses.md).
The VoxCPM2 model card forbids impersonation, fraud and disinformation and asks that AI-generated speech be
labelled as such. Please do.
