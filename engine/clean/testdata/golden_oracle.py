"""The PyTorch oracle of the end-to-end golden: fp32 network, 20 s windows, 50 ms crossfades, torch.stft/istft.

Copied from ~/Developer/utilities/mossformer2-coreml-spike/reference.py (sha256 4cc4ef33dcb41f7dbcf76a5ea8433014f2886b3430cc5555691beeaccbc23289),
the functions `features`, `torch_mask_fn`, `_stft`, `_istft`, `enhance_window`, `plan20`, `fill20`, `windowed20`
and `windowed20_net` with their constants, unchanged, so the golden regenerates from this repo alone. Build-time only.
"""
import numpy as np
import torch
import torchaudio

torch.backends.mps.is_available = lambda: False          # the reference is CPU, deterministic

SR, WIN, HOP, FFT, MELS = 48000, 1920, 384, 1920, 60
SCALE = 32768.0

WIN20 = 20 * SR
STRIDE20 = 15 * SR
XFADE = SR // 20                                   # 50 ms = 2400 samples

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


def _stft(x):
    w = torch.hamming_window(WIN, periodic=False)
    return torch.stft(x, FFT, HOP, WIN, center=False, window=w, onesided=True, return_complex=True)


def _istft(c, n):
    w = torch.hamming_window(WIN, periodic=False)
    return torch.istft(c, FFT, HOP, WIN, center=False, window=w, onesided=True, length=n)


def enhance_window(scaled, mask_fn, dither=0.0, seed=None):
    """One window (any length >= 1920): features -> mask -> STFT -> apply -> iSTFT. Returns scaled-domain output."""
    f = features(scaled, dither, seed)
    m = torch.from_numpy(mask_fn(f))                       # [T,961]
    c = _stft(scaled) * m.T                                # [961,T]
    return _istft(c, scaled.shape[0])


def plan20(n):
    """Window start samples for a clip of n samples."""
    if n <= WIN20:
        return [0]
    count = 1 + -(-(n - WIN20) // STRIDE20)
    return [k * STRIDE20 for k in range(count - 1)] + [n - WIN20]


def fill20(x):
    """The first window's audio: the clip itself if >= 20 s, else its own audio tiled to 20 s."""
    if len(x) >= WIN20:
        return x
    return np.tile(x, -(-WIN20 // len(x)))[:WIN20]


def windowed20(x, win_fn):
    """x: float32 mono 48 kHz, unscaled. win_fn(window_scaled_tensor[960000], start_sample) -> scaled-domain output window
    (any array of 960000 samples). Returns the stitched output, same length as x."""
    n = len(x)
    starts = plan20(n)
    src = fill20(x)
    # global keep boundaries: the middle of each overlap
    mids = [(starts[i] + starts[i + 1] + WIN20) // 2 for i in range(len(starts) - 1)]
    half = XFADE // 2
    ramp = (np.arange(XFADE, dtype=np.float64) + 0.5) / XFADE
    out = np.zeros(max(n, WIN20), np.float64)
    for i, s in enumerate(starts):
        seg = src[s:s + WIN20] if len(x) >= WIN20 else src
        y = np.asarray(win_fn(torch.from_numpy(seg.astype(np.float32) * SCALE), s), np.float64) / SCALE
        assert len(y) == WIN20
        w = np.ones(WIN20, np.float64)                      # weight of this window over its own span
        if i > 0:                                           # fade in around mids[i-1]
            c = mids[i - 1] - s
            w[:c - half] = 0.0
            w[c - half:c + half] = ramp
        if i < len(starts) - 1:                             # fade out around mids[i]
            c = mids[i] - s
            w[c + half:] = 0.0
            w[c - half:c + half] = 1.0 - ramp
        out[s:s + WIN20] += w * y
    return out[:n].astype(np.float32)


def windowed20_net(x, mask_fn, dither=0.0, seed=None):
    """The network path of windowed20: features(dither, seed + window start) -> mask_fn -> STFT mask iSTFT per window."""
    def win(sc, s):
        return enhance_window(sc, mask_fn, dither, (seed + s) if seed is not None else None).numpy()
    return windowed20(x, win)
