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
constexpr double kMinScore = 0.02;       // normalized xcorr floor for a measured lag
constexpr int kSilencePeak = 128;        // whole-file render peak -> no_render

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

    int16_t render_peak = 0;
    for (int16_t s : render) render_peak = std::max<int16_t>(render_peak, std::abs(s));
    if (render_peak < kSilencePeak) {
        skipped = true;
    } else {
        lags = oxaec::estimate_lags(render.data(), render.size(), capture.data(), capture.size(),
                                  kWindow, kMaxLag, kVoicedFloor, kMinScore);

        rtc::scoped_refptr<webrtc::AudioProcessing> apm = webrtc::AudioProcessingBuilder().Create();
        if (!apm) {
            std::fprintf(stderr, "ox-aec: AudioProcessingBuilder failed\n");
            return 1;
        }
        webrtc::AudioProcessing::Config cfg;
        cfg.echo_canceller.enabled = true;
        cfg.echo_canceller.mobile_mode = false;
        cfg.high_pass_filter.enabled = true;
        cfg.noise_suppression.enabled = false;
        cfg.gain_controller1.enabled = false;
        cfg.gain_controller2.enabled = false;
        apm->ApplyConfig(cfg);

        webrtc::StreamConfig sc(kRate, 1);
        int16_t rbuf[kFrame], cbuf[kFrame];
        long voiced = 0;
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
            bool far = rrms >= kVoicedFloor;
            if (apm->ProcessReverseStream(rbuf, sc, sc, rbuf) != 0) {
                std::fprintf(stderr, "ox-aec: ProcessReverseStream failed at frame %ld\n", frames);
                return 1;
            }
            apm->set_stream_delay_ms(kMarginMs);
            double ein_f = 0.0;
            for (int i = 0; i < kFrame; ++i) ein_f += static_cast<double>(cbuf[i]) * cbuf[i];
            if (apm->ProcessStream(cbuf, sc, sc, cbuf) != 0) {
                std::fprintf(stderr, "ox-aec: ProcessStream failed at frame %ld\n", frames);
                return 1;
            }
            if (far) {
                ++voiced;
                ein += ein_f;
                for (int i = 0; i < kFrame; ++i) eout += static_cast<double>(cbuf[i]) * cbuf[i];
            }
            std::memcpy(out.data() + cap_idx, cbuf, kFrame * 2);
            ++frames;
            if (frames % 100 == 0) {
                webrtc::AudioProcessingStats st = apm->GetStatistics();
                stats.push_back({frames / 100, st.delay_ms, st.echo_return_loss,
                                 st.echo_return_loss_enhancement, st.divergent_filter_fraction});
            }
        }
        diverged = voiced > 0 && eout > ein;
        render_active = frames ? static_cast<double>(voiced) / frames : 0.0;
    }

    if (!write_pcm(out_path, out)) return 1;

    if (report_path) {
        FILE* f = std::fopen(report_path, "w");
        if (!f) {
            std::fprintf(stderr, "ox-aec: cannot write %s: %s\n", report_path, std::strerror(errno));
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
        if (skipped) std::fputs(",\"skipped\":\"no_render\"", f);
        std::fputs("}\n", f);
        if (std::fclose(f) != 0) {
            std::fprintf(stderr, "ox-aec: failed writing %s\n", report_path);
            return 1;
        }
    }
    return 0;
}
