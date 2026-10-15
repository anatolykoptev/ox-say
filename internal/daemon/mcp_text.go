package daemon

// speakDescription is what an agent reads before calling speak: when to pick
// each engine, the options, units and limits, and what comes back.
const speakDescription = `Synthesize speech to an audio file; returns path, format, duration, elapsed time, voice, model, seed and any warning.

Two engines:
- model "qwen3-tts" is fast (about 4x real time, 24 kHz). It has cloned voices but no style control. Use it for quick notices.
- model "voxcpm2" is the quality voice: 48 kHz, 30 languages, emotion and style control, voice design. It renders at about real time, and the first call after idle loads the model (10-40 s). Use it for voiceover and anything expressive. Apple Silicon with 24 GB or more, opt-in install.
With no model given, the voice's preferred engine applies (if voxcpm2 cannot run on this Mac, qwen3-tts speaks and warning says so), else the daemon default (usually qwen3-tts).

voxcpm2 options:
- instructions says HOW to speak. Write short English descriptors, comma-separated, without parentheses: emotion, pace, loudness, delivery. Examples: "excited and joyful, lively pace, smiling voice"; "calm and warm, slow, close to the mic"; "angry and frustrated, loud, sharp emphasis". It works for text in any language. With a voice, instructions keep the voice's timbre and change the delivery; without instructions the voice's saved style applies. With voice "default" (no cloned voice) instructions also describe the speaker (voice design): "A deep male narrator in his forties, calm documentary voice-over". Omitting voice uses the configured default voice, not "no voice". To keep a designed voice, use voice_design then voice_design_save.
- Emotional results vary by seed. For an important line, render 2-3 seeds and keep the best. The seed in the result (0-4294967295) reproduces a take.
- cfg_value (default 2.0, the measured setting): higher follows the text and style more strictly; too high sounds strained. Change it only when a take ignores the style.
- inference_timesteps (default 10, the measured setting): more costs time. Leave it unless you are making a final render and have time.
- clone_mode: "auto" (the default) uses the voice's transcript for the most faithful copy when no instructions are set; "reference" clones the timbre only; "ultimate" needs a voice with ref_text and no instructions.
- The text must not start with "(" (it is read as a style tag; with instructions set it is refused). Up to 1000 characters per call: split longer scripts at sentence ends.
- If warning says the take is longer than its text needs, it may contain babble: re-render with another seed.

Other options:
- loudness_lufs normalizes the file: -16 for online video and podcasts, -14 for music streaming, -23 for broadcast.
- format is wav (default), mp3, or opus (OGG, Telegram-ready).
- Without out_path, the file goes to the cache dir as <timestamp>-<slug>.<ext>. With out_path, give an absolute path with an existing parent and an extension matching the format. An existing file is refused unless overwrite is set.
- play plays the file after writing it.`

// voiceAddDescription covers cloning a voice from a clip and the metadata the
// quality engine uses.
const voiceAddDescription = `Clone a voice from a local audio file: 5-20 s of clean single-speaker audio works best; ` +
	`the clip is normalized to mono WAV automatically (a longer clip is cut at a word boundary). ` +
	`Set ref_text to the clip's transcript for transcript-conditioned cloning of the clip's OWN language — ` +
	`it improves quality but carries the accent. For OTHER languages omit ref_text (timbre-only cloning). ` +
	`name must match ^[a-z0-9][a-z0-9_-]{0,31}$. ` +
	`engine sets the voice's preferred model ("voxcpm2" for voiceover voices, "qwen3-tts", or empty for the daemon default). ` +
	`style sets a default voxcpm2 delivery used when speak has no instructions. designed_from records a note on how the voice was made. ` +
	`voxcpm2 uses ref_text for "ultimate" cloning of the clip's own language, so keep it exact. ` +
	`A flat reference recording gives a flat clone: for a lively voice prefer voice_design, then voice_design_save. ` +
	`Returns the name, whether the engine registered it now, and a notice if the clip or transcript was adjusted. Next: speak with voice: <name>.`
