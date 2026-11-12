# Usage
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
With `on`, a `speak` that needs the engine can block behind a long GPU
run, and over MCP fail after about 5 minutes. `off` never touches the card.
On a discrete card `OX_SAY_STT_GPU=on` does not opt the resident server into
the GPU — a process that holds GPU memory for its whole lifetime cannot take
part in a per-run lease, so the server is always `-ng` there. Transcriptions
run one at a time; up to 8 more wait,
further ones get 503.

