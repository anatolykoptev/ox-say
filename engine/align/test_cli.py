#!/usr/bin/env python3
"""Bad-input suite for ox-align: corrupted GGUFs, malformed flags, empty WAV.

Each case must exit with a code > 0 — never a signal — with stderr naming
the offending key, tensor or flag, and must leave no .npy or .tmp behind.
On aarch64 an integer division by zero does not trap, so the assertions are
on the stderr message, not only the exit code.

Corrupted GGUFs are rebuilt from the base f32 GGUF with the `gguf` package
into a temp dir.

Usage:
  python3 test_cli.py --ox-align build/engine/align-build/ox-align \
      --models-dir build/models --testdata engine/align/testdata
"""

import argparse
import os
import struct
import subprocess
import sys
import tempfile

GOOD_MODEL = "wav2vec2-base-960h-f32.gguf"
CLIP = "clip-short.wav"

# kv keys the corrupted-model builds override
KV_STRINGS = ("wav2vec2.feat_extract_norm", "wav2vec2.vocab_json",
              "ox_align.source_sha256")
KV_BOOLS = ("wav2vec2.do_stable_layer_norm", "wav2vec2.do_normalize",
            "wav2vec2.conv_bias")
KV_FLOATS = ("wav2vec2.layer_norm_eps",)
KV_UINTS = ("wav2vec2.hidden_size", "wav2vec2.num_hidden_layers",
            "wav2vec2.num_attention_heads", "wav2vec2.intermediate_size",
            "wav2vec2.vocab_size", "wav2vec2.num_conv_pos_embeddings",
            "wav2vec2.num_conv_pos_embedding_groups")
KV_ARRAYS = ("wav2vec2.conv_kernel", "wav2vec2.conv_stride",
             "wav2vec2.conv_dim")


def build_model(dst: str, src: str, kv_over: dict = None,
                drop: frozenset = frozenset(), tensor_over: dict = None):
    """Rewrite src into dst with kv_over applied to the metadata."""
    import numpy as np
    from gguf import GGUFReader, GGUFWriter

    kv_over = kv_over or {}
    tensor_over = tensor_over or {}
    r = GGUFReader(src)
    w = GGUFWriter(dst, "wav2vec2")
    w.add_name("test-corrupt")
    w.add_file_type(int(r.fields["general.file_type"].contents()))
    for key in KV_STRINGS:
        w.add_string(key, str(kv_over.get(key, r.fields[key].contents())))
    for key in KV_BOOLS:
        w.add_bool(key, bool(kv_over.get(key, r.fields[key].contents())))
    for key in KV_FLOATS:
        w.add_float32(key, float(kv_over.get(key, r.fields[key].contents())))
    for key in KV_UINTS:
        w.add_uint32(key, int(kv_over.get(key, r.fields[key].contents())))
    for key in KV_ARRAYS:
        w.add_array(key, list(kv_over.get(key, r.fields[key].contents())))
    for t in r.tensors:
        if t.name in drop:
            continue
        w.add_tensor(t.name, tensor_over.get(t.name, np.asarray(t.data)))
    w.write_header_to_file()
    w.write_kv_data_to_file()
    w.write_tensors_to_file()
    w.close()


def empty_wav(path: str):
    """A syntactically valid WAV with an empty data chunk."""
    fmt = struct.pack("<HHIIHH", 1, 1, 16000, 64000, 2, 16)
    riff = b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + \
        b"data" + struct.pack("<I", 0)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", len(riff)) + riff)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ox-align", required=True)
    ap.add_argument("--models-dir", required=True)
    ap.add_argument("--testdata", required=True)
    a = ap.parse_args()

    src = os.path.join(a.models_dir, GOOD_MODEL)
    wav = os.path.join(a.testdata, CLIP)
    if not os.path.exists(src) or not os.path.exists(wav):
        print(f"FAIL: need {src} and {wav}")
        return 1

    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        # corrupted models: (name, kv overrides, dropped tensors, want-stderr)
        vocab, d = 32, 768
        import numpy as np
        bad_models = [
            ("n_head0", {"wav2vec2.num_attention_heads": 0}, frozenset(),
             {}, "num_attention_heads"),
            # 0xFFFFFFFF reads back as -1 through the int kv path: passes the
            # divisibility check (768 % -1 == 0) — only the >0 gate stops it
            ("n_headneg", {"wav2vec2.num_attention_heads": 0xFFFFFFFF},
             frozenset(), {}, "num_attention_heads"),
            ("pos_groups0",
             {"wav2vec2.num_conv_pos_embedding_groups": 0}, frozenset(),
             {}, "num_conv_pos_embedding_groups"),
            ("stride0", {"wav2vec2.conv_stride": [0] * 7}, frozenset(),
             {}, "conv_stride"),
            ("lm_head", {}, frozenset(),
             {"lm_head.weight": np.zeros((vocab + 1, d), np.float32)},
             "lm_head.weight"),
            # conv_bias=true with no bias tensors in the file
            ("conv_bias", {"wav2vec2.conv_bias": True}, frozenset(),
             {}, "conv.bias"),
        ]
        models = {}
        for name, kvo, drop, tover, _ in bad_models:
            dst = os.path.join(tmp, f"bad-{name}.gguf")
            print(f"building {dst} ...", flush=True)
            build_model(dst, src, kvo, frozenset(drop), tover)
            models[name] = dst

        empty = os.path.join(tmp, "empty.wav")
        empty_wav(empty)

        cases = []
        for name, _, _, _, want in bad_models:
            cases.append((f"model:{name}", models[name], wav, [], want))
        cases += [
            ("flag:window-30.01", src, wav, ["--window", "30.01"], "--window"),
            ("flag:window-1e15", src, wav, ["--window", "1e15"], "--window"),
            ("flag:context-1.99", src, wav, ["--context", "1.99"], "--context"),
            ("wav:empty", src, empty, [], "no audio samples"),
        ]

        for tag, model, clip, extra, want in cases:
            out = os.path.join(tmp, f"out-{tag.replace(':', '-')}.npy")
            before = set(os.listdir(tmp))
            r = subprocess.run([a.ox_align, "-m", model, "-f", clip,
                                "-o", out, "-ng", *extra],
                               capture_output=True, text=True, timeout=600)
            after = set(os.listdir(tmp))
            left = [f for f in after - before
                    if f.endswith(".npy") or f.endswith(".tmp")]
            sig = r.returncode < 0
            # the offending key must be named on the error line, not merely
            # somewhere in the usage text that follows it
            err = r.stderr.split("\n", 1)[0]
            ok = (r.returncode > 0 and not sig and want in err
                  and not left)
            detail = (f"rc={r.returncode}"
                      + (f" (SIGNAL {-r.returncode})" if sig else "")
                      + f" stderr={r.stderr[-300:]!r} left={left}")
            print(f"{'PASS' if ok else 'FAIL'} {tag}: {detail}", flush=True)
            if not ok:
                failures.append(tag)

    print()
    if failures:
        print("FAILURES:", *failures)
        return 1
    print("all bad-input checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
