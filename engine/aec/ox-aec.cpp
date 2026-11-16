// ox-aec: offline echo cancellation for a meeting's two recorded channels.
//
//   ox-aec --capture me.pcm --render them.pcm --out me.aec.pcm [--report report.json]
//
// Both inputs are raw s16le mono 16 kHz on one timeline: sample N of one file
// is the same instant as sample N of the other. They may differ in length;
// the shorter span is processed and any capture tail passes through
// unchanged. The output is the echo-cancelled capture, on the capture's own
// timeline: same length, same index = same instant.
//
// Alignment first: AEC3 cancels only while the render reference leads the
// echo in the capture stream, and the two files' stamps can disagree by a
// negative lag as well as a positive one. estimate_lags() (lag.h) finds the
// coarse lag per 10 s window by cross-correlation over voiced render; the
// capture is fed to ProcessStream shifted so the render leads the echo by
// MARGIN_MS, and set_stream_delay_ms gets that residual margin.
//
// The capture file is never opened for writing, and --out equal to --capture
// or --render is refused.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

#include "api/scoped_refptr.h"
#include "modules/audio_processing/include/audio_processing.h"
#include "api/audio/audio_processing_statistics.h"

#include "lag.h"

namespace {

constexpr int kRate = 16000;
constexpr int kFrame = 160;              // 10 ms
constexpr int kWindow = 160000;          // 10 s lag-estimation window
constexpr int kMaxLag = 8000;            // +/-500 ms correlation search range
constexpr int kMarginMs = 15;
constexpr int kMargin = kMarginMs * kRate / 1000; // render-lead margin, samples
constexpr double kVoicedFloor = 40.0;    // int16 RMS, ~-56 dBFS
// Lag-measurement gates, picked from the score/second-peak distributions of the
// synthetic fixture (see engine/aec/test_cli.py and lag_test.cpp): uncorrelated
// capture tops out at a normalized score ~0.011 and a peak ratio ~1.05; a -30 dB
// echo still scores ~0.025 with a ratio ~1.6.
constexpr double kMinScore = 0.016;      // normalized xcorr floor for a measured lag
constexpr double kMinPeakRatio = 1.3;    // peak vs runner-up score floor
constexpr int kSilencePeak = 128;        // whole-file render peak -> no_render
constexpr int kApmLatencyMax = 3200;     // sanity bound for the measured APM delay, samples
constexpr int kApmLatencyFallback = 128; // used only when the startup probe fails

const char* kUsage =
    "usage: ox-aec --capture me.pcm --render them.pcm --out me.aec.pcm [--report report.json]";

bool read_pcm(const char* path, std::vector<int16_t>& out) {
    FILE* f = std::fopen(path, "rb");
    if (!f) {
        std::fprintf(stderr, "ox-aec: cannot open %s: %s\n", path, std::strerror(errno));
        return false;
    }
    if (std::fseek(f, 0, SEEK_END) != 0) {
        std::fprintf(stderr, "ox-aec: cannot seek %s\n", path);
        std::fclose(f);
        return false;
    }
    long size = std::ftell(f);
    if (size < 0 || std::fseek(f, 0, SEEK_SET) != 0) {
        std::fprintf(stderr, "ox-aec: cannot measure %s\n", path);
        std::fclose(f);
        return false;
    }
    if (size % 2) {
        std::fprintf(stderr, "ox-aec: %s has an odd byte count; s16le mono expected\n", path);
        std::fclose(f);
        return false;
    }
    out.resize(static_cast<size_t>(size) / 2);
    bool ok = out.empty() || std::fread(out.data(), 2, out.size(), f) == out.size();
    if (!ok) std::fprintf(stderr, "ox-aec: short read on %s\n", path);
    std::fclose(f);
    return ok;
}

bool write_pcm(const char* path, const std::vector<int16_t>& data) {
    FILE* f = std::fopen(path, "wb");
    if (!f) {
        std::fprintf(stderr, "ox-aec: cannot write %s: %s\n", path, std::strerror(errno));
        return false;
    }
    bool ok = data.empty() || std::fwrite(data.data(), 2, data.size(), f) == data.size();
    if (std::fclose(f) != 0) ok = false;
    if (!ok) std::fprintf(stderr, "ox-aec: failed writing %s\n", path);
    return ok;
}

// The path as a canonical string for equality checks: realpath when the file
// exists, else realpath of the parent directory plus the basename.
std::string canon_path(const char* path) {
    char buf[4096];
    if (realpath(path, buf)) return buf;
    std::string s(path);
    size_t slash = s.rfind('/');
    std::string dir = slash == std::string::npos ? "." : s.substr(0, slash);
    std::string base = slash == std::string::npos ? s : s.substr(slash + 1);
    if (realpath(dir.c_str(), buf)) return std::string(buf) + "/" + base;
    return s;
}

// The one APM configuration, shared by the latency probe and the production
// instance so the measured delay belongs to the pipeline that actually runs.
webrtc::AudioProcessing::Config apm_config() {
    webrtc::AudioProcessing::Config cfg;
    cfg.echo_canceller.enabled = true;
    cfg.echo_canceller.mobile_mode = false;
    cfg.high_pass_filter.enabled = true;
    cfg.noise_suppression.enabled = false;
    cfg.gain_controller1.enabled = false;
    cfg.gain_controller2.enabled = false;
    return cfg;
}

// ProcessStream's output trails its input by a fixed pipeline delay (measured
// 128 samples on this AEC3 build). Writing each emitted frame back where its
// input was fed shifts every timestamp by that delay, so the delay is measured
// here, not assumed: a known noise burst goes through a throwaway APM built
// with the production config and the shift of its correlation peak is the
// latency. Returns -1 when the peak cannot be found.
int measure_apm_latency() {
    rtc::scoped_refptr<webrtc::AudioProcessing> apm = webrtc::AudioProcessingBuilder().Create();
    if (!apm) return -1;
    webrtc::AudioProcessing::Config cfg = apm_config();
    apm->ApplyConfig(cfg);
    webrtc::StreamConfig sc(kRate, 1);

    const int lead = 4, burst = 8, tail = kApmLatencyMax / kFrame + 4;
    std::vector<int16_t> fed((lead + burst + tail) * kFrame, 0);
    uint32_t x = 0x9e3779b9u; // xorshift32: a deterministic, white-ish burst
    for (int i = lead * kFrame; i < (lead + burst) * kFrame; ++i) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        fed[i] = static_cast<int16_t>(x >> 4);
    }
    std::vector<int16_t> emitted;
    emitted.reserve(fed.size());
    int16_t rbuf[kFrame] = {0}, cbuf[kFrame];
    for (size_t k = 0; k < fed.size(); k += kFrame) {
        std::memcpy(cbuf, fed.data() + k, kFrame * 2);
        apm->ProcessReverseStream(rbuf, sc, sc, rbuf);
        if (apm->ProcessStream(cbuf, sc, sc, cbuf) != 0) return -1;
        emitted.insert(emitted.end(), cbuf, cbuf + kFrame);
    }
    const int b0 = lead * kFrame, bn = burst * kFrame;
    double eb = 0.0;
    for (int i = 0; i < bn; ++i) eb += static_cast<double>(fed[b0 + i]) * fed[b0 + i];
    int best_d = -1;
    double best_c = 0.0;
    for (int d = b0; d <= b0 + kApmLatencyMax; ++d) {
        double v = 0.0, ee = 0.0;
        for (int i = 0; i < bn; ++i) {
            double e = static_cast<double>(emitted[d + i]);
            v += static_cast<double>(fed[b0 + i]) * e;
            ee += e * e;
        }
        double c = ee > 0.0 ? v / std::sqrt(eb * ee) : 0.0;
        if (c > best_c) {
            best_c = c;
            best_d = d;
        }
    }
    if (best_d < 0 || best_c < 0.5) return -1;
    return best_d - b0;
}

void json_num(FILE* f, double v) {
    if (v == static_cast<double>(static_cast<long long>(v)) && std::abs(v) < 1e15)
        std::fprintf(f, "%lld", static_cast<long long>(v));
    else
        std::fprintf(f, "%.6g", v);
}

void json_opt(FILE* f, const std::optional<double>& v) {
    if (v) json_num(f, *v); else std::fputs("null", f);
}

void json_opt(FILE* f, const std::optional<int32_t>& v) {
    if (v) json_num(f, *v); else std::fputs("null", f);
}

} // namespace

int main(int argc, char** argv) {
    const char* capture_path = nullptr;
    const char* render_path = nullptr;
    const char* out_path = nullptr;
    const char* report_path = nullptr;
    for (int i = 1; i < argc; ++i) {
        auto take = [&](const char* flag, const char** dst) -> bool {
            if (std::strcmp(argv[i], flag) == 0 && i + 1 < argc) {
                *dst = argv[++i];
                return true;
            }
            return false;
        };
        if (take("--capture", &capture_path) || take("--render", &render_path) ||
            take("--out", &out_path) || take("--report", &report_path)) {
            continue;
        }
        std::fprintf(stderr, "%s\n", kUsage);
        return 2;
    }
    if (!capture_path || !render_path || !out_path) {
        std::fprintf(stderr, "%s\n", kUsage);
        return 2;
    }

    std::string out_canon = canon_path(out_path);
    if (out_canon == canon_path(capture_path) || out_canon == canon_path(render_path)) {
        std::fprintf(stderr, "ox-aec: --out must differ from --capture and --render\n");
        return 2;
    }
    if (report_path &&
        (out_canon == canon_path(report_path) || canon_path(capture_path) == canon_path(report_path) ||
         canon_path(render_path) == canon_path(report_path))) {
        std::fprintf(stderr, "ox-aec: --report must differ from --capture, --render and --out\n");
        return 2;
    }

    std::vector<int16_t> capture, render;
    if (!read_pcm(capture_path, capture)) return 1;
    if (!read_pcm(render_path, render)) return 1;

    std::vector<int16_t> out = capture; // passthrough wherever nothing is processed
    bool skipped = false;
    bool diverged = false;
    long frames = 0;
    double render_active = 0.0;
    std::vector<oxaec::LagWindow> lags;
    struct StatRow { long t; std::optional<int32_t> delay_ms; std::optional<double> erl, erle, div; };
    std::vector<StatRow> stats;

    int render_peak = 0;
    for (int16_t s : render) render_peak = std::max(render_peak, std::abs(static_cast<int>(s)));
    long apm_latency = -1;
    bool latency_measured = false;
    if (render_peak < kSilencePeak) {
        skipped = true;
    } else {
        lags = oxaec::estimate_lags(render.data(), render.size(), capture.data(), capture.size(),
                                  kWindow, kMaxLag, kVoicedFloor, kMinScore, kMinPeakRatio);

        rtc::scoped_refptr<webrtc::AudioProcessing> apm = webrtc::AudioProcessingBuilder().Create();
        if (!apm) {
            std::fprintf(stderr, "ox-aec: AudioProcessingBuilder failed\n");
            return 1;
        }
        webrtc::AudioProcessing::Config cfg = apm_config();
        apm->ApplyConfig(cfg);

        apm_latency = measure_apm_latency();
        latency_measured = apm_latency >= 0;
        if (!latency_measured) {
            std::fprintf(stderr, "ox-aec: APM latency probe failed; falling back to %d samples\n",
                         kApmLatencyFallback);
            apm_latency = kApmLatencyFallback;
        }

        webrtc::StreamConfig sc(kRate, 1);
        int16_t rbuf[kFrame], cbuf[kFrame];
        // fed_cap[j] is the capture index where feed j's frame started.
        // Emitted block j covers fed-stream positions
        // [j*kFrame - apm_latency, (j+1)*kFrame - apm_latency): its sample i is
        // the processed version of fed sample x = j*kFrame - apm_latency + i,
        // captured at fed_cap[x/kFrame] + x%kFrame. The per-sample map keeps
        // the output on the capture timeline when a lag step jumps the feed
        // position (one emitted block can straddle the jump) and at the
        // processed/passthrough borders: a capture index never fed keeps its
        // passthrough copy, and the pipeline fill ahead of the first fed
        // sample is skipped rather than written.
        std::vector<long> fed_cap;
        long emitted = 0;
        auto emit_block = [&]() {
            for (int i = 0; i < kFrame; ++i) {
                long x = emitted * kFrame - apm_latency + i;
                if (x < 0 || x >= frames * kFrame) continue;
                long pos = fed_cap[x / kFrame] + x % kFrame;
                if (pos < static_cast<long>(out.size())) out[pos] = cbuf[i];
            }
            ++emitted;
        };
        long voiced = 0, echo_only = 0;
        double ein = 0.0, eout = 0.0;
        for (size_t k = 0; k < render.size(); k += kFrame) {
            int s = static_cast<int>(lags[k / kWindow].lag_ms * 16.0) - kMargin; // capture offset: render leads by kMargin
            long cap_idx = static_cast<long>(k) + s;
            if (cap_idx < 0) continue;
            if (cap_idx + kFrame > static_cast<long>(capture.size())) break;

            std::fill(rbuf, rbuf + kFrame, 0);
            size_t rlen = std::min<size_t>(kFrame, render.size() - k);
            std::memcpy(rbuf, render.data() + k, rlen * 2);
            std::memcpy(cbuf, capture.data() + cap_idx, kFrame * 2);

            double rrms = oxaec::lag_rms(rbuf, kFrame);
            double crms = oxaec::lag_rms(cbuf, kFrame);
            bool far = rrms >= kVoicedFloor;
            // Heuristic for "far-end-only": the echo is attenuated render, so
            // a capture frame no louder than ~1.5x the render frame carries
            // no near-end. A quiet near end can still pass as echo-dominated;
            // a loud one cannot.
            bool echo_dom = far && crms <= 1.5 * rrms;
            if (apm->ProcessReverseStream(rbuf, sc, sc, rbuf) != 0) {
                std::fprintf(stderr, "ox-aec: ProcessReverseStream failed at frame %ld\n", emitted);
                return 1;
            }
            apm->set_stream_delay_ms(kMarginMs);
            double ein_f = 0.0;
            for (int i = 0; i < kFrame; ++i) ein_f += static_cast<double>(cbuf[i]) * cbuf[i];
            if (apm->ProcessStream(cbuf, sc, sc, cbuf) != 0) {
                std::fprintf(stderr, "ox-aec: ProcessStream failed at frame %ld\n", emitted);
                return 1;
            }
            fed_cap.push_back(cap_idx);
            ++frames;
            emit_block();
            if (far) ++voiced;
            if (echo_dom) {
                ++echo_only;
                ein += ein_f;
                for (int i = 0; i < kFrame; ++i) eout += static_cast<double>(cbuf[i]) * cbuf[i];
            }
            if (emitted % 100 == 0) {
                webrtc::AudioProcessingStats st = apm->GetStatistics();
                stats.push_back({emitted / 100, st.delay_ms, st.echo_return_loss,
                                 st.echo_return_loss_enhancement, st.divergent_filter_fraction});
            }
        }
        // Drain the last apm_latency fed samples still inside the pipeline:
        // feed silent frames until they come out. The padding frames own no
        // capture positions — emit_block skips fed-stream positions past the
        // last real feed — so the output length stays the capture's.
        for (int j = 0; j < (apm_latency + kFrame - 1) / kFrame; ++j) {
            std::fill(rbuf, rbuf + kFrame, 0);
            std::fill(cbuf, cbuf + kFrame, 0);
            if (apm->ProcessReverseStream(rbuf, sc, sc, rbuf) != 0) {
                std::fprintf(stderr, "ox-aec: ProcessReverseStream failed while flushing\n");
                return 1;
            }
            apm->set_stream_delay_ms(kMarginMs);
            if (apm->ProcessStream(cbuf, sc, sc, cbuf) != 0) {
                std::fprintf(stderr, "ox-aec: ProcessStream failed while flushing\n");
                return 1;
            }
            emit_block();
        }
        diverged = echo_only > 0 && eout > ein;
        render_active = frames ? static_cast<double>(voiced) / frames : 0.0;
    }

    long voiced_windows = 0, measured_windows = 0;
    for (const auto& l : lags) {
        if (l.voiced) ++voiced_windows;
        if (l.measured) ++measured_windows;
    }
    const char* alignment = "unmeasured";
    if (voiced_windows > 0 && measured_windows == voiced_windows) {
        alignment = "measured";
    } else if (measured_windows > 0) {
        alignment = "partial";
    }

    // Both artifacts go to a temp file first and are renamed only when both
    // writes succeeded — the report first, the output last, so a failed
    // report never leaves a fresh output beside a non-zero exit.
    std::string out_tmp = std::string(out_path) + ".tmp";
    std::string rep_tmp = report_path ? std::string(report_path) + ".tmp" : std::string();
    if (!write_pcm(out_tmp.c_str(), out)) {
        std::remove(out_tmp.c_str());
        return 1;
    }
    if (report_path) {
        FILE* f = std::fopen(rep_tmp.c_str(), "w");
        if (!f) {
            std::fprintf(stderr, "ox-aec: cannot write %s: %s\n", rep_tmp.c_str(), std::strerror(errno));
            std::remove(out_tmp.c_str());
            return 1;
        }
        std::fputs("{\"frames\":", f);
        json_num(f, frames);
        std::fputs(",\"lag_ms\":[", f);
        for (size_t i = 0; i < lags.size(); ++i) {
            if (i) std::fputc(',', f);
            json_num(f, lags[i].lag_ms);
        }
        std::fputs("],\"lag_measured\":[", f);
        for (size_t i = 0; i < lags.size(); ++i) {
            if (i) std::fputc(',', f);
            std::fputc(lags[i].measured ? '1' : '0', f);
        }
        std::fputs("],\"stats\":[", f);
        for (size_t i = 0; i < stats.size(); ++i) {
            if (i) std::fputc(',', f);
            std::fprintf(f, "{\"t\":%ld,\"delay_ms\":", stats[i].t);
            json_opt(f, stats[i].delay_ms);
            std::fputs(",\"erl_db\":", f);
            json_opt(f, stats[i].erl);
            std::fputs(",\"erle_db\":", f);
            json_opt(f, stats[i].erle);
            std::fputs(",\"div_frac\":", f);
            json_opt(f, stats[i].div);
            std::fputc('}', f);
        }
        std::fputs("],\"render_active\":", f);
        json_num(f, render_active);
        std::fprintf(f, ",\"diverged\":%s", diverged ? "true" : "false");
        std::fprintf(f, ",\"alignment\":\"%s\"", alignment);
        if (apm_latency >= 0) {
            std::fprintf(f, ",\"apm_latency_samples\":%ld", apm_latency);
            if (!latency_measured) std::fputs(",\"apm_latency_measured\":false", f);
        }
        if (skipped) std::fputs(",\"skipped\":\"no_render\"", f);
        std::fputs("}\n", f);
        if (std::fclose(f) != 0) {
            std::fprintf(stderr, "ox-aec: failed writing %s\n", rep_tmp.c_str());
            std::remove(rep_tmp.c_str());
            std::remove(out_tmp.c_str());
            return 1;
        }
        if (std::rename(rep_tmp.c_str(), report_path) != 0) {
            std::fprintf(stderr, "ox-aec: cannot rename %s: %s\n", rep_tmp.c_str(), std::strerror(errno));
            std::remove(rep_tmp.c_str());
            std::remove(out_tmp.c_str());
            return 1;
        }
    }
    if (std::rename(out_tmp.c_str(), out_path) != 0) {
        std::fprintf(stderr, "ox-aec: cannot rename %s: %s\n", out_tmp.c_str(), std::strerror(errno));
        std::remove(out_tmp.c_str());
        return 1;
    }
    return 0;
}
