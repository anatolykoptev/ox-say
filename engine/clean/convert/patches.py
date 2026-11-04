"""Module-surgery patches for the Core ML conversion. Each function is listed in the report with
the failure it fixes; together they are the Apache-2.0 §4(b) list of changes on the HF card.
Ported from the Task 0/0b spike without its experiment gates (MF2_EXTRA, pad_as_concat,
no_group_padding): each was tried against the cpuOnly defect and had no effect (0b report).
"""
import os


def no_rotary_cache(net):
    """rotary_embedding_torch 0.8.3 RotaryEmbedding.forward writes `self.cached_freqs[:seq_len] = freqs` and
    `cached_freqs_seq_len.copy_(seq_len)` on first call. In a traced graph that is a slice-assignment on a buffer and
    coremltools raises `ValueError: No matching select or slice.` (torchir_passes.generate_tensor_assignment_ops).
    cache_if_possible=False computes the same freqs without touching the buffers (same maths)."""
    from rotary_embedding_torch import RotaryEmbedding
    n = 0
    for m in net.modules():
        if isinstance(m, RotaryEmbedding):
            m.cache_if_possible = False
            n += 1
    print(f"[patch no_rotary_cache] {n} RotaryEmbedding modules")


def negative_pad(net):
    """(Also pads the bool key-padding mask via float, see below.) FLASH_ShareA_FFConvM token shift does `F.pad(x_shift, (0, 0, 1, -1), value=0.)` (mossformer2_block.py:348).
    coremltools' pad op rejects a negative pad (`pad must be non-negative integer, got -1 at index 3`). Equivalent
    form: narrow the negative sides first (a slice), then pad the positive sides. Same maths, bit-identical values.
    Implemented as a `F` shim inside the mossformer2_block module namespace only (torch.nn.functional is untouched)."""
    import sys, torch, torch.nn.functional as TF

    class _F:
        def __getattr__(self, name):
            return getattr(TF, name)

        @staticmethod
        def pad(x, pad, mode="constant", value=None):
            if x.dtype == torch.bool:
                # the key-padding mask of the grouped attention (mossformer2_block.py:397): coremltools types a padded
                # bool as double and then rejects `~mask` (bitwise_not). Pad it as float, cast back to bool.
                return _F.pad(x.to(torch.float32), pad, mode=mode, value=float(value or 0)) > 0.5
            if all(p >= 0 for p in pad):
                return TF.pad(x, pad, mode=mode, value=value)
            assert mode == "constant"
            pad = list(pad)
            for i in range(0, len(pad), 2):
                dim = x.dim() - 1 - i // 2
                lo, hi = pad[i], pad[i + 1]
                start = -lo if lo < 0 else 0
                stop = x.shape[dim] + hi if hi < 0 else x.shape[dim]
                x = x.narrow(dim, start, stop - start)
                pad[i], pad[i + 1] = max(lo, 0), max(hi, 0)
            return TF.pad(x, pad, mode=mode, value=value)

    mod = sys.modules[type(next(m for m in net.modules() if type(m).__name__ == "FLASH_ShareA_FFConvM")).__module__]
    mod.F = _F()
    print("[patch negative_pad] shim installed in", mod.__name__)


def einsum_as_matmul(net):
    """coremltools 9.0 cannot convert the ellipsis einsums used by the net: '... d, h d -> ... h d' (OffsetScale),
    '... i d, ... j d -> ... i j' and '... i j, ... j d -> ... i d' (grouped attention) all raise
    `ValueError: perm should have the same length as rank(x)` (coremltools _utils.build_einsum_mil), and
    '..., f -> ... f' converts silently WRONG. Each equation the net uses is replaced by the equivalent
    broadcast/matmul (checked exact in float64 by the spike). Applied to the `einsum` name inside
    mossformer2_block and rotary_embedding_torch only; any equation not listed falls through to torch.einsum."""
    import sys, torch

    def fast(eq):
        eq = eq.replace(" ", "")
        if eq == "...ij,...jd->...id":
            return lambda a, b: torch.matmul(a, b)
        if eq == "bgnd,bgne->bgde":
            return lambda a, b: torch.matmul(a.transpose(-1, -2), b)
        if eq == "bgde,bgnd->bgne":
            return lambda a, b: torch.matmul(b, a)
        if eq == "bgnd,bgne->bde":
            return lambda a, b: torch.matmul(a.flatten(1, 2).transpose(-1, -2), b.flatten(1, 2))
        if eq == "bgnd,bde->bgne":
            return lambda a, b: torch.matmul(a, b.unsqueeze(1))
        if eq == "i,j->ij":
            return lambda a, b: a[:, None] * b[None, :]
        if eq == "...,f->...f":
            return lambda a, b: a.unsqueeze(-1) * b
        if eq == "...d,hd->...hd":
            return lambda a, b: a.unsqueeze(-2) * b
        if eq == "...id,...jd->...ij":
            return lambda a, b: torch.matmul(a, b.transpose(-1, -2))
        return None

    def shim(eq, *ops):
        f = fast(eq)
        return f(*ops) if f is not None else torch.einsum(eq, *ops)

    import rotary_embedding_torch.rotary_embedding_torch as rmod
    bmod = sys.modules[type(next(m for m in net.modules() if type(m).__name__ == "FLASH_ShareA_FFConvM")).__module__]
    bmod.einsum = shim
    rmod.einsum = shim
    print("[patch einsum_as_matmul] installed in", bmod.__name__, "and", rmod.__name__)


_FP32_REGION = {}


def fp32_region(block):
    """Op names that stay fp32 in the mixed-precision build. Found by dataflow, not by name: for every Gated_FSMN's second
    norm (a layer_norm fed by `add(mul(...), ...)`, the `x = x_v * x_u + input` of Gated_FSMN.forward) walk backwards through
    the producers until a silu or another layer_norm. That covers the FSMN memory path (project linear, depthwise conv,
    residual adds, the x_v * x_u product) whose activations reach 1e10 (range scan, fp16 max is 65504) and the norm that
    divides them back down. Everything after that norm is O(1)-O(700) and runs in fp16."""
    key = id(block)
    if key in _FP32_REGION:
        return _FP32_REGION[key]
    ops = list(block.operations)
    region, norms = set(), 0
    for o in ops:
        if o.op_type != "layer_norm":
            continue
        src = o.x.op
        if src is None or src.op_type != "add":
            continue
        if not any(v.op is not None and v.op.op_type == "mul" for v in (src.x, src.y)):
            continue
        norms += 1
        stack = [o]
        while stack:
            cur = stack.pop()
            if cur.name in region:
                continue
            region.add(cur.name)
            for v in cur.inputs.values():
                vs = v if isinstance(v, (list, tuple)) else [v]
                for x in vs:
                    p = getattr(x, "op", None)
                    if p is None or p.op_type in ("const", "silu", "layer_norm") or p.name in region:
                        continue
                    stack.append(p)
    # linear attention: lin_kv = einsum('b g n d, b g n e -> b d e', lin_k, v) / n sums over all n positions BEFORE the
    # division; the sum reaches 2.5e5 (> fp16 max 65504) on a 20 s window (Task 0b range scan), so
    # matmul -> mul(1/n) -> expand_dims stays fp32 (48 tiny matmuls).
    users = {}
    for o in ops:
        for v in o.inputs.values():
            for x in (v if isinstance(v, (list, tuple)) else [v]):
                p = getattr(x, "op", None)
                if p is not None:
                    users.setdefault(p.name, []).append(o)
    lin = 0
    for o in ops:
        if o.op_type != "matmul":
            continue
        us = users.get(o.name, [])
        if len(us) == 1 and us[0].op_type == "mul" and users.get(us[0].name) and all(u.op_type == "expand_dims" for u in users[us[0].name]):
            region.add(o.name); region.add(us[0].name); lin += 1
    # size trim: the UniDeepFsmn input linear (linear -> relu) stays well inside fp16 (range scan: only `project`, conv1 and the
    # adds exceed 65504), so its weights stay fp16 (saves 24 x 256x256 x 2 B of the download budget).
    trimmed = 0
    for o in ops:
        if o.op_type == "linear" and o.name in region:
            us = users.get(o.name, [])
            if len(us) == 1 and us[0].op_type == "relu":
                region.discard(o.name); trimmed += 1
    print(f"[mixed] trimmed {trimmed} input linears back to fp16", flush=True)
    print(f"[mixed] fp32 region: {len(region)} ops behind {norms} Gated_FSMN norms + {lin} linear-attention k^T v sums", flush=True)
    _FP32_REGION[key] = region
    return region


def mixed_selector(op):
    """ct.transform.FP16ComputePrecision op_selector: True = cast to fp16."""
    return op.name not in fp32_region(op.enclosing_block)
