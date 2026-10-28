# Engine

`build.sh` clones qwentts.cpp at the commit in `pins.env`, checks that its
ggml submodule is at the recorded commit, applies the patches below and
builds a static `tts-server`.

## Metal shaders: precompiled libraries, embedded fallback

Every engine binary always embeds the Metal sources
(`GGML_METAL_EMBED_LIBRARY=ON`): a missing, stale or corrupt metallib can
never stop an engine. When the Metal toolchain works, the build additionally
compiles the same kernels ahead of time: a second, cheap configure of the
same patched ggml tree with `GGML_METAL_EMBED_LIBRARY=OFF` builds only the
`ggml-metal-lib` target, and its `default.metallib` is copied to `out/` under
the binary's own name — `tts-server.metallib`, `ox-stt.metallib`,
`ox-align.metallib`, `ox-llm.metallib` and, on arm64 with VoxCPM2,
`audiocpp_server.metallib`.
`GGML_METAL_MACOSX_VERSION_MIN=14.0` pins the ordinary library's AIR target:
it carries the bf16 kernels (`GGML_METAL_HAS_BF16`, patch `0005`,
`audiocpp/0004`, `llamacpp/0001`), which need Metal language 3.1 — the runtime source compile
defines the macro on every bfloat-capable device, so the precompiled library
must match or a bf16 op aborts on a missing function (`kernels/common.h`
`#undef`s the macro below Metal 3.1). The 14.0 floor is the library's, not
the app's: macOS 13.3 stays supported because on 13.x the patched ggml skips
the library and compiles the embedded sources instead. A macOS 26 SDK also
emits `<bin>-tensor.metallib`, the Metal4 kernel library, which
intentionally keeps its macOS 26 target (patch `0004`, `llamacpp/0001`).

The engines are built against different ggml trees whose kernel sources
differ, so one shared `default.metallib` cannot serve them all — each probes
`<argv[0] basename>.metallib` next to the binary, uses it only when it loads,
and otherwise falls back to the embedded source, compiling in-process on
first run (patch `0003`, `audiocpp/0003`, `llamacpp/0001`). The library is also refused on
macOS older than 14.0, where its AIR target cannot load, and on a
bfloat-capable device when `kernel_get_rows_bf16` is missing from its
function list — a library built without the bf16 define (a dev build, a flag
regression) falls back instead of aborting on the first bf16 op. Each
failure logs one line and is never fatal.

The toolchain check compiles and links a trivial kernel
(`xcrun -sdk macosx metal -c` + `metallib`), because on Xcode 26 `xcrun -f
metal` resolves a stub while the toolchain itself is a separate component
(`xcodebuild -downloadComponent MetalToolchain`). When the probe fails the
metallib build is skipped, says so on one line, and the engines still embed
their sources. `OX_SAY_METAL_EMBED=1` skips the metallib build even when the
toolchain is present (A/B tests).

## ox-diar (speaker diarization)

A one-shot CLI that tells the voices of one recording apart: `ox-diar <pcm16k-mono-s16le> <out.json> --models DIR`, where
the input is a meeting's raw channel file (the format of `them.pcm`) and DIR holds `speaker-diarization/` as
`scripts/fetch-models.sh --diar-only` lays it out. It is a Swift package (`engine/diar`) on FluidAudio 0.17.7 (pinned with
`exact:` and a committed `Package.resolved`), which runs the pyannote community-1 pipeline (segmentation, WeSpeaker,
PLDA, VBx) on Core ML: `.cpuAndNeuralEngine` on Apple Silicon, so the GPU stays free for Parakeet (`probe_gpu.sh` proves
it). There is no Intel build: Core ML cannot run the models on `.cpuOnly` (the Intel smoke of plan Task 20a failed), so
the x86_64 package carries none and the daemon reports `cpu_unsupported`. The configuration is pinned in `OxDiarCore/Config.swift` (AHC threshold 0.7, step 0.1, no 1 s floor
on a segment: the spike's `parity0`), where `swift test` reads it. The audio is read whole into memory and never written
to a temporary file (FluidAudio's file path would stream a float32 copy to the user's temporary directory). It never
touches the network (`ModelHub.offlineMode`), and it exits 5 on macOS older than 15, where Apple's BNNS bug can crash a
prediction (FluidAudio issue 878). Exit 0 also for silence (empty lists), 2 usage, 3 models, 4 input missing or empty.

The answer is `{version, duration_s, speakers:[{id, speech_s, embedding[256]}], segments:[{s, e, spk}], timing_s}`: the
exclusive timeline, ids 0..n-1 by descending speech, each embedding the cluster's VBx centroid. The daemon reads it
once, inside the meeting's `work/`, and the embeddings never reach the meeting directory (a voiceprint of people who
never agreed to one). Building it needs Xcode 26 (Swift 6.2) and the engine only runs on macOS 15 or later, so
`engine/build.sh` builds it when asked or able (`engine/want-diar.sh`). `test_cli.py` pins the contract and runs in CI on
both architectures, `swift test` the pure parts, `test_der.py` scores three AMI mixes against their references (not in
CI: it needs pyannote.metrics and the recordings).

## ox-llm (llama.cpp's llama-server)

The meeting-notes engine. `build.sh` builds `llama-server` from the llama.cpp
commit in `pins.env` and ships it as `ox-llm`: llama.cpp vendors a ggml newer
than whisper.cpp's, so none of `patches/ggml` applies — the same metallib
handling comes from `patches/llamacpp/0001` (the `0003`–`0005` port onto the
newer ggml), and the rename keeps the per-binary lookup
(`<argv[0]>.metallib`) working. The daemon starts it
with `-c 16384 -fa on --jinja --no-ui -np 1 --cache-ram 0 --api-key-file …`
(`internal/daemon/meetings.go`); the build fails if the pinned llama-server no
longer lists those flags. The model (Qwen3.5-4B Q4_K_M) is not part of the
package: `scripts/fetch-models.sh --notes-only` downloads it on first use.

## patches/ggml/0001-metal-amd-discrete-gpu.patch

Makes the ggml Metal backend correct and usable on GPUs without unified
memory and without simdgroup matrix multiply (Intel Macs with AMD GPUs):

- `memset_tensor` passed an end offset where `NSMakeRange` expects a length,
  overwriting the neighbouring tensors in private buffers.
- `set_tensor`/`get_tensor` wrapped arbitrary host pointers with
  `newBufferWithBytesNoCopy`, which needs page-aligned memory and returns nil
  otherwise; they now copy through a staging buffer and release it.
- Concurrent dispatch is disabled by default on non-UMA devices, where it
  produced wrong results; `GGML_METAL_CONCURRENCY_ENABLE` opts back in.
- A tiled threadgroup-memory GEMM kernel (`kernel_mul_mm_tg`) for devices
  without simdgroup matrix multiply, plus mat-vec and flash-attention
  routing that stays within what these devices compute correctly.

## Apple Silicon

`build.sh` builds for the shell's architecture (`uname -m`). On arm64 the same pins and the same
patches apply. On unified memory with simdgroup matrix multiply (every M-series GPU),
`0001-metal-amd-discrete-gpu.patch` is inert:
- its kernel routing is gated on `!has_simdgroup_mm`;
- its dispatch default is gated on `!has_unified_memory`;
- its staging copies are on the private-buffer path, which unified memory does not use.

Two parts of it do apply on Apple Silicon:
- the `memset_tensor` range fix, a bug fix on the private-buffer path
  (`GGML_METAL_SHARED_BUFFERS_DISABLE`);
- a larger flash-attention scratch reservation.

`0002-metal-mps-mul-mat.patch` never runs there (`!has_unified_memory`).

Verified on an Apple M5 Pro (macOS 26.5) at qwentts.cpp `6fae929` / ggml `40e16e4` and
whisper.cpp `6e4ab85`:
- `test-backend-ops test -b MTL0` for MUL_MAT, MUL_MAT_ID and FLASH_ATTN_EXT gives the same
  OK/FAIL set on the patched tree as on stock ggml (791, 796 and 4115 cases; FAIL: 0 on both).
  Cases that already flip between two stock runs (random inputs) are excluded — there were none.
- whisper.cpp's ggml has no test suite: there, `ox-stt` prints identical text for
  `samples/jfk.wav` on Metal and with `-ng`.

`OX_SAY_DIST=1` on arm64 targets the Apple M1 baseline (`-mcpu=apple-m1`, `GGML_NATIVE=OFF`;
dotprod, fp16). `scripts/check-arm64-baseline.sh` fails the build if the disassembly of a binary
has an i8mm (`smmla`, `usdot`, ...), BF16 (`bfdot`, `bfcvt`, ...), SME (`smstart`, `zero {za}`,
`rdsvl`, ZA tiles, `fmopa`, ...) or SVE (`addvl`, z- and p-registers) instruction, which a native
build on a newer chip emits. It also refuses anything the disassembler cannot decode (an older
Xcode's `otool` prints SME/SVE words as `.long 0x...`) and an empty disassembly, so a toolchain
that cannot see an instruction fails the build instead of passing it. `scripts/check-arm64-baseline_test.sh` assembles one probe per
instruction family (and M1-legal controls) and checks the guard against the real engine binaries.

## Speech length (#122, #91)

Measured on the pinned engine (qwentts `6fae929`, `qwen-talker-0.6b-base-Q8_0`, M-series Mac), sentences
of 1 to 55 text tokens, 5 voices per language (no voice, three same-language clones, one other-language
clone), seed 7, 315 requests. Speech runs at 12.5 frames/s.

| text, voices | takes | frames/token p50 | p99 | max | frames/char p50 | p99 | chars/token |
|---|---|---|---|---|---|---|---|
| en, en voices or none | 120 | 3.41 | 5.50 | 5.85 | 0.71 | 2.70 | 4.88 |
| en, ru voice | 30 | 4.37 | 16.40 | 20.00 | 0.88 | 7.83 | 4.88 |
| ru, ru voices or none | 132 | 2.70 | 5.53 | 10.00 | 0.94 | 3.23 | 2.94 |
| ru, en voice | 32 | 2.91 | 4.05 | 4.12 | 1.01 | 1.67 | 2.92 |

The high tails are 1 to 3 token texts ("Yes.", a name): a fixed lead and tail of silence dominates.
The shortest take that needed the most room was 20 frames per token at 2 tokens (40 frames, 3.2 s).
Long texts are slower per token than short ones are fast per frame: 600 to 3000 chars ran 2.0 to
2.8 frames/token (en 3002 chars: 1685 frames, 135 s; ru 2603 chars: 1805 frames, 144 s).

**Frame budget (patch 0003).** A request may emit at most `8 x text tokens + 60` frames (and never more
than `max_new_tokens`, default 2048). Every one of 314 normal takes ended at or under 57% of its
budget (the worst: 26 tokens, 152 frames, budget 268), so the bound is 1.76 times the slowest take
measured, and 8 frames/token is 1.4 times the slowest per-token rate of any sentence of 8 or more
tokens (5.85). The constant 60 frames (4.8 s) covers the lead and tail of a one-word take. A 3-word
request that runs away is stopped at under 7 s, not 164 s. The bound sits in the engine because only the
engine has the BPE token count and sees the talker not emitting EOS; the daemon can only guess from
characters (2.9 to 4.9 chars/token). Hitting the budget (or a `max_new_tokens` set by the caller) is an
error, not a short take: HTTP 502, type `generation_runaway` on the wav route, and a failed transfer on
the streaming (pcm) route, whose 200 has already gone out. The daemon counts both under
`/status` `tts_faults`. Natural runaways were seen twice in 630 requests (a Russian sentence with an
English voice ran the full 2048 frames = 163.84 s unpatched; with the patch one ru-voice sentence stopped
at 436 frames after 6 s). They are not reproducible on demand, so
`scripts/test-tts-frame-budget.sh` forces the same code path with `max_new_tokens: 5`.

**Long input.** Unpatched, a text the model cannot finish in 2048 frames comes back as a WAV of 163.84 s
with a 200 and no sign of the cut. Where it stops covering the text (transcribed with Parakeet, 16 kHz):

| text | chars | audio | EOS | words heard / in text | last words heard |
|---|---|---|---|---|---|
| en | 3002 | 134.8 s | yes | 542 / 542 | "...the animals out to the fields" (correct end) |
| en | 4165 | 163.84 s | no | 653 / 749 | "...the new version fixed the bridge" (mid-text) |
| ru | 1602 | 108.2 s | yes | 222 / 220 | correct end |
| ru | 2036 | 163.84 s | no | 279 / 279 | "...о цене на рыбку по линии" (end garbled) |
| ru | 2603 | 144.4 s | yes | 354 / 354 | correct end |
| ru | 3037 | 163.84 s | no | 368 / 413 | cut mid-text |
| ru | 4071 | 163.84 s | no | 343 / 554 | cut mid-text |

So Russian is cut or garbled from about 2000 chars and English from about 3300, both well under the
daemon's 5000-character limit; the point depends on the take's pace. The daemon therefore speaks
qwen3-tts input in pieces of at most 600 characters (`qwenChunkChars`, `internal/daemon/speak_split.go`),
cut at sentence ends, all on one seed, joined with 0.25 s of silence. 600 characters is 25 to 60 s of
audio, under a third of the cap.

## patches/qwentts/0003-frame-budget-runaway.patch

Adds `src/frame-budget.h` (`qt_frame_budget`, the constants above) and replaces the silent
`max_new_tokens` stop in `tts_engine_step` with a failed take: the request's budget is derived from
`PromptBuilderOutput::N_text` when the slot is admitted (logged as `Frame budget N (T text tokens, cap C)`),
and reaching it without EOS fails the take with `runaway: no end after N frames ...`. `tts-server`
answers that as `generation_runaway` (a typed error the daemon recognises) instead of a plain 502.
Verified by `scripts/test-tts-frame-budget.sh` against a built engine.

## patches/qwentts/0002-tts-server-local-only.patch

Upstream `tts-server` answers every origin (`Access-Control-Allow-Origin: *`),
so while it runs any web page can synthesize speech in a cloned voice, read
the audio and register voices. Here the ox-say daemon is its only client:
the CORS headers are gone and POST bodies must be JSON (no cross-site simple
request) — exactly `application/json`, case-insensitive, parameters allowed;
a prefix match would also accept `application/jsonx`. Methods other than GET,
HEAD, POST and DELETE are refused before any body is read (405), a request
carrying Transfer-Encoding or a POST without Content-Length gets 411. When
bound to loopback, which is how ox-say always starts it, the Host must be a
loopback literal or `localhost` (DNS rebinding). A non-loopback bind (LAN
use) gets no Host check, so there a rebinding page is same-origin.

## patches/qwentts/0001-fused-qkv-gateup-and-threads-env.patch

- Fuses the Q/K/V and gate/up projections into single matmuls at load time.
- `OV_N_THREADS` overrides the CPU thread count (default: half of
  `std::thread::hardware_concurrency()`). It is not an `OX_SAY_*` variable, so the installers do not
  carry it into the LaunchAgent; it applies when you run `tts-server` yourself.

## patches/ggml/0002-metal-mps-mul-mat.patch

On GPUs without unified memory and without simdgroup matrix multiply, plain
2D fp32-output `MUL_MAT` with fp32 activations and m, n, k >= 64 runs through
`MPSMatrixMultiplication`. On a Radeon Pro 5500M, MPS reaches 3.4-3.7 TFLOPS
in fp32 (about 85% of peak), against 0.8-1.2 TFLOPS for the tiled kernel;
its fp16 path is slow, so fp16 weights are widened into a scratch region
after dst by a small kernel first, at most 4M elements (16 MiB) at a time,
each block multiplied into its own dst columns. The scratch is reserved
through `get_alloc_size`, so it lives as long as dst: measured on whisper
large-v3-turbo, decode +19 MB, encode +5 MB and cross +52 MB of compute
buffer against the tiled kernel (unbounded widening had cost +268 MB on the
vocabulary projection). MPS encodes straight into the command buffer, so the
compute encoder is ended and reopened around it, with any open debug groups
restored.

**The path is opt-in: set `GGML_METAL_MPS_ENABLE`.** Any value turns it on,
including `0`, following ggml's presence-only convention for these variables.
Unset it to turn the path off; `GGML_METAL_MPS_DISABLE` wins over it. During a
stretch of sustained full CPU load, on a Radeon Pro 5500M, the path gave
wrong output in 7 of 8 runs over about 12 minutes. It hit both Parakeet and
the wav2vec2 aligner, the results differed from run to run, and every run
exited 0. Without MPS, the same inputs came out correct. The failure has not
reproduced since, even at 16 busy threads on a throttled CPU, and its cause
is not known (#14). Until it is, correct-and-slower is the default.

Measured idle on a 347 s file, MPS off against on:

| Model | MPS off | MPS on |
|---|---|---|
| Parakeet (f16) | 18.2 s | 10.9 s |
| MMS aligner | 68.2 s | 49.6 s |

The transcript was the same, and the emissions agreed within 0.004.

The daemon's engines inherit the variable from the LaunchAgent environment.
`scripts/install.sh` writes only `OX_SAY_*` variables, so if you add
`GGML_METAL_MPS_ENABLE` to the plist by hand, the next reinstall drops it and the
engines quietly fall back to the slower path.

`patches/ggml-tests/` holds test-backend-ops cases that reach this path
(stock cases never do); `build.sh` does not apply it. Apply it to the ggml
tree when bumping the pins and run
`GGML_METAL_MPS_ENABLE=1 test-backend-ops -o MUL_MAT -b MTL0`. Without the
variable the path is off, and the cases pass without ever reaching it.

Measured with the path enabled, on the whisper large-v3-turbo encoder
(whisper.cpp): 3.14 -> 1.89 s per 30 s window, and 83 -> 60 s on a 347 s file,
with a byte-identical transcript. The TTS codec decode is ~3.5% faster per
frame; the talker is unchanged.

## stt/ox-stt.cpp

`ox-stt` is speech-to-text on the pinned whisper.cpp (`WHISPER_COMMIT`), whose
vendored ggml takes the same `patches/ggml`. It reads a 16 kHz mono WAV and
prints JSON: `text`, `segments` and `words` (`w`, `s`, `e`, `p`; seconds).

- `--engine parakeet` (default): Parakeet TDT 0.6B v3, 25 European languages,
  punctuation and word timings. Long audio is cut into chunks of at most
  `--chunk-s` (30) seconds at the quietest 10 ms frame near each window's end:
  one graph per chunk keeps each GPU command buffer under the macOS watchdog
  of a display GPU, and the encoder cost linear in length.
- Edge context (#123, `stt/edge_pad.h`): Parakeet drops words when a decode
  window has no quiet context at its edges (a tight 1.4 s clip decodes empty,
  a 12 s session segment cut mid-speech loses 25-100 % of its words). Every
  chunk is decoded as 1 s of comfort noise, the chunk, 1 s of comfort noise,
  the noise 12 dB under the chunk's level: the mean power of its 10 ms frames
  above -60 dBFS, each clamped to the 90th-percentile frame + 10 dB, so one
  click cannot lift it. Frames at or under -80 dBFS at the chunk's own edges
  (digital silence, a fade, dither) get the same noise added; that bound is
  absolute, so quiet speech at an edge (a far speaker before a near one) is
  never touched. Token times are shifted back by the pad and clamped to the
  chunk; they sit on parakeet's 80 ms token grid of the padded signal, 40 ms
  off an unpadded decode's (a 0.96 s pad keeps the grid but lost more cuts).
  Tokens more than 0.5 s out in a pad are taken for noise and dropped
  (stderr: `dropped N token(s) decoded from the edge pad`); punctuation right
  after a kept piece stays with it. A chunk with no frame above -60 dBFS is
  decoded as it is, so silence stays empty. Hence `--chunk-s` is at most
  47.99 s. The feature pipeline was compared with NeMo's
  `FilterbankFeatures` and the model's own preprocessor config first: no
  mismatch that changes a decode (dither is training-only in NeMo; the
  per-feature statistics use one frame fewer than NeMo 2.3, measured
  without effect), so the cure is context, not a library patch. Residual:
  one-shot cuts every 0.5 s across a speaker change lose the second speaker
  in 1 of 94 windows (four take pairs), against 30 of 70 unpadded (three). Measured on an M5 Pro GPU:
  +5 ms per short clip (29 -> 34 ms), +11 ms per 30 s chunk (158 -> 169 ms).
  The token loop is `edge_pad::map_segment`, unit-tested in CI
  (`edge_pad_test.cpp`); `scripts/test-stt-edges.sh` is the model test
  (skips without the model).
- `--engine whisper`: Whisper large-v3-turbo, 99 languages, one segment per
  word (`max_len` 1, split on word), beam search 5.
- `-ng` runs on the CPU.
- `--serve --port N -m <parakeet>` keeps the model resident on loopback HTTP:
  `GET /health` and `POST /transcribe` (WAV body). With `--vad <silero>` it
  also serves `/sessions` for streaming dictation: the client posts raw
  float32 16 kHz PCM chunks, a Silero VAD per session cuts the stream at
  pauses (`segmenter.h`, 512-sample windows, hysteresis, 400 ms close, 12 s
  cap) and a single background worker decodes finished pieces under the same
  `decode_mu` as `/transcribe`. `POST /sessions` (application/json), `POST
  /sessions/<id>/audio` (octet-stream, <= 30 s), `POST
  /sessions/<id>/finish` (drains and closes), `DELETE /sessions/<id>`; at
  most 4 sessions, idle >120 s reaped. The startup probe requires the VAD
  model's window to be 512 samples — anything else exits before listening.
  Failure contract: a failed segment decode fails the whole session
  (`/audio` and `/finish` then answer 500 `"decode failed"`; `/finish`
  deletes it) — a failed decode is never reported as an empty segment, so
  on any non-200 the client uploads the whole recording to `/transcribe` or
  the daemon's one-shot route. `/audio` also answers 429 `"decode backlog"`
  once a session has more than 8 segments queued or decoding; that audio is
  not taken and may be retried. Fairness: `decode_mu` is shared, so a long
  `/transcribe` delays session decodes and the other way round — a `/finish`
  can hit its 60 s bound queued behind a very long one-shot.

Measured on a 347 s English interview (Radeon Pro 5500M, i9-9880H), with the
Parakeet f16 weights that were the default then: Parakeet 9.6 s on the GPU
(RTF 0.028) and 29.7 s on the CPU; Whisper turbo 60.5 s; faster-whisper
large-v3-turbo int8 (CPU) 103.6 s. Parakeet and Whisper share 853 and 858 words
in order with a reference transcript of 909.

## align/ox-align.cpp

`ox-align` is phase 1 of a forced aligner: it runs a wav2vec2 CTC checkpoint
on the same ggml tree as `ox-stt` and writes per-frame log-softmax emissions
(`[frames, vocab]` float32 `.npy`, 50 frames/s). Text normalization and the
Viterbi pass over the emissions stay outside the binary.

```
ox-align -m model.gguf -f audio.wav -o emissions.npy \
         [--window 30] [--context 2] [-t threads] [-ng] [--vocab vocab.json]
         [--no-normalize] [--dump-dir DIR]
ox-align -m model.gguf --info
```

`--window`/`--context` must be positive whole numbers of 20 ms frames
(window <= 600 s, context <= 10 s; a zero context can never satisfy the
conv stack's receptive field and is rejected at parse time).

**Normalization contract.** By default the input is zero-mean/unit-variance
normalized per window when the checkpoint's `do_normalize` says so — the HF
semantics. `--no-normalize` feeds raw samples instead. The production
aligner today feeds raw audio (`--no-normalize`; its ONNX export does not
normalize internally either — a x10 input gain changes 5% of frame argmaxes
there). Callers must pass the mode explicitly until an A/B on word-boundary
accuracy decides the default.

Outputs are write-or-nothing: content goes to `<path>.tmp` and is renamed
over `<path>` only on success. A run that exits non-zero leaves the
previous output file in place, so callers must check the exit code before
reading the emissions.

`--info` prints the hyperparameters and the checkpoint's
`ox_align.source_sha256` provenance hash as JSON without reading audio.
`--dump-dir DIR` writes the named stage activations of the first window as
`.npy` files for debugging; it is a flag, not an env var, so it cannot be
inherited by accident.

`engine/align/convert_wav2vec2.py` turns a Hugging Face `Wav2Vec2ForCTC`
checkpoint into the GGUF it reads (fp16/bf16 source tensors are upcast to
f32 at conversion; `ox_align.source_sha256` records a sha256 over every
file baked into the GGUF — `config.json`, `preprocessor_config.json`,
`vocab.json` and `model.safetensors`, each name+length framed, with a fixed
marker for files the converter can run without). `--ftype f16` stores the matmul
weights in f16. On the CPU backend they are upcast back to f32 at load —
ggml's f16 dot product would also quantize the activations — so CPU compute
is identical for both ftypes; f16 buys smaller files, not CPU speed. On
Metal the picture depends on the GPU. On the target AMD dGPU, every
mul_mat with more than 32 frames runs patch 0001's tiled kernel. That covers the
projections, the attention products and lm_head, and the kernel's tiles are
float. The exception is when patch 0002's opt-in MPS path takes the eligible 2D
projections: then it runs them in float32 after widening the f16 weights. A
short window falls back to mul_mv. Activations stay f32 on the tiled and MPS
paths, so f16 weights are kept as stored.
On Apple Silicon, `kernel_mul_mm_*` tiles the activations into `half`,
which is exactly the rounding the CPU upcast avoids. Two configurations
are supported:

- `feat_extract_norm: "layer"` + `do_stable_layer_norm: true` (pre-LN), e.g.
  `MahmoudAshraf/mms-300m-1130-forced-aligner`;
- `feat_extract_norm: "group"` + `do_stable_layer_norm: false` (post-LN),
  e.g. `facebook/wav2vec2-base-960h`.

### Model licenses — read before shipping

- `MahmoudAshraf/mms-300m-1130-forced-aligner` (MMS 300M, 24 layers,
  d = 1024): **CC-BY-NC-4.0 — non-commercial use only**.
- `facebook/wav2vec2-base-960h` (12 layers, d = 768): Apache-2.0.

Converting is a documented manual step; neither model is fetched by
`fetch-models.sh`. In a venv with `gguf`, `numpy` and `safetensors`:

```bash
python3 engine/align/convert_wav2vec2.py <hf-checkpoint-dir> out.gguf [--ftype f32|f16]
```

### Verification

`engine/align/test_oracle.py` compares emissions against HF transformers
`Wav2Vec2ForCTC` run in float64 on CPU. The gate is derived from the oracle
we did not choose: HF's own f32 forward deviates from its f64 result by
`hf32_err` (measured 2.3e-3-7.6e-3 across the cases on this aarch64 box,
3.2e-3 on the target Mac), so a fixed 2e-3 gate would sit below float32
noise — no correct implementation could meet it. Each case's gate is `max(base_tol, 2 * hf32_err)` with base
tolerances 2e-3 (f32) and 5e-3 (f16), argmax agreement >= 99.5%. Cached
references carry a sidecar (WAV sha256, `source_sha256`, windowing,
normalize mode); any mismatch fails instead of silently recomputing.
`--backend cpu|gpu` picks the backend; `--refs-only` runs without torch or
transformers on the host (numpy only), which is how the target Mac runs it.
`engine/align/test_cli.py` is the bad-input suite: corrupted GGUFs,
malformed `--window`/`--context`, empty WAV — each must fail cleanly with
the offending key named. Test audio is committed under `testdata/`
(LibriSpeech test-clean, CC-BY-4.0).

Measured on aarch64 Linux (CPU backend, `-t 4`; max Δ = max |log-prob
difference| vs the float64 oracle, argmax = per-frame argmax agreement):

| model | ftype | clip | max Δ | argmax | time |
|-------|-------|------|-------|--------|------|
| wav2vec2-base-960h | f32 | 10.4 s | 0.0016 | 1.000 | 39 s |
| wav2vec2-base-960h | f16 | 10.4 s | 0.0016 | 1.000 | 38 s |
| mms-300m-1130-forced-aligner | f32 | 10.4 s | 0.0003 | 1.000 | ~110-180 s |
| mms-300m-1130-forced-aligner | f16 | 10.4 s | 0.0003 | 1.000 | ~110-180 s |
| wav2vec2-base-960h | f32 | 70 s (3 windows) | 0.0020 | 1.000 | 116 s |

The f32/f16 rows run the same arithmetic on the CPU — f16 weights are
upcast at load — so identical times are expected; the earlier 184 s vs
106 s spread came from a contended box, not the dtype. For reference,
torch/transformers f32 runs the same 70 s clip in 44 s on this box — the
CPU backend is not faster than torch here; the win of this port is Metal
on the Mac and sharing the patched ggml stack with ox-stt.

Measured on the target Mac (Intel i9-9880H, Radeon Pro 5500M; max Δ vs
the float64 oracle, argmax = per-frame agreement):

| model | ftype | clip | backend | max Δ | argmax |
|-------|-------|------|---------|-------|--------|
| wav2vec2-base-960h | f32 | 10 s | Metal | 0.0045 | 1.000 |
| wav2vec2-base-960h | f32 | 10 s | CPU `-ng` | 0.0042 | 1.000 |
| mms-300m-1130-forced-aligner | f16 | 10 s | Metal | 0.0014 | 1.000 |
| wav2vec2-base-960h | f32 | 70 s | Metal | 0.0030 | 1.000 |

The Mac's own CPU backend sits at 0.0042 — above a fixed 2e-3 — because
HF float32 itself is 0.0032 away from HF float64 there. That is float32
noise on x86, not a Metal defect; the per-case `2 * hf32_err` gate
accounts for it.


