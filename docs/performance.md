# Performance

Measured by `cmd/ox-say-bench` on the distribution engines (`OX_SAY_DIST=1 engine/build.sh`),
each spawned through the daemon's supervisor on loopback.

- Clips are macOS `say` voices (Samantha for English, Milena for the Russian reference), cut with
  ffmpeg.
- Latencies are wall time, warm medians of 3 runs unless a row says otherwise.
- RTF is synthesis time divided by audio duration.
- First audio is the time to the first `pcm` byte.
- Peak RSS is sampled with `ps` every 200 ms.
- Peak footprint is `vmmap --summary`'s "Physical footprint (peak)", which also counts Metal
  memory.
- Each binary's first start, which compiles its Metal library, is excluded and listed in the
  notes.
- The after-idle row was measured with plenty of free memory, so the model was likely still
  resident.

Reproduce from the repository root:

```sh
OX_SAY_DIST=1 engine/build.sh /tmp/ox-say-engine
scripts/fetch-models.sh /tmp/ox-say-models
go run ./cmd/ox-say-bench -engine /tmp/ox-say-engine/out -models /tmp/ox-say-models
```

## Apple M5 Pro, macOS 26.5 (2026-10-14)

The first-start notes below read well under 1 s because macOS caches compiled Metal libraries
across runs, and this was the second run of the same binaries. On the first run, with a cold cache,
`tts-server` took 16.5 s and `ox-stt` 14.2 s to start once. The 1.7B Q8 talker is not fetched by
`scripts/fetch-models.sh`; pass it with `-tts-models`.

### Host

- Chip: Apple M5 Pro
- Cores: 6 performance + 12 efficiency
- Memory (bytes): 51539607552
- macOS: 26.5.1
- Engine pins (engine/pins.env): QWENTTS_COMMIT=6fae929, GGML_COMMIT=40e16e4, WHISPER_COMMIT=6e4ab85
- Date: 2026-10-14

### Text-to-speech: tts-server (Qwen3-TTS) on Metal

| Model | Voice | Language | Start (s) | First audio (ms) | RTF | Peak RSS (MB) | Peak footprint |
|---|---|---|---|---|---|---|---|
| qwen-talker-0.6b-base-Q8_0.gguf | default | English | 0.5 | 29 | 0.22 | 5187 | 3.6G |
| qwen-talker-0.6b-base-Q8_0.gguf | cloned | English | 0.5 | 35 | 0.22 | 5187 | 3.6G |
| qwen-talker-0.6b-base-Q8_0.gguf | default | Russian | 0.5 | 31 | 0.22 | 5187 | 3.6G |
| qwen-talker-0.6b-base-Q8_0.gguf | cloned | Russian | 0.5 | 34 | 0.22 | 5187 | 3.6G |
| qwen-talker-1.7b-base-Q8_0.gguf | default | English | 1.4 | 42 | 0.27 | 7263 | 4.6G |
| qwen-talker-1.7b-base-Q8_0.gguf | cloned | English | 1.4 | 50 | 0.28 | 7263 | 4.6G |
| qwen-talker-1.7b-base-Q8_0.gguf | default | Russian | 1.4 | 43 | 0.28 | 7263 | 4.6G |
| qwen-talker-1.7b-base-Q8_0.gguf | cloned | Russian | 1.4 | 50 | 0.27 | 7263 | 4.6G |

### Speech-to-text: ox-stt, Parakeet TDT 0.6B v3 q8_0

| Measurement | Metal | CPU (-ng) |
|---|---|---|
| Server start (spawn to ready) | 0.23 s | 0.40 s |
| First call after start, 30 s clip | 0.18 s (165× RT) | 0.49 s (61× RT) |
| Whole clip 5 s, warm | 0.05 s (107× RT) | 0.09 s (56× RT) |
| Whole clip 15 s, warm | 0.09 s (158× RT) | 0.23 s (64× RT) |
| Whole clip 30 s, warm | 0.17 s (172× RT) | 0.48 s (62× RT) |
| Whole clip 60 s, warm | 0.38 s (159× RT) | 0.99 s (61× RT) |
| Whole clip 120 s, warm | 0.74 s (162× RT) | 1.96 s (61× RT) |
| Whole clip 300 s, warm | 1.84 s (163× RT) | 5.17 s (58× RT) |
| Daemon path (ffmpeg + server), 60 s clip, warm | 0.41 s (148× RT) | 1.07 s (56× RT) |
| First call after 2m0s idle, 60 s clip | 0.40 s (148× RT) | 1.01 s (59× RT) |
| Session /finish after 15 s streamed in real time | 0.05 s | 0.08 s |
| CLI, 360 s clip, model load included | 2.48 s (145× RT) | 6.24 s (58× RT) |
| Peak RSS (ps), resident server | 798 MB | 940 MB |
| Peak physical footprint (vmmap), resident server | 825.1M | 942.5M |
| Whole clip 30 s while tts-server synthesizes | 0.19 s (156× RT) | — |

### Notes

- tts-server first start (Metal library compile, excluded from the tables): 0.47 s
- ox-stt (Metal) first start (Metal library compile, excluded from the tables): 0.23 s
- TTS qwen-talker-0.6b-base-Q8_0.gguf: first synthesis after start took 1.48 s (excluded from the medians)
- TTS qwen-talker-1.7b-base-Q8_0.gguf: first synthesis after start took 1.64 s (excluded from the medians)
