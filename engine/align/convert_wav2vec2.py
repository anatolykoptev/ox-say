#!/usr/bin/env python3
"""Convert a Hugging Face Wav2Vec2ForCTC checkpoint directory (config.json +
model.safetensors, plus preprocessor_config.json and vocab.json) into a GGUF
file for ox-align.

Usage: convert_wav2vec2.py <model_dir> <out.gguf> [--ftype f32|f16]

Tensors keep their HF names minus the common `wav2vec2.` prefix (several HF
names exceed ggml's 64-char tensor-name limit; stripping the shared prefix is
a bijective mapping and brings the longest name to 56 chars). With --ftype f16
the Linear (matmul) weights are stored as f16; norms, biases, convs and the
positional conv stay f32.

The positional conv embedding is stored in HF checkpoints as a weight_norm
parametrization (g, v). ggml has no weight_norm so it is materialized here:
W = g * v / ||v|| where the norm is taken over all dims EXCEPT dim 2 (the
kernel axis) — HF applies weight_norm(dim=2), and torch's _weight_norm calls
norm_except_dim(v, 2, dim). Verified empirically: loading
facebook/wav2vec2-base-960h with transformers and comparing conv.weight to
g*v/||v||_{dims 0,1} matches to 4.3e-6, while normalizing over dim 2 itself is
off by 7.6. Newer checkpoints store the pair as
`conv.parametrizations.weight.original0` (g) / `original1` (v), older ones as
`conv.weight_g` / `conv.weight_v`; both are accepted.
"""

import argparse
import json
import os
import sys

import numpy as np
from safetensors import safe_open

import gguf

KEY = "wav2vec2."


def read_json(model_dir: str, name: str):
    p = os.path.join(model_dir, name)
    if not os.path.exists(p):
        return None
    with open(p, "r", encoding="utf-8") as f:
        return json.load(f)


def main() -> int:
    ap = argparse.ArgumentParser(description="convert HF Wav2Vec2ForCTC to GGUF")
    ap.add_argument("model_dir")
    ap.add_argument("out")
    ap.add_argument("--ftype", choices=["f32", "f16"], default="f32")
    args = ap.parse_args()

    config = read_json(args.model_dir, "config.json")
    if config is None:
        sys.exit(f"{args.model_dir}: no config.json")
    prep = read_json(args.model_dir, "preprocessor_config.json") or \
        read_json(args.model_dir, "feature_extractor_config.json") or {}
    st_path = os.path.join(args.model_dir, "model.safetensors")
    if not os.path.exists(st_path):
        sys.exit(f"{args.model_dir}: no model.safetensors")

    tensors = {}
    with safe_open(st_path, framework="np") as f:
        for name in f.keys():
            tensors[name] = f.get_tensor(name)

    # --- positional conv: materialize weight_norm (see module docstring) ---
    base = "wav2vec2.encoder.pos_conv_embed.conv."
    for gname, vname in ((base + "weight_g", base + "weight_v"),
                         (base + "parametrizations.weight.original0",
                          base + "parametrizations.weight.original1")):
        if gname in tensors:
            g, v = tensors.pop(gname), tensors.pop(vname)
            # g has shape [1, 1, K]: torch.norm_except_dim keeps dim 2 and
            # reduces every other dim -> one scale per kernel position.
            w = v * g / np.sqrt((v.astype(np.float64) ** 2).sum(axis=(0, 1),
                                                              keepdims=True))
            tensors[base + "weight"] = w.astype(np.float32)
            break
    else:
        sys.exit("pos_conv_embed weight_norm params not found")

    # masked_spec_embed is only used for spec-augment during training
    tensors.pop("wav2vec2.masked_spec_embed", None)
    if config.get("add_adapter"):
        sys.exit("config has add_adapter=true: adapters are not supported")
    if config.get("feat_extract_norm") not in ("group", "layer"):
        sys.exit("unsupported feat_extract_norm: "
                 f"{config.get('feat_extract_norm')}")
    if config.get("feat_extract_activation") != "gelu" or \
            config.get("hidden_act") != "gelu":
        sys.exit("only gelu activations are supported")

    f16 = args.ftype == "f16"
    # matmul weights (Linear kernels) go f16; norms/biases/convs stay f32
    def is_matmul(name: str, t: np.ndarray) -> bool:
        if t.ndim != 2 or not name.endswith(".weight"):
            return False
        return (".attention." in name or ".feed_forward." in name or
                name in ("lm_head.weight",
                         "wav2vec2.feature_projection.projection.weight"))

    writer = gguf.GGUFWriter(args.out, "wav2vec2")
    writer.add_name(os.path.basename(os.path.abspath(args.model_dir)))
    writer.add_file_type(1 if f16 else 0)

    writer.add_string(KEY + "feat_extract_norm", config["feat_extract_norm"])
    writer.add_bool(KEY + "do_stable_layer_norm",
                    bool(config["do_stable_layer_norm"]))
    writer.add_bool(KEY + "do_normalize", bool(prep.get("do_normalize", True)))
    writer.add_bool(KEY + "conv_bias", bool(config.get("conv_bias", False)))
    writer.add_float32(KEY + "layer_norm_eps",
                       float(config.get("layer_norm_eps", 1e-5)))
    writer.add_uint32(KEY + "hidden_size", config["hidden_size"])
    writer.add_uint32(KEY + "num_hidden_layers", config["num_hidden_layers"])
    writer.add_uint32(KEY + "num_attention_heads",
                      config["num_attention_heads"])
    writer.add_uint32(KEY + "intermediate_size", config["intermediate_size"])
    writer.add_uint32(KEY + "vocab_size", config["vocab_size"])
    writer.add_array(KEY + "conv_kernel",
                     [int(x) for x in config["conv_kernel"]])
    writer.add_array(KEY + "conv_stride",
                     [int(x) for x in config["conv_stride"]])
    writer.add_array(KEY + "conv_dim",
                     [int(x) for x in config["conv_dim"]])
    writer.add_uint32(KEY + "num_conv_pos_embeddings",
                      config["num_conv_pos_embeddings"])
    writer.add_uint32(KEY + "num_conv_pos_embedding_groups",
                      config["num_conv_pos_embedding_groups"])
    vocab = read_json(args.model_dir, "vocab.json")
    if vocab is None:
        print("warning: no vocab.json; --vocab output will be unavailable",
              file=sys.stderr)
    else:
        writer.add_string(KEY + "vocab_json",
                          json.dumps(vocab, ensure_ascii=False))

    n16 = 0
    for name in sorted(tensors):
        t = tensors[name]
        if t.dtype != np.float32:
            sys.exit(f"{name}: unexpected dtype {t.dtype}")
        gname = name[len(KEY):] if name.startswith(KEY) else name
        if len(gname) >= 64:
            sys.exit(f"{name}: GGUF name {gname!r} exceeds 64 chars")
        if f16 and is_matmul(name, t):
            # the writer stores numpy dtype as the GGML type; cast ourselves
            writer.add_tensor(gname, t.astype(np.float16))
            n16 += 1
        else:
            writer.add_tensor(gname, t)

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()
    print(f"wrote {args.out}: {len(tensors)} tensors "
          f"({n16} f16), arch wav2vec2")
    return 0


if __name__ == "__main__":
    sys.exit(main())
