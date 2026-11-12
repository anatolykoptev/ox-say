# Studio voice (VoxCPM2)
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
[`ox-say produce`](produce.md), which does the splitting, checking and joining for you.

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

