// Tests for lag.h: plain asserts, no framework. Every check prints what
// failed and exits 1. Each test names the mutation that turns it RED.
#include "lag.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

static int failures = 0;

#define CHECK(cond, msg)                                                                          \
    do {                                                                                          \
        if (!(cond)) {                                                                            \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg);                          \
            ++failures;                                                                           \
        }                                                                                         \
    } while (0)

static const size_t SR = 16000;
static const size_t W = 16000;   // 1 s windows keep the test fast; the math is the same
static const int MAXLAG = 2000;  // +/-125 ms search

// A speech-like signal: syllable-rate envelope over a few detuned partials.
// Deterministic; loud enough (peak ~0.45 FS) for the voiced floor.
static std::vector<int16_t> speech(size_t n, unsigned seed) {
    std::vector<int16_t> x(n);
    for (size_t i = 0; i < n; ++i) {
        double t = static_cast<double>(i) / SR;
        double env = 0.5 + 0.5 * std::sin(2.0 * 3.14159265358979323846 * 4.3 * t + seed);
        env *= env;
        double s = 0.0;
        for (unsigned h = 1; h <= 4; ++h)
            s += std::sin(2.0 * 3.14159265358979323846 * (90.0 + 40.0 * seed) * h * t + h * seed) / h;
        x[i] = static_cast<int16_t>(14000.0 * env * s);
    }
    return x;
}

// capture[n] = render[n - shift]: positive shift = the echo trails the render.
static std::vector<int16_t> shifted(const std::vector<int16_t>& r, long shift) {
    std::vector<int16_t> c(r.size(), 0);
    for (size_t i = 0; i < r.size(); ++i) {
        long j = static_cast<long>(i) - shift;
        if (j >= 0 && j < static_cast<long>(r.size())) c[i] = r[j];
    }
    return c;
}

static double lag_at(const std::vector<oxaec::LagWindow>& l, size_t i) { return l.at(i).lag_ms; }

// RED if: the xcorr argmax picks t != lag, or the lag sign flips (the
// negative-shift case below must come out negative).
static void t_positive_lag() {
    std::vector<int16_t> r = speech(3 * W, 1);
    std::vector<int16_t> c = shifted(r, 960); // +60 ms
    std::vector<oxaec::LagWindow> l =
        oxaec::estimate_lags(r.data(), r.size(), c.data(), c.size(), W, MAXLAG, 40.0, 0.02);
    CHECK(l.size() == 3, "3 windows expected");
    CHECK(l[0].measured, "voiced window must be measured");
    CHECK(std::fabs(lag_at(l, 0) - 60.0) < 0.2, "lag should be +60 ms");
    CHECK(std::fabs(lag_at(l, 2) - 60.0) < 0.2, "lag should stay +60 ms");
}

static void t_negative_lag() {
    std::vector<int16_t> r = speech(3 * W, 2);
    std::vector<int16_t> c = shifted(r, -1280); // -80 ms: render stamped after the echo
    std::vector<oxaec::LagWindow> l =
        oxaec::estimate_lags(r.data(), r.size(), c.data(), c.size(), W, MAXLAG, 40.0, 0.02);
    CHECK(l[0].measured, "voiced window must be measured");
    CHECK(lag_at(l, 0) < 0.0, "a render stamped late must give a negative lag");
    CHECK(std::fabs(lag_at(l, 0) + 80.0) < 0.2, "lag should be -80 ms");
}

// RED if: an unvoiced window resets the carry to 0 or re-measures.
static void t_unvoiced_carries() {
    std::vector<int16_t> r = speech(W, 3);
    r.insert(r.end(), W, 0); // window 1: render silent
    std::vector<int16_t> tail = speech(W, 4);
    r.insert(r.end(), tail.begin(), tail.end());          // window 2: voiced again
    std::vector<int16_t> c = shifted(r, 960);
    std::vector<oxaec::LagWindow> l =
        oxaec::estimate_lags(r.data(), r.size(), c.data(), c.size(), W, MAXLAG, 40.0, 0.02);
    CHECK(l.size() == 3, "3 windows expected");
    CHECK(l[0].measured && std::fabs(lag_at(l, 0) - 60.0) < 0.2, "window 0 should measure +60 ms");
    CHECK(!l[1].measured && std::fabs(lag_at(l, 1) - 60.0) < 0.2,
          "unvoiced window must carry the previous lag");
    CHECK(l[2].measured, "voiced window must measure again");
}

// RED if: a leading silence keeps a stale nonzero carry, or measures it.
static void t_leading_silence_zero() {
    std::vector<int16_t> r(W, 0);
    std::vector<int16_t> tail = speech(W, 5);
    r.insert(r.end(), tail.begin(), tail.end());
    std::vector<int16_t> c = shifted(r, 960);
    std::vector<oxaec::LagWindow> l =
        oxaec::estimate_lags(r.data(), r.size(), c.data(), c.size(), W, MAXLAG, 40.0, 0.02);
    CHECK(!l[0].measured && lag_at(l, 0) == 0.0, "before the first measurement the lag is 0");
    CHECK(l[1].measured && std::fabs(lag_at(l, 1) - 60.0) < 0.2, "then +60 ms");
}

// RED if: a correlation made of pure noise still counts as a measurement
// (the min_score gate dropped).
static void t_noise_rejected() {
    std::vector<int16_t> r = speech(2 * W, 6);
    std::vector<int16_t> c(2 * W, 0); // capture never has the echo
    std::vector<oxaec::LagWindow> l =
        oxaec::estimate_lags(r.data(), r.size(), c.data(), c.size(), W, MAXLAG, 40.0, 0.02);
    CHECK(!l[0].measured, "a zero capture must not count as a measurement");
    CHECK(lag_at(l, 1) == 0.0, "lag stays 0 when nothing ever measured");
}

int main() {
    t_positive_lag();
    t_negative_lag();
    t_unvoiced_carries();
    t_leading_silence_zero();
    t_noise_rejected();
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("all checks passed\n");
    return 0;
}
