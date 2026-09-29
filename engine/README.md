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

## patches/qwentts/0001-fused-qkv-gateup-and-threads-env.patch

- Fuses the Q/K/V and gate/up projections into single matmuls at load time.
- `QT_N_THREADS` overrides the CPU thread count.

## patches/ggml/0002-metal-mps-mul-mat.patch

On GPUs without unified memory and without simdgroup matrix multiply, plain
2D fp32-output `MUL_MAT` with fp32 activations and m, n, k >= 64 runs through
`MPSMatrixMultiplication`. On a Radeon Pro 5500M, MPS reaches 3.4-3.7 TFLOPS
in fp32 (about 85% of peak), against 0.8-1.2 TFLOPS for the tiled kernel;
its fp16 path is slow, so fp16 weights are widened into a scratch region
after dst (reserved through `get_alloc_size`) by a small kernel first.
MPS encodes straight into the command buffer, so the compute encoder is
ended and reopened around it, with any open debug groups restored.
`GGML_METAL_MPS_DISABLE` turns the path off.

Measured on the whisper large-v3-turbo encoder (whisper.cpp): 3.14 -> 1.89 s
per 30 s window, 347 s file 83 -> 60 s, byte-identical transcript. The TTS
codec decode is ~3.5% faster per frame; the talker is unchanged.
