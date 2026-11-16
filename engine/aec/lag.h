#ifndef OX_AEC_LAG_H
#define OX_AEC_LAG_H

// Windowed cross-correlation lag estimation for ox-aec: pure C++17 with no
// webrtc-audio-processing dependency, so lag_test.cpp compiles it directly in
// the CI gate the way engine/stt's header tests do.
//
// The lag D of a window is how much later the echo appears in the capture
// file than the matching far-end audio in the render file: capture[n] echoes
// render[n - D]. It is positive when the echo trails the render stamp (the
// usual speaker path) and negative when the echo leads it (the render file
// was stamped late). AEC3 only cancels while the render leads the echo, so
// the caller shifts the capture by D - margin and feeds ProcessStream frames
// D - margin ahead of the matching ProcessReverseStream frames.

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace oxaec {

struct LagWindow {
    double lag_ms; // applied estimate in ms; carried forward when not measured
    bool measured; // the render was voiced and the correlation was confident
    bool voiced;   // the render window cleared the voiced floor at all
};

// Floor for the second-peak guard in lag_measure (the guard itself grows with
// the search radius: a real echo's impulse-response skirt widens the peak by
// ~125 ms at the production max_lag, so the sidelobe the peak is compared
// against must sit well outside it).
inline constexpr int kLagPeakGuard = 32;

inline size_t lag_next_pow2(size_t n) {
    size_t p = 1;
    while (p < n) p <<= 1;
    return p;
}

// Iterative radix-2 FFT over std::complex<double>; n must be a power of two.
inline void lag_fft(std::complex<double>* a, size_t n, bool invert) {
    const double PI = 3.14159265358979323846;
    for (size_t i = 1, j = 0; i < n; ++i) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j |= bit;
        if (i < j) std::swap(a[i], a[j]);
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        double ang = 2.0 * PI / static_cast<double>(len) * (invert ? -1.0 : 1.0);
        std::complex<double> wlen(std::cos(ang), std::sin(ang));
        for (size_t i = 0; i < n; i += len) {
            std::complex<double> w(1.0, 0.0);
            for (size_t k = 0; k < len / 2; ++k) {
                std::complex<double> u = a[i + k];
                std::complex<double> v = a[i + k + len / 2] * w;
                a[i + k] = u + v;
                a[i + k + len / 2] = u - v;
                w *= wlen;
            }
        }
    }
    if (invert) {
        double inv = 1.0 / static_cast<double>(n);
        for (size_t i = 0; i < n; ++i) a[i] *= inv;
    }
}

inline double lag_rms(const int16_t* p, size_t n) {
    if (n == 0) return 0.0;
    double s = 0.0;
    for (size_t i = 0; i < n; ++i) s += static_cast<double>(p[i]) * p[i];
    return std::sqrt(s / static_cast<double>(n));
}

// One cross-correlation pass: corr[t] = sum_n a[n] * b[n + t], evaluated for
// t in [0, t_max]. The buffers are power-of-two sized and mean-centered by the
// caller; the returned index maximizes the raw correlation. B's usable length
// is b_len, the rest of the N-point buffer is zero.
inline void lag_xcorr(const std::complex<double>* fa, const std::complex<double>* fb,
                      std::complex<double>* out, size_t n) {
    for (size_t i = 0; i < n; ++i) out[i] = std::conj(fa[i]) * fb[i];
    lag_fft(out, n, true);
}

// Estimate the lag for one window: corr[d] = sum_n a[n] * b[c0 + n + d],
// d in [-max_lag, +max_lag] samples. Returns the best d and sets *score to the
// correlation normalized by sqrt(E_render * E_capture) over the compared span —
// a Pearson-style coefficient in [-1, 1] that does not scale with the capture
// level, so a loud uncorrelated capture cannot pass where a quiet echo can.
// *peak_ratio gets s(d*) / s2 where s2 is the strongest score outside a guard
// around d*: a real echo is one dominant alignment while uncorrelated input is
// a flat landscape whose argmax barely exceeds its runner-up. The guard is a
// quarter of the search radius (at least kLagPeakGuard samples) so a real
// impulse response's skirt counts as part of the peak, not as the sidelobe.
inline int lag_measure(const int16_t* render, size_t render_n,
                       const int16_t* capture, size_t capture_n,
                       size_t w0, size_t window, int max_lag,
                       std::complex<double>* fa, std::complex<double>* fb,
                       std::complex<double>* work, size_t fft_n,
                       double* score, double* peak_ratio) {
    // A = render[w0, w0+window); B = capture[w0-max_lag, w0+window+max_lag)
    // clamped to the file. corr[d] = sum_n A[n] * B[n + d + max_lag].
    size_t a_len = std::min(window, render_n > w0 ? render_n - w0 : size_t(0));
    long c0 = static_cast<long>(w0) - max_lag;
    size_t b_len = window + 2 * static_cast<size_t>(max_lag);
    std::fill(fa, fa + fft_n, std::complex<double>(0.0, 0.0));
    std::fill(fb, fb + fft_n, std::complex<double>(0.0, 0.0));
    double am = 0.0, bm = 0.0;
    for (size_t i = 0; i < a_len; ++i) am += render[w0 + i];
    am /= static_cast<double>(a_len ? a_len : 1);
    for (size_t i = 0; i < b_len; ++i) {
        long idx = c0 + static_cast<long>(i);
        if (idx >= 0 && idx < static_cast<long>(capture_n)) bm += capture[idx];
    }
    bm /= static_cast<double>(b_len);
    for (size_t i = 0; i < a_len; ++i) fa[i] = render[w0 + i] - am;
    for (size_t i = 0; i < b_len; ++i) {
        long idx = c0 + static_cast<long>(i);
        if (idx >= 0 && idx < static_cast<long>(capture_n)) fb[i] = capture[idx] - bm;
    }
    lag_fft(fa, fft_n, false);
    lag_fft(fb, fft_n, false);
    lag_xcorr(fa, fb, work, fft_n);
    // corr[t] = sum_n A[n] * B[n + t]; the physical lag is t - max_lag. Terms
    // with n + t >= fft_n stay zero while fft_n >= window + 2*max_lag.
    double ea = 0.0;
    for (size_t i = 0; i < a_len; ++i) {
        double v = render[w0 + i] - am;
        ea += v * v;
    }
    // The compared capture span's energy per candidate lag, sliding by prefix
    // sums over the same mean-centered capture the FFT sees (out-of-file
    // positions are the zero fill the correlation treats them as). The score
    // s(t) = corr/sqrt(EA*EB(t)) is bounded by 1 (Cauchy-Schwarz over the same
    // terms) and independent of how loud the capture is.
    std::vector<double> pb(b_len + 1, 0.0);
    for (size_t i = 0; i < b_len; ++i) {
        long idx = c0 + static_cast<long>(i);
        double v = (idx >= 0 && idx < static_cast<long>(capture_n))
                       ? static_cast<double>(capture[idx]) - bm
                       : 0.0;
        pb[i + 1] = pb[i] + v * v;
    }
    std::vector<double> scores(2 * static_cast<size_t>(max_lag) + 1);
    int best_t = 0;
    double best_s = -1.0;
    for (int t = 0; t <= 2 * max_lag; ++t) {
        double eb = pb[t + a_len] - pb[t];
        double s = (ea > 0.0 && eb > 0.0) ? work[t].real() / std::sqrt(ea * eb) : 0.0;
        scores[t] = s;
        if (s > best_s) {
            best_s = s;
            best_t = t;
        }
    }
    *score = best_s;
    // The strongest score away from the winner. Uncorrelated input tops out at
    // ~1.05x its runner-up; a real echo stands several times taller, because
    // the second peak is just the next noise draw.
    const int guard = std::max(kLagPeakGuard, max_lag / 4);
    double second = 0.0;
    for (int t = 0; t <= 2 * max_lag; ++t) {
        if (std::abs(t - best_t) > guard && scores[t] > second) second = scores[t];
    }
    *peak_ratio = second > 0.0 ? best_s / second : (best_s > 0.0 ? 1e9 : 0.0);
    return best_t - max_lag;
}

// Per-window lag estimates over the render timeline: one value per
// `window`-sample window. Windows where the render is not voiced (RMS below
// voiced_floor, in int16 amplitude units) or the correlation is too weak keep
// the previous estimate; before the first measured window that is 0. A window
// counts as measured when its normalized score clears min_score and its
// peak-to-second-peak ratio clears min_ratio.
inline std::vector<LagWindow> estimate_lags(const int16_t* render, size_t render_n,
                                            const int16_t* capture, size_t capture_n,
                                            size_t window, int max_lag,
                                            double voiced_floor, double min_score,
                                            double min_ratio) {
    std::vector<LagWindow> out;
    if (window == 0 || render_n == 0) return out;
    size_t fft_n = lag_next_pow2(window + 2 * static_cast<size_t>(max_lag) + 1);
    std::vector<std::complex<double>> fa(fft_n), fb(fft_n), work(fft_n);
    int carry = 0;
    for (size_t w0 = 0; w0 < render_n; w0 += window) {
        size_t a_len = std::min(window, render_n - w0);
        bool voiced = lag_rms(render + w0, a_len) >= voiced_floor && capture_n > 0;
        bool measured = false;
        if (voiced) {
            double score = 0.0, ratio = 0.0;
            int d = lag_measure(render, render_n, capture, capture_n, w0, window,
                                max_lag, fa.data(), fb.data(), work.data(), fft_n,
                                &score, &ratio);
            if (score >= min_score && ratio >= min_ratio) {
                carry = d;
                measured = true;
            }
        }
        out.push_back({carry / 16.0, measured, voiced});
    }
    return out;
}

} // namespace oxaec

#endif // OX_AEC_LAG_H
