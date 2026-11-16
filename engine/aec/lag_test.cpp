// Tests for lag.h: plain asserts, no framework. Every check prints what
// failed and exits 1. Each test names the mutation that turns it RED.
#include "lag.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <random>
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
static const size_t W6 = 96000;  // 6 s windows for the level-sweep: noise margins like production
static const int MAXLAG = 2000;  // +/-125 ms search
// The production gates (kMinScore/kMinPeakRatio in ox-aec.cpp), pinned here so
// the rejection cases exercise the values the binary actually uses.
static const double kProdMinScore = 0.016;
static const double kProdMinRatio = 1.3;

// A speech-like signal: one-pole filtered noise under a syllable-rate
// envelope — the same shape as test_cli.py's synth_far. Aperiodic, so the
// cross-correlation peak is unambiguous (a periodic carrier would tie every
// period and hand the argmax to noise).
static std::vector<int16_t> speech(size_t n, unsigned seed) {
    std::mt19937 rng(seed);
    std::normal_distribution<double> g(0.0, 1.0);
    std::vector<int16_t> x(n);
    double y = 0.0;
    const double a = 0.93;
    for (size_t i = 0; i < n; ++i) {
        double t = static_cast<double>(i) / SR;
        double env = 0.5 + 0.5 * std::sin(2.0 * 3.14159265358979323846 * 4.3 * t + seed);
        env *= env;
        y = a * y + (1 - a) * g(rng);
        double v = 42000.0 * env * y;
        x[i] = static_cast<int16_t>(std::max(-32768.0, std::min(32767.0, v)));
    }
    return x;
}

// Independent near-end noise at a given RMS.
static std::vector<int16_t> noise(size_t n, unsigned seed, double amp) {
    std::mt19937 rng(seed);
    std::normal_distribution<double> g(0.0, 1.0);
    std::vector<int16_t> x(n);
    for (size_t i = 0; i < n; ++i)
        x[i] = static_cast<int16_t>(std::max(-32768.0, std::min(32767.0, amp * g(rng))));
    return x;
}

static double rms(const std::vector<int16_t>& x) {
    double s = 0.0;
    for (int16_t v : x) s += static_cast<double>(v) * v;
    return std::sqrt(s / x.size());
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

// capture = near + echo at `db` relative to the near level, delayed `shift`.
static std::vector<int16_t> mix(const std::vector<int16_t>& render,
                                const std::vector<int16_t>& near_, long shift, double db) {
    double gain = std::pow(10.0, db / 20.0) * rms(near_) / rms(render);
    std::vector<int16_t> c(near_.size(), 0);
    for (size_t i = 0; i < c.size(); ++i) {
        double v = near_[i];
        long j = static_cast<long>(i) - shift;
        if (j >= 0 && j < static_cast<long>(render.size())) v += gain * render[j];
        c[i] = static_cast<int16_t>(std::max(-32768.0, std::min(32767.0, v)));
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
        oxaec::estimate_lags(r.data(), r.size(), c.data(), c.size(), W, MAXLAG, 40.0, 0.02, 1.3);
    CHECK(l.size() == 3, "3 windows expected");
    CHECK(l[0].measured, "voiced window must be measured");
    CHECK(std::fabs(lag_at(l, 0) - 60.0) < 0.2, "lag should be +60 ms");
    CHECK(std::fabs(lag_at(l, 2) - 60.0) < 0.2, "lag should stay +60 ms");
}

static void t_negative_lag() {
    std::vector<int16_t> r = speech(3 * W, 2);
    std::vector<int16_t> c = shifted(r, -1280); // -80 ms: render stamped after the echo
    std::vector<oxaec::LagWindow> l =
        oxaec::estimate_lags(r.data(), r.size(), c.data(), c.size(), W, MAXLAG, 40.0, 0.02, 1.3);
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
        oxaec::estimate_lags(r.data(), r.size(), c.data(), c.size(), W, MAXLAG, 40.0, 0.02, 1.3);
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
        oxaec::estimate_lags(r.data(), r.size(), c.data(), c.size(), W, MAXLAG, 40.0, 0.02, 1.3);
    CHECK(!l[0].measured && lag_at(l, 0) == 0.0, "before the first measurement the lag is 0");
    CHECK(l[1].measured && std::fabs(lag_at(l, 1) - 60.0) < 0.2, "then +60 ms");
}

// RED if: a correlation made of pure noise still counts as a measurement
// (the min_score gate dropped).
static void t_noise_rejected() {
    std::vector<int16_t> r = speech(2 * W, 6);
    std::vector<int16_t> c(2 * W, 0); // capture never has the echo
    std::vector<oxaec::LagWindow> l =
        oxaec::estimate_lags(r.data(), r.size(), c.data(), c.size(), W, MAXLAG, 40.0, 0.02, 1.3);
    CHECK(!l[0].measured, "a zero capture must not count as a measurement");
    CHECK(lag_at(l, 1) == 0.0, "lag stays 0 when nothing ever measured");
}

// RED if: a loud uncorrelated capture counts as a measurement. Mutating the
// score back to corr / E_render (render energy alone) makes it scale with the
// capture level: the 3x case then clears the floor and this goes red.
static void t_uncorrelated_loud_rejected() {
    const double ratios[] = {0.3, 1.0, 3.0};
    for (int i = 0; i < 3; ++i) {
        std::vector<int16_t> r = speech(2 * W6, 60 + i);
        std::vector<int16_t> c = noise(2 * W6, 900 + i, rms(r) * ratios[i]);
        std::vector<oxaec::LagWindow> l =
            oxaec::estimate_lags(r.data(), r.size(), c.data(), c.size(), W6, MAXLAG,
                                 40.0, kProdMinScore, kProdMinRatio);
        char msg[96];
        std::snprintf(msg, sizeof(msg), "uncorrelated capture at %.1fx render RMS measured a lag",
                      ratios[i]);
        CHECK(!l[0].measured && !l[1].measured, msg);
        CHECK(lag_at(l, 1) == 0.0, "unmeasured windows must not shift the lag");
    }
}

// RED if: a -25 dB echo at a negative lag is rejected. The level that used to
// die against the render-energy-only score.
static void t_weak_echo_negative_lag() {
    std::vector<int16_t> r = speech(2 * W6, 70);
    std::vector<int16_t> n = noise(2 * W6, 701, 9000.0);
    std::vector<int16_t> c = mix(r, n, -1280, -25.0); // -80 ms, echo -25 dB under near
    std::vector<oxaec::LagWindow> l =
        oxaec::estimate_lags(r.data(), r.size(), c.data(), c.size(), W6, MAXLAG,
                             40.0, kProdMinScore, kProdMinRatio);
    CHECK(l[0].measured, "a -25 dB echo at -80 ms must still measure");
    CHECK(lag_at(l, 0) < 0.0, "the weak echo's lag must stay negative");
    CHECK(std::fabs(lag_at(l, 0) + 80.0) < 1.0, "weak-echo lag should be -80 ms");
}

// RED if: any level in the -6..-30 dB band loses its lag, either sign. The
// level the review found rejected (-80 ms, -20 dB) sits inside it.
static void t_echo_levels() {
    const double dbs[] = {-6.0, -12.0, -18.0, -20.0, -25.0, -30.0};
    const long shifts[] = {960, -1280};
    for (long shift : shifts) {
        for (double dbv : dbs) {
            std::vector<int16_t> r = speech(2 * W6, static_cast<unsigned>(80 + shift + 1300));
            std::vector<int16_t> n = noise(2 * W6, static_cast<unsigned>(shift + 3000), 9000.0);
            std::vector<int16_t> c = mix(r, n, shift, dbv);
            std::vector<oxaec::LagWindow> l =
                oxaec::estimate_lags(r.data(), r.size(), c.data(), c.size(), W6, MAXLAG,
                                     40.0, kProdMinScore, kProdMinRatio);
            char msg[96];
            std::snprintf(msg, sizeof(msg), "echo at %+.0f dB, %+ld samples must measure", dbv, shift);
            CHECK(l[0].measured, msg);
            std::snprintf(msg, sizeof(msg), "lag at %+.0f dB should be %+.1f ms", dbv, shift / 16.0);
            CHECK(std::fabs(lag_at(l, 0) - shift / 16.0) < 1.0, msg);
        }
    }
}

int main() {
    t_positive_lag();
    t_negative_lag();
    t_unvoiced_carries();
    t_leading_silence_zero();
    t_noise_rejected();
    t_uncorrelated_loud_rejected();
    t_weak_echo_negative_lag();
    t_echo_levels();
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("all checks passed\n");
    return 0;
}
