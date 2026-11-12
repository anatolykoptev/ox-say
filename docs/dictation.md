# Dictation
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

To win that back, the STT server decodes the whole recording once more at release when a dictation was cut
into more than one segment and is at most 15 s long. It does this only when the server's own measured
decode speed predicts the extra decode fits in 500 ms; a slow CPU decode (an Intel Mac) keeps the streamed
text. If the extra decode fails or comes back empty, the streamed text is used
([engine/README.md](../engine/README.md), "Re-decode at release").

## Speak selection
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

## Diagnosing dictation
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

