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
