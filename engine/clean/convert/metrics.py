import numpy as np

def si_sdr(est, ref):
    est = np.asarray(est, np.float64); ref = np.asarray(ref, np.float64)
    est = est - est.mean(); ref = ref - ref.mean()
    a = (est @ ref) / (ref @ ref + 1e-12); t = a * ref; e = est - t
    return float(10 * np.log10((t @ t + 1e-12) / (e @ e + 1e-12)))

def mask_stats(a, b):  # masks [T,961]
    d = a.astype(np.float64) - b.astype(np.float64)
    return dict(mse=float((d ** 2).mean()), max_abs=float(np.abs(d).max()), p999=float(np.quantile(np.abs(d), 0.999)))

# Thresholds fixed before the measurements were taken. Verdict strings: PASS / WARN / FAIL.
def grade_mask(stats, precision):
    if precision == "fp32":
        if stats["mse"] <= 1e-7 and stats["max_abs"] <= 1e-3: return "PASS"
        return "WARN" if stats["mse"] <= 1e-5 else "FAIL"
    if stats["mse"] <= 1e-4 and stats["p999"] <= 0.05: return "PASS"
    return "WARN" if stats["mse"] <= 1e-3 else "FAIL"

def grade_sisdr(v, floor):
    thr = min(35.0, floor - 3.0)
    if v >= thr: return "PASS"
    return "WARN" if v >= 25.0 else "FAIL"

def grade_ecapa(c):
    return "PASS" if c >= 0.995 else ("WARN" if c >= 0.98 else "FAIL")

def grade_divergence(v):
    return "PASS" if v >= 25 else ("WARN" if v >= 15 else "FAIL")

def grade_speed(x):
    return "PASS" if x >= 10 else ("WARN" if x >= 5 else "FAIL")

def grade_mem(gib):
    return "PASS" if gib <= 1.0 else ("WARN" if gib <= 1.5 else "FAIL")
