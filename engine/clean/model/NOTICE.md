# NOTICE

This repository contains a Core ML conversion of **MossFormer2_SE_48K**, a speech-enhancement
network by Shengkui Zhao, Yukun Ma, Chongjia Ni, Chong Zhang, Hao Wang, Trung Hieu Nguyen,
Kun Zhou, Jiaqi Yip, Dianwen Ng and Bin Ma (Alibaba SLAB), published as part of
**ClearerVoice-Studio** (https://github.com/modelscope/ClearerVoice-Studio), licensed under the
Apache License, Version 2.0.

The original weights are distributed at `alibabasglab/MossFormer2_SE_48K` on Hugging Face
(revision `eff8c97925c8bec812af707814b3e5d777fd4503`); this repository publishes only the Core ML
conversion — no upstream weights are hosted here.

Per Apache-2.0 §4(b), the conversion modifies the computation graph as follows (all changes are
module surgery applied at conversion time; the checkpoint bytes are untouched):

- `no_rotary_cache`: rotary frequency tables are computed without the buffer cache
  (the traced slice-assignment is not convertible);
- `negative_pad`: `F.pad` calls with a negative pad are rewritten as narrow + pad, and the
  boolean key-padding mask is padded via float (the MIL pad op rejects negative pads and
  mis-types the padded bool);
- `einsum_as_matmul`: nine einsum equations are rewritten as broadcast/matmul (ellipsis
  einsums fail conversion and `'..., f -> ... f'` converts silently wrong);
- mixed precision: 600 of 4437 ops are kept in fp32 — the FSMN memory path behind each
  Gated_FSMN second norm and the linear-attention `k^T v` sums — selected by dataflow;
  everything else is fp16 (the `FP16ComputePrecision` op_selector `mixed_selector`).

The conversion and its supporting files are distributed under the Apache License, Version 2.0
(see `LICENSE`), consistent with the upstream licence.

ox-say voice cleanup · Anatolii Koptev · 2026
