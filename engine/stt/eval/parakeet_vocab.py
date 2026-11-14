"""Dump the SentencePiece pieces of a ggml Parakeet model file, one JSON list on stdout.

The model is the legacy ggml layout whisper.cpp's parakeet loader reads (src/parakeet.cpp): magic,
hparams, mel filters (n_mel, n_fb, floats), window (n, floats), TDT durations, then n_vocab and
<u32 len><bytes> per piece. Run with `python3 -I`.
"""
import json
import struct
import sys


def vocab(path):
    with open(path, "rb") as f:
        head = f.read(4096)
        # the mel filter block starts with n_mel=128, n_fb=257 right after the hparams
        at = head.find(struct.pack("<ii", 128, 257))
        if at < 0:
            raise SystemExit("mel filter header not found: not a parakeet ggml file")
        f.seek(at)
        n_mel, n_fb = struct.unpack("<ii", f.read(8))
        f.seek(n_mel * n_fb * 4, 1)
        (n_window,) = struct.unpack("<i", f.read(4))
        f.seek(n_window * 4, 1)
        # TDT durations: a few small ints, then n_vocab; find n_vocab as the first int32 equal to 8192
        pos = f.tell()
        probe = f.read(64)
        ints = struct.unpack("<16i", probe)
        k = ints.index(8192)
        f.seek(pos + 4 * k)
        (n_vocab,) = struct.unpack("<i", f.read(4))
        out = []
        for _ in range(n_vocab):
            (ln,) = struct.unpack("<I", f.read(4))
            out.append(f.read(ln).decode("utf-8", "replace"))
        return out


if __name__ == "__main__":
    json.dump(vocab(sys.argv[1]), sys.stdout, ensure_ascii=False)
