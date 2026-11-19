#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 OxSay (anatolykoptev/ox-say). Licensed under the Apache License, Version 2.0
# (see LICENSE in this directory). This is OxSay's own script.
#
# The two key-mapping tables below (NEMO_TO_HF_WEIGHT_MAPPING, NEMO_TDT_WEIGHT_MAPPING) and
# convert_key() are reproduced from Hugging Face transformers,
# src/transformers/models/parakeet/convert_nemo_to_hf.py, Copyright 2025 The HuggingFace Inc.
# team, Apache License 2.0, https://github.com/huggingface/transformers. The copy we read is
# byte-identical to that file at commit f36c750069f0aef45179207a680b592f138450ec (git blob
# a18a328b3cf3e5517c4315ff831bbd6b3def5368, lines 41-61 and 64). No change was made to the tables.
"""Rebuild a NeMo-shaped .nemo archive from a HF-transformers Parakeet TDT checkpoint.

The key mapping is the forward mapping from transformers'
src/transformers/models/parakeet/convert_nemo_to_hf.py
(NEMO_TO_HF_WEIGHT_MAPPING lines 41-52, NEMO_TDT_WEIGHT_MAPPING lines 55-61, convert_key line 64,
load_and_convert_tdt_state_dict lines 357-373). It is a pure key rename: no transpose, reshape or
gate reorder is applied there, so nothing has to be undone besides the names.

We do not regex-invert. We apply the forward mapping to every key of the reference v3 NeMo
checkpoint, which gives a dict nemo_key -> hf_key, check it is injective, and invert THAT dict.

usage: hf2nemo.py --ref-nemo v3.nemo --hf model.safetensors --out out.nemo --workdir new-empty-dir
"""
import argparse, io, os, re, sys, tarfile, tempfile
import torch
from safetensors import safe_open

NEMO_TO_HF_WEIGHT_MAPPING = {
    r"encoder\.pre_encode\.conv\.": r"encoder.subsampling.layers.",
    r"encoder\.pre_encode\.out\.": r"encoder.subsampling.linear.",
    r"encoder\.pos_enc\.": r"encoder.encode_positions.",
    r"encoder\.layers\.(\d+)\.conv\.batch_norm\.": r"encoder.layers.\1.conv.norm.",
    r"decoder\.decoder_layers\.0\.(weight|bias)": r"ctc_head.\1",
    r"linear_([kv])": r"\1_proj",
    r"linear_out": r"o_proj",
    r"linear_q": r"q_proj",
    r"pos_bias_([uv])": r"bias_\1",
    r"linear_pos": r"relative_k_proj",
}
NEMO_TDT_WEIGHT_MAPPING = {
    r"decoder\.prediction\.embed\.": r"decoder.embedding.",
    r"decoder\.prediction\.dec_rnn\.lstm\.": r"decoder.lstm.",
    r"joint\.enc\.": r"encoder_projector.",
    r"joint\.pred\.": r"decoder.decoder_projector.",
    r"joint\.joint_net\.2\.": r"joint.head.",
}


def convert_key(key, mapping):
    for pattern, replacement in mapping.items():
        key = re.sub(pattern, replacement, key)
    return key


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref-nemo", required=True)
    ap.add_argument("--hf", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--workdir", required=True, help="new empty dir for extraction")
    a = ap.parse_args()

    os.makedirs(a.workdir, exist_ok=False)
    with tarfile.open(a.ref_nemo, "r") as tar:
        tar.extractall(a.workdir, filter="data")
    files = sorted(os.listdir(a.workdir))
    print("ref archive members:", files)
    ref = torch.load(os.path.join(a.workdir, "model_weights.ckpt"), map_location="cpu", weights_only=True)
    if "state_dict" in ref:
        ref = ref["state_dict"]
    print("ref nemo tensors:", len(ref))

    allmap = {**NEMO_TO_HF_WEIGHT_MAPPING, **NEMO_TDT_WEIGHT_MAPPING}
    fwd = {}
    skipped = []
    for k in ref:
        if k.endswith("featurizer.window") or k.endswith("featurizer.fb"):
            skipped.append(k)
            continue
        fwd[k] = convert_key(k, allmap)
    print("featurizer tensors (not in HF, taken from ref nemo):", skipped)
    inv = {}
    for k, h in fwd.items():
        assert h not in inv, f"mapping not injective: {h} <- {inv[h]} and {k}"
        inv[h] = k
    print("mapped nemo keys:", len(fwd), "-> hf keys:", len(inv))

    hf = {}
    with safe_open(a.hf, framework="pt", device="cpu") as f:
        meta = f.metadata()
        for k in f.keys():
            hf[k] = f.get_tensor(k)
    print("hf tensors:", len(hf), "dtypes:", sorted({str(t.dtype) for t in hf.values()}))

    hf_keys, inv_keys = set(hf), set(inv)
    missing = sorted(inv_keys - hf_keys)  # nemo keys with no HF source
    extra = sorted(hf_keys - inv_keys)    # HF tensors with no nemo destination
    print("NEMO keys with NO hf source (unfilled):", len(missing))
    for m in missing:
        print("   MISSING", inv[m], "<-", m, tuple(ref[inv[m]].shape), ref[inv[m]].dtype)
    print("HF extras with no nemo destination:", len(extra))
    for e in extra:
        print("   EXTRA", e, tuple(hf[e].shape), hf[e].dtype)

    new = {}
    shape_bad = []
    for h, k in inv.items():
        if h not in hf:
            continue
        t = hf[h]
        if tuple(t.shape) != tuple(ref[k].shape):
            shape_bad.append((k, tuple(ref[k].shape), tuple(t.shape)))
            continue
        new[k] = t.to(ref[k].dtype) if t.dtype != ref[k].dtype else t.clone()
    print("shape mismatches:", shape_bad)
    # unfilled keys: fall back to ref value but REPORT (should be only non-learned buffers)
    for h in missing:
        k = inv[h]
        print("   FALLBACK to ref value for", k)
        new[k] = ref[k].clone()
    for k in skipped:
        new[k] = ref[k].clone()
    assert not shape_bad, "shape mismatch"
    assert set(new) == set(ref), "key set differs from ref"
    # keep ref ordering (converter iterates state_dict order; names are what matter, order kept anyway)
    new = {k: new[k] for k in ref}

    # equality vs reference
    n_eq = n_close = n_diff = 0
    worst = (0.0, None)
    for k in ref:
        if k in missing or k in skipped:
            continue
        r, n = ref[k], new[k]
        if torch.equal(r, n):
            n_eq += 1
        else:
            d = (r.double() - n.double()).abs().max().item()
            rel = d / (r.double().abs().max().item() + 1e-30)
            if rel < 1e-2:
                n_close += 1
            else:
                n_diff += 1
            if d > worst[0]:
                worst = (d, k)
    print(f"vs ref nemo: bit-equal={n_eq} close(<1e-2 rel of max)={n_close} different={n_diff} worst abs diff={worst}")

    torch.save(new, os.path.join(a.workdir, "model_weights.ckpt"))
    with tarfile.open(a.out, "w") as tar:
        for fn in sorted(os.listdir(a.workdir)):
            tar.add(os.path.join(a.workdir, fn), arcname=fn)
    print("wrote", a.out)


if __name__ == "__main__":
    main()
