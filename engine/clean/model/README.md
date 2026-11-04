---
license: apache-2.0
library_name: coreml
pipeline_tag: audio-to-audio
base_model: alibabasglab/MossFormer2_SE_48K
base_model_relation: quantized
tags:
  - speech-enhancement
  - audio
  - coreml
  - apple-silicon
  - mossformer2
---

# MossFormer2_SE_48K — Core ML (mixed precision, 20 s window)

A Core ML conversion of Alibaba SLAB's **MossFormer2_SE_48K** speech-enhancement mask network
(ClearerVoice-Studio), built for the OxSay voice-cleanup feature on macOS (Apple Silicon and Intel). The model
takes a fixed 20 s feature window and returns an STFT magnitude mask; the audio front end
(Kaldi fbank, STFT/iSTFT, chunking) lives in the caller — see `config.json` for the exact
I/O contract.

## Model Details

- **Upstream:** `alibabasglab/MossFormer2_SE_48K` at revision
  `eff8c97925c8bec812af707814b3e5d777fd4503` (weights by Shengkui Zhao et al., Alibaba SLAB /
  ClearerVoice-Studio, Apache-2.0). Only this conversion is published here.
- **This build:** ML Program, macOS 13 deployment target, 55.26 M parameters.
  Input `features` float32 `[1, 2496, 180]` → output `mask` float32 `[1, 2496, 961]`
  (a ReLU mask, not bounded by 1).
- **Precision:** mixed — 600 of 4437 ops in fp32, the rest fp16.
- **Converter:** `engine/clean/convert/` of `anatolykoptev/ox-say` (Apache-2.0); rebuilds
  these bytes from the pinned checkpoint. See `PROVENANCE.md`.

## Uses

```swift
import CoreML

let cfg = MLModelConfiguration()
cfg.computeUnits = .cpuAndGPU            // required — see Limitations
let model = try MLModel(contentsOf: modelURL, configuration: cfg)

// features: MLMultiArray [1, 2496, 180] float32 — Kaldi fbank 60 + delta + delta-delta,
// dither 1.0, from a 20 s mono 48 kHz window scaled by 32768 (config.json).
let input = try MLDictionaryFeatureProvider(dictionary: ["features": MLFeatureValue(multiArray: features)])
let mask = try model.prediction(from: input).featureValue(for: "mask")!.multiArrayValue!
```

**Out of scope:** sample rates other than 48 kHz, streaming/low-latency enhancement,
separation or speaker extraction (this is the SE model only), and any use that expects
bounded [0,1] mask values — renormalise if you need one.

## Limitations

- **Apple Silicon requires `cpuAndGPU`.** On `cpuOnly` this mixed-precision build is *wrong* on
  Apple Silicon: the Core ML CPU fp16 runtime renders the first ~64 frames of each window as
  garbage (macOS 26.5.1, M5 Pro; a runtime defect with no minimal repro — the fp32 build is
  exact on CPU, so the conversion itself is sound). Never request `.cpuAndNeuralEngine` or
  `.all` — the ANE compile fails outright.
- **Intel:** measured on an i9-9880H with a Radeon Pro 5500M (macOS 26.6.2). The same build is
  correct on `cpuAndGPU` with the discrete GPU (7.9× real time, 2.2 GiB) and on `cpuOnly`
  (2.9×, 3.25 GiB) — the CPU fp16 defect does not appear there. Do **not** run it on an Intel
  integrated GPU (UHD 630: 0.22× and a 16.7 GiB footprint): pick the discrete, non-low-power
  Metal device via `preferredMetalDevice`, or `cpuOnly` when none exists.
- 48 kHz mono only. Verified on one machine per architecture; run the known-answer check below
  on every load.
- "Not for meetings" is a product rule of ox-say, not a property of this model.

## Known-answer self-check (run this after every load)

The download carries `reference_window.bin`: one fixed feature window `[1,2496,180]` plus
its expected mask, computed by the fp32 PyTorch reference on a seeded synthetic 20 s signal.
Its SHA-256 is recorded in `manifest.json` and `config.json` (`known_answer`).

After loading, run the stored features through the model and compare the result with the
stored mask: **mask MSE must be ≤ 1e-4** and contain no NaN. On a mismatch, refuse the
model — a Core ML runtime defect (like the cpuOnly one above) turns a silent garbage output
into a loud refusal. File format: magic `MF2REF01`, then uint32 LE `n_frames`, `n_features`,
`n_bins`, `reserved`, then row-major float32 features `[2496,180]` and mask `[2496,961]`.

## Conversion (Apache-2.0 §4(b) list of changes)

Converted 2026-11-03 by `engine/clean/convert/convert.py` at the pinned checkpoint
(SHA-256 `03692b9f…`). Module surgery on the traced graph; the checkpoint bytes are untouched:

1. `no_rotary_cache` — rotary frequency tables computed without the buffer cache
   (a traced slice-assignment coremltools rejects).
2. `negative_pad` — `F.pad` with a negative pad rewritten as narrow + pad; the boolean
   key-padding mask padded via float.
3. `einsum_as_matmul` — nine einsum equations rewritten as broadcast/matmul
   (checked exact in float64).
4. `mixed_selector` — fp32 kept on the FSMN memory path behind each Gated_FSMN second
   norm and on the 48 linear-attention `k^T v` sums (activations reach 1e10 and 2.5e5
   respectively, above the fp16 maximum); everything else fp16.

## Evaluation

Mask parity (a) and end-to-end parity (b) vs the fp32 PyTorch reference through the shared
20 s window / 15 s stride chunker, dither 1.0, on cpuAndGPU (Task 0b report, 2026-11-03):

| Clip | Mask MSE | SI-SDR (dB) | ECAPA cosine |
|---|---|---|---|
| A (30 s lav) | 2.98e-6 | 73.1 | 1.0000 |
| B (30 s loud party) | 2.65e-6 | 47.9 | 1.0000 |
| C (60 s concat) | 2.87e-6 | 47.3 | 1.0000 |
| 4 party clips, 20 s each | 2.21e-6 … 3.04e-6 | 48.0 … 58.7 | 1.0000 |
| A3 (3 s, tiled) | 2.48e-6 | 74.0 | 1.0000 |
| party clip, 7 s, tiled | 9.10e-6 | 44.4 | 0.9999 |

Speed on Apple **M5 Pro** (median of 200, Swift probe, model only): **68.6 ms per 20 s
window** (218× real time, 15 s of new audio per window), first prediction 7.06 s, peak
footprint 0.403 GiB. cpuOnly is not a fallback: 1.012 s/window *and* wrong output.

## Technical specs (what the caller must implement)

- **Features:** Kaldi fbank, 60 mel bins, frame length 40 ms, frame shift 8 ms, hamming
  window, dither 1.0 (fixed-seed Gaussian, σ 1.0 in the ×32768 domain, seeded per window),
  plus delta and delta-delta → 180 features/frame.
- **Scaling:** waveform × 32768 before fbank and STFT; ÷ 32768 after iSTFT.
- **STFT:** FFT 1920, hop 384, win 1920, hamming periodic=False, center=False, onesided —
  961 bins; mask multiplies magnitude.
- **Window:** fixed 20 s = 960 000 samples = 2496 frames. Stride 15 s.
- **Chunking:** the last window is end-aligned (`start = n − 20 s`); a clip shorter than
  20 s is filled by tiling its own audio, never zero padding; windows splice at the middle
  of each overlap with a 50 ms linear crossfade.

## Pitfalls found during conversion

- **Pure fp16 returns an all-zero mask.** Nothing raises; the output is simply zero.
  The mixed-precision region exists because of this.
- **`einsum('..., f -> ... f')` converts silently wrong** in coremltools 9.0 — the graph
  builds, the numbers are garbage. The converter asserts zero `einsum` nodes in both the
  traced graph and the MIL program.
- **Never zero-pad a short clip.** Tiling its own audio scored 19.6 dB SI-SDR vs 1.5 dB
  for zero padding on a 3 s party clip.
- **cpuOnly garbage is silent too** (see Limitations) — which is why the known-answer
  check above exists.

## Citation

```bibtex
@misc{zhao2024mossformer2combiningtransformerrnnfree,
      title={MossFormer2: Combining Transformer and RNN-Free Recurrent Network for Enhanced Time-Domain Monaural Speech Separation},
      author={Shengkui Zhao and Yukun Ma and Chongjia Ni and Chong Zhang and Hao Wang and Trung Hieu Nguyen and Kun Zhou and Jiaqi Yip and Dianwen Ng and Bin Ma},
      year={2024},
      eprint={2312.11825},
      archivePrefix={arXiv},
      primaryClass={cs.SD},
      url={https://arxiv.org/abs/2312.11825},
}

@misc{zhao2025clearervoicestudiobridgingadvancedspeech,
      title={ClearerVoice-Studio: Bridging Advanced Speech Processing Research and Practical Deployment},
      author={Shengkui Zhao and Zexu Pan and Bin Ma},
      year={2025},
      eprint={2506.19398},
      archivePrefix={arXiv},
      primaryClass={cs.SD},
      url={https://arxiv.org/abs/2506.19398},
}
```
