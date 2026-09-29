# Engine

`build.sh` clones qwentts.cpp at the commit in `pins.env`, checks that its
ggml submodule is at the recorded commit, applies the patches below and
builds a static `tts-server` with the Metal shader library embedded.

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

## patches/qwentts/0002-tts-server-local-only.patch

Upstream `tts-server` answers every origin (`Access-Control-Allow-Origin: *`),
so while it runs any web page can synthesize speech in a cloned voice, read
the audio and register voices. Here the ox-say daemon is its only client:
the CORS headers are gone and POST bodies must be JSON (no cross-site simple
request). When bound to loopback, which is how ox-say always starts it, the
Host must be a loopback literal or `localhost` (DNS rebinding). A non-loopback
bind (LAN use) gets no Host check, so there a rebinding page is same-origin.

## patches/qwentts/0001-fused-qkv-gateup-and-threads-env.patch

- Fuses the Q/K/V and gate/up projections into single matmuls at load time.
- `QT_N_THREADS` overrides the CPU thread count.

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
restored. `GGML_METAL_MPS_DISABLE` turns the path off.

`patches/ggml-tests/` holds test-backend-ops cases that reach this path
(stock cases never do); `build.sh` does not apply it. Apply it to the ggml
tree when bumping the pins and run `test-backend-ops -o MUL_MAT -b MTL0`.

Measured on the whisper large-v3-turbo encoder (whisper.cpp): 3.14 -> 1.89 s
per 30 s window, 347 s file 83 -> 60 s, byte-identical transcript. The TTS
codec decode is ~3.5% faster per frame; the talker is unchanged.

## stt/ox-stt.cpp

`ox-stt` is speech-to-text on the pinned whisper.cpp (`WHISPER_COMMIT`), whose
vendored ggml takes the same `patches/ggml`. It reads a 16 kHz mono WAV and
prints JSON: `text`, `segments` and `words` (`w`, `s`, `e`, `p`; seconds).

- `--engine parakeet` (default): Parakeet TDT 0.6B v3, 25 European languages,
  punctuation and word timings. Long audio is cut into chunks of at most
  `--chunk-s` (30) seconds at the quietest 10 ms frame near each window's end:
  one graph per chunk keeps each GPU command buffer under the macOS watchdog
  of a display GPU, and the encoder cost linear in length.
- `--engine whisper`: Whisper large-v3-turbo, 99 languages, one segment per
  word (`max_len` 1, split on word), beam search 5.
- `-ng` runs on the CPU.

Measured on a 347 s English interview (Radeon Pro 5500M, i9-9880H):
Parakeet 9.6 s on the GPU (RTF 0.028) and 29.7 s on the CPU; Whisper turbo
60.5 s; faster-whisper large-v3-turbo int8 (CPU) 103.6 s. Parakeet and Whisper
share 853 and 858 words in order with a reference transcript of 909.

## align/ox-align.cpp

`ox-align` is phase 1 of a forced aligner: it runs a wav2vec2 CTC checkpoint
on the same ggml tree as `ox-stt` and writes per-frame log-softmax emissions
(`[frames, vocab]` float32 `.npy`, 50 frames/s). Text normalization and the
Viterbi pass over the emissions stay outside the binary.

```
ox-align -m model.gguf -f audio.wav -o emissions.npy \
         [--window 30] [--context 2] [-t threads] [-ng] [--vocab vocab.json]
```

`engine/align/convert_wav2vec2.py` turns a Hugging Face `Wav2Vec2ForCTC`
checkpoint into the GGUF it reads; `--ftype f16` stores the matmul weights in
f16 (upcast back to f32 at load on the CPU backend — ggml's f16 dot product
would also quantize the activations — and kept f16 on Metal, where matmuls
run natively in f16). Two configurations are supported:

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
`Wav2Vec2ForCTC` run in float64 on CPU (HF's own f32 forward deviates ~3e-3
from its f64 result on these models, so the f64 run is the meaningful
reference for a 2e-3 gate). Test audio is committed under `testdata/`
(LibriSpeech test-clean, CC-BY-4.0).

Measured on aarch64 Linux (CPU backend, `-t 4`; max Δ = max |log-prob
difference| vs the float64 oracle, argmax = per-frame argmax agreement):

| model | ftype | clip | max Δ | argmax | time |
|-------|-------|------|-------|--------|------|
| wav2vec2-base-960h | f32 | 10.4 s | 0.0016 | 1.000 | 39 s |
| wav2vec2-base-960h | f16 | 10.4 s | 0.0016 | 1.000 | 38 s |
| mms-300m-1130-forced-aligner | f32 | 10.4 s | 0.0003 | 1.000 | 184 s |
| mms-300m-1130-forced-aligner | f16 | 10.4 s | 0.0003 | 1.000 | 106 s |
| wav2vec2-base-960h | f32 | 70 s (3 windows) | 0.0020 | 1.000 | 116 s |

For reference, torch/transformers f32 runs the same 70 s clip in 44 s on this
box — the CPU backend is not faster than torch here; the win of this port is
Metal on the Mac and sharing the patched ggml stack with ox-stt.


