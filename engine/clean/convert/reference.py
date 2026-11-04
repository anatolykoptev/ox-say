"""Reference pipeline for the MossFormer2_SE_48K Core ML converter (build-time only).

Loads the network exactly as ClearVoice does (so the weights are exactly the pinned checkpoint),
verifies the pinned SHA-256 of both checkpoint files, and computes the Kaldi fbank features the
model consumes. The chunking rules (20 s window / 15 s stride / end-aligned last window / tiled
short clip / 50 ms crossfade) live in the Swift engine (the engine, not this module); this module serves convert.py
(trace + the known-answer mask) and verify.py (fixture windows). It never runs at user runtime.
"""
import hashlib
import os
import struct
import tempfile

import numpy as np
import torch
import torchaudio

torch.backends.mps.is_available = lambda: False          # the reference is CPU, deterministic

# alibabasglab/MossFormer2_SE_48K at revision eff8c97925c8bec812af707814b3e5d777fd4503 (26 Nov 2024),
# (the pinned upstream revision; both checkpoint files are SHA-256 checked below).
CKPT_SHA256 = {
    "last_best_checkpoint.pt": "03692b9f773bbd6bb43b9c5a41f96b1e28affd66e13796b7bec66ad3d8b227c6",
    "last_best_checkpoint": "315744c841441f8831cb2f896e06102b4d864776bf272febaa30c639c903e1c0",
}
MODEL_NAME = "MossFormer2_SE_48K"
# The two shipped artifacts and the weight blob inside each; the manifest records the SHA-256 of both blobs.
WEIGHT_BLOBS = {
    "mlmodelc": MODEL_NAME + ".mlmodelc/weights/weight.bin",
    "mlpackage": MODEL_NAME + ".mlpackage/Data/com.apple.CoreML/weights/weight.bin",
}

SR, WIN, HOP, FFT, MELS = 48000, 1920, 384, 1920, 60
SCALE = 32768.0                                          # MossFormer2 expects waveform x 32768
# The fixed 20 s window (a fixed shape, so one Core ML model serves every clip): features [1,2496,180] -> mask [1,2496,961].
WIN20, STRIDE20, XFADE = 20 * SR, 15 * SR, SR // 20      # 960000 / 720000 / 2400 (50 ms)
FRAMES20 = 1 + (WIN20 - WIN) // HOP                      # 2496
BINS = FFT // 2 + 1                                      # 961

_REF_MAGIC = b"MF2REF01"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()


def load_net(checkpoint):
    """checkpoint: path to last_best_checkpoint.pt or to the directory that holds it.

    ClearVoice resolves `checkpoints/MossFormer2_SE_48K` relative to the cwd and downloads
    unpinned weights when `last_best_checkpoint` is absent, so both files are SHA-256 checked
    first, and a directory outside the `checkpoints/MossFormer2_SE_48K` layout is staged
    through a symlink under a temp root that is removed once the net is loaded.
    """
    # Absolute before anything else: a relative path would be resolved from the staging root by the
    # symlink, and the layout test below would see an empty dirname.
    checkpoint = os.path.abspath(checkpoint)
    ckpt_dir = checkpoint if os.path.isdir(checkpoint) else os.path.dirname(checkpoint)
    for name, want in CKPT_SHA256.items():
        p = os.path.join(ckpt_dir, name)
        assert os.path.isfile(p), f"missing checkpoint file {p} (ClearVoice would download unpinned weights instead)"
        got = sha256_file(p)
        assert got == want, f"checkpoint {name} sha256 {got} != pinned {want}"
    staging = None
    if os.path.basename(ckpt_dir) == MODEL_NAME and os.path.basename(os.path.dirname(ckpt_dir)) == "checkpoints":
        root = os.path.dirname(os.path.dirname(ckpt_dir))
    else:
        staging = tempfile.TemporaryDirectory(prefix="mf2-ckpt-")
        root = staging.name
        sub = os.path.join(root, "checkpoints")
        os.mkdir(sub)
        os.symlink(ckpt_dir, os.path.join(sub, MODEL_NAME))
    cwd = os.getcwd()
    os.chdir(root)
    try:
        from clearvoice import ClearVoice
        # ClearVoice reads the checkpoint with an eager torch.load (no mmap, no retained handle), so
        # the staging root is not needed once the constructor returns.
        cv = ClearVoice(task="speech_enhancement", model_names=[MODEL_NAME])
    finally:
        os.chdir(cwd)
        if staging is not None:
            staging.cleanup()
    net = cv.models[0].model
    net.eval()
    return net, cv


def features(scaled, dither=0.0, seed=None):
    """scaled: 1-D float tensor already x32768. Returns [frames, 180] (60 fbank, 60 delta, 60 delta-delta)."""
    if seed is not None:
        torch.manual_seed(seed)
    fb = torchaudio.compliance.kaldi.fbank(scaled.unsqueeze(0), dither=dither, frame_length=WIN / SR * 1000,
                                           frame_shift=HOP / SR * 1000, num_mel_bins=MELS, sample_frequency=SR,
                                           window_type="hamming")
    d1 = torchaudio.functional.compute_deltas(fb.T).T
    d2 = torchaudio.functional.compute_deltas(d1.T).T
    return torch.cat([fb, d1, d2], 1)


def torch_mask_fn(net):
    @torch.no_grad()
    def fn(feats):                       # feats [T,180] -> mask [T,961] float32 numpy
        out = net(feats.unsqueeze(0))
        return out[-1][0].detach().cpu().numpy().astype(np.float32)
    return fn


def synthetic_window(seed):
    """A seeded synthetic 20 s signal: the publishable known-answer clip (no recording, no licence
    question). Broadband noise under a random 0.2 s amplitude envelope plus formant-like tones, so
    the log-mel range stays speech-like. Deterministic from the seed. float32 mono 48 kHz, unscaled.
    """
    rng = np.random.RandomState(seed)
    t = np.arange(WIN20, dtype=np.float64) / SR
    env = np.interp(t, np.linspace(0.0, WIN20 / SR, 101), rng.rand(101) ** 2)
    x = rng.randn(WIN20) * env
    for f0 in (180.0, 320.0, 750.0, 1450.0):
        x += (0.05 + 0.1 * rng.rand()) * np.sin(2 * np.pi * f0 * t + 6 * rng.rand()) * (0.3 + env)
    x /= np.abs(x).max() / 0.2                          # about -14 dBFS peak
    return x.astype(np.float32)


def write_reference(path, feats, mask):
    """reference_window.bin: one self-describing binary the Swift engine reads without numpy —
    magic MF2REF01, uint32 LE n_frames, n_features, n_bins, reserved, then row-major float32
    features [T,180] and the fp32 PyTorch mask [T,961]."""
    t, nf = feats.shape
    _, nb = mask.shape
    with open(path, "wb") as f:
        f.write(_REF_MAGIC + struct.pack("<4I", t, nf, nb, 0))
        f.write(feats.astype("<f4").tobytes())
        f.write(mask.astype("<f4").tobytes())


def read_reference(path):
    d = open(path, "rb").read()
    assert d[:8] == _REF_MAGIC, "bad reference_window.bin magic"
    t, nf, nb, _ = struct.unpack("<4I", d[8:24])
    assert (t, nf, nb) == (FRAMES20, MELS * 3, BINS), f"reference_window.bin dims {(t, nf, nb)} != {(FRAMES20, MELS * 3, BINS)}"
    assert len(d) == 24 + 4 * t * (nf + nb), f"reference_window.bin length {len(d)} != {24 + 4 * t * (nf + nb)}"
    feats = np.frombuffer(d, "<f4", t * nf, 24).reshape(t, nf).copy()
    mask = np.frombuffer(d, "<f4", t * nb, 24 + 4 * t * nf).reshape(t, nb).copy()
    return feats, mask
