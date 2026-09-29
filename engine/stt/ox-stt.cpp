// ox-stt: speech-to-text with word timings, JSON out. Parakeet TDT (default) or Whisper via whisper.cpp.
//
//   ox-stt -m <model> -f <16 kHz mono WAV> [--engine parakeet|whisper] [-l lang] [--prompt text]
//          [-t threads] [-ng] [--chunk-s 30] [-o out.json] [-v]
//
// Output: {"engine","language","duration_s","elapsed_s","text","segments":[{"s","e","text"}],
//          "words":[{"w","s","e","p"}]}, times in seconds.
//
// Parakeet runs on chunks of at most --chunk-s seconds, cut at the quietest 10 ms frame near the end of
// each window: one graph per chunk keeps every GPU command buffer short (a GPU that drives the display
// is killed by the macOS watchdog after a few seconds) and the encoder's attention cost linear in length.
#include "parakeet.h"
#include "whisper.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr int SR = 16000;

struct word {
    std::string w;
    double s, e, p;
};

struct segment {
    double s, e;
    std::string text;
};

struct result {
    std::string language;
    std::vector<segment> segments;
    std::vector<word> words;
};

struct args {
    std::string model, file, out, engine = "parakeet", lang, prompt;
    int threads = 6;
    bool gpu = true, verbose = false;
    double chunk_s = 30.0;
};

void usage(const char * argv0) {
    fprintf(stderr,
            "usage: %s -m model -f audio.wav [--engine parakeet|whisper] [-l lang] [--prompt text]\n"
            "          [-t threads] [-ng] [--chunk-s 30] [-o out.json] [-v]\n"
            "audio must be a 16 kHz mono WAV (PCM16 or float32): ffmpeg -i in -ar 16000 -ac 1 out.wav\n",
            argv0);
}

bool parse(int argc, char ** argv, args & a) {
    for (int i = 1; i < argc; ++i) {
        const std::string k = argv[i];
        auto next = [&](std::string & v) {
            if (i + 1 >= argc) {
                return false;
            }
            v = argv[++i];
            return true;
        };
        std::string v;
        if (k == "-m" || k == "--model") {
            if (!next(a.model)) return false;
        } else if (k == "-f" || k == "--file") {
            if (!next(a.file)) return false;
        } else if (k == "-o" || k == "--out") {
            if (!next(a.out)) return false;
        } else if (k == "--engine") {
            if (!next(a.engine)) return false;
        } else if (k == "-l" || k == "--language") {
            if (!next(a.lang)) return false;
        } else if (k == "--prompt") {
            if (!next(a.prompt)) return false;
        } else if (k == "-t" || k == "--threads") {
            if (!next(v)) return false;
            a.threads = std::max(1, atoi(v.c_str()));
        } else if (k == "--chunk-s") {
            if (!next(v)) return false;
            a.chunk_s = atof(v.c_str());
        } else if (k == "-ng" || k == "--no-gpu") {
            a.gpu = false;
        } else if (k == "-v" || k == "--verbose") {
            a.verbose = true;
        } else {
            fprintf(stderr, "unknown argument: %s\n", k.c_str());
            return false;
        }
    }
    if (a.model.empty() || a.file.empty() || (a.engine != "parakeet" && a.engine != "whisper") ||
        !std::isfinite(a.chunk_s) || a.chunk_s < 5.0) {
        return false;
    }
    return true;
}

uint32_t rd32(const unsigned char * p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t) p[3] << 24; }
uint16_t rd16(const unsigned char * p) { return (uint16_t) (p[0] | p[1] << 8); }

// 16 kHz mono PCM16 or float32 WAV -> float samples
bool read_wav(const std::string & path, std::vector<float> & out, std::string & err) {
    FILE * f = fopen(path.c_str(), "rb");
    if (!f) {
        err = "cannot open " + path;
        return false;
    }
    std::vector<unsigned char> buf;
    if (fseek(f, 0, SEEK_END) == 0) {
        const long size = ftell(f);
        if (size > 0) {
            buf.reserve((size_t) size);
        }
        fseek(f, 0, SEEK_SET);
    }
    unsigned char tmp[1 << 16];
    size_t n;
    while ((n = fread(tmp, 1, sizeof(tmp), f)) > 0) {
        buf.insert(buf.end(), tmp, tmp + n);
    }
    fclose(f);
    if (buf.size() < 12 || memcmp(buf.data(), "RIFF", 4) != 0 || memcmp(buf.data() + 8, "WAVE", 4) != 0) {
        err = "not a RIFF/WAVE file";
        return false;
    }
    int fmt = 0, ch = 0, bits = 0;
    uint32_t rate = 0;
    for (size_t off = 12; off + 8 <= buf.size();) {
        const uint32_t len = rd32(&buf[off + 4]);
        const size_t body = off + 8;
        if (body + len > buf.size() && memcmp(&buf[off], "data", 4) != 0) {
            break;
        }
        if (memcmp(&buf[off], "fmt ", 4) == 0 && len >= 16) {
            fmt  = rd16(&buf[body]);
            ch   = rd16(&buf[body + 2]);
            rate = rd32(&buf[body + 4]);
            bits = rd16(&buf[body + 14]);
            if (fmt == 0xFFFE && len >= 26) {  // WAVE_FORMAT_EXTENSIBLE: sub-format code
                fmt = rd16(&buf[body + 24]);
            }
        } else if (memcmp(&buf[off], "data", 4) == 0) {
            if (rate != SR || ch != 1 || !((fmt == 1 && bits == 16) || (fmt == 3 && bits == 32))) {
                err = "need 16 kHz mono PCM16 or float32 (got rate " + std::to_string(rate) + ", channels " +
                      std::to_string(ch) + ", format " + std::to_string(fmt) + "/" + std::to_string(bits) + " bit)";
                return false;
            }
            // a streaming writer leaves the length 0 or 0xFFFFFFFF: take the rest of the file
            const size_t avail = (len == 0 || len == 0xFFFFFFFFu) ? buf.size() - body : std::min<size_t>(len, buf.size() - body);
            if (fmt == 1) {
                out.resize(avail / 2);
                for (size_t i = 0; i < out.size(); ++i) {
                    out[i] = (int16_t) rd16(&buf[body + 2 * i]) / 32768.0f;
                }
            } else {
                out.resize(avail / 4);
                memcpy(out.data(), &buf[body], out.size() * 4);
                for (float v : out) {
                    if (!std::isfinite(v)) {
                        err = "float WAV has non-finite samples";
                        return false;
                    }
                }
            }
            if (out.empty()) {
                err = "no audio samples";
                return false;
            }
            return true;
        }
        off = body + len + (len & 1);
    }
    err = "no data chunk";
    return false;
}

// chunk boundaries (sample offsets): windows of at most max_len samples, each cut at the centre of the
// quietest 150 ms stretch in its last fifth. A stretch, not a single 10 ms frame: the closure of a stop
// consonant is quiet for a frame or two and would cut a word in half.
std::vector<size_t> chunk_bounds(const std::vector<float> & x, size_t max_len) {
    std::vector<size_t> b = { 0 };
    const size_t hop  = SR / 100;
    const size_t span = 15;  // hops per stretch
    while (x.size() - b.back() > max_len) {
        const size_t start = b.back();
        const size_t lo    = start + max_len * 4 / 5;
        const size_t hi    = start + max_len;
        std::vector<double> e;  // energy per hop in [lo, hi)
        for (size_t i = lo; i + hop <= hi; i += hop) {
            double v = 0;
            for (size_t j = i; j < i + hop; ++j) {
                v += (double) x[j] * x[j];
            }
            e.push_back(v);
        }
        size_t best = hi - hop;
        if (e.size() >= span) {
            double sum = 0;
            for (size_t k = 0; k < span; ++k) {
                sum += e[k];
            }
            double best_sum = sum;
            size_t best_k   = 0;
            for (size_t k = span; k < e.size(); ++k) {
                sum += e[k] - e[k - span];
                if (sum < best_sum) {
                    best_sum = sum;
                    best_k   = k - span + 1;
                }
            }
            best = lo + (best_k + span / 2) * hop;
        }
        b.push_back(best);
    }
    b.push_back(x.size());
    return b;
}

bool is_punct(const std::string & t) {
    if (t.empty()) {
        return false;
    }
    for (unsigned char c : t) {
        if (!std::ispunct(c)) {
            return false;
        }
    }
    return true;
}

void no_log(ggml_log_level, const char *, void *) {}

std::string strip_marker(const char * tok) {
    std::string s = tok;
    const std::string mark = "\xE2\x96\x81";  // U+2581, SentencePiece word boundary
    size_t p;
    while ((p = s.find(mark)) != std::string::npos) {
        s.erase(p, mark.size());
    }
    return s;
}

bool run_parakeet(const args & a, const std::vector<float> & x, result & r, std::string & err) {
    parakeet_context_params cp = parakeet_context_default_params();
    cp.use_gpu = a.gpu;
    parakeet_context * ctx = parakeet_init_from_file_with_params(a.model.c_str(), cp);
    if (!ctx) {
        err = "failed to load parakeet model " + a.model;
        return false;
    }
    // Longer chunks than the model's audio context take parakeet's dynamic-encoder path, whose segment
    // times are in encoder frames (80 ms), not mel frames; stay on the fixed-context path.
    // A chunk of n samples has n/160 + 1 mel frames: at most n_audio_ctx - 1 hops, i.e. 49.99 s.
    const double max_s = (parakeet_n_audio_ctx(ctx) - 1) / 100.0;
    if (a.chunk_s > max_s) {
        parakeet_free(ctx);
        char msg[96];
        snprintf(msg, sizeof(msg), "--chunk-s must be at most %.2f s for this model", max_s);
        err = msg;
        return false;
    }
    const std::vector<size_t> b = chunk_bounds(x, (size_t) (a.chunk_s * SR));
    for (size_t c = 0; c + 1 < b.size(); ++c) {
        const double off = (double) b[c] / SR;
        parakeet_full_params fp = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY);
        fp.n_threads  = a.threads;
        fp.no_context = true;
        if (parakeet_full(ctx, fp, x.data() + b[c], (int) (b[c + 1] - b[c])) != 0) {
            parakeet_free(ctx);
            err = "parakeet failed on chunk " + std::to_string(c) + " at " + std::to_string(off) + " s";
            return false;
        }
        const double end = (double) b[c + 1] / SR;
        for (int i = 0; i < parakeet_full_n_segments(ctx); ++i) {
            r.segments.push_back({ off + parakeet_full_get_segment_t0(ctx, i) / 100.0,
                                   std::min(end, off + parakeet_full_get_segment_t1(ctx, i) / 100.0),
                                   parakeet_full_get_segment_text(ctx, i) });
            int n_in_word = 0;  // tokens averaged into the current word's p
            for (int j = 0; j < parakeet_full_n_tokens(ctx, i); ++j) {
                const parakeet_token_data d = parakeet_full_get_token_data(ctx, i, j);
                const std::string t = strip_marker(parakeet_full_get_token_text(ctx, i, j));
                if (t.empty()) {
                    if (d.is_word_start) {
                        n_in_word = 0;  // a lone boundary marker: the next token starts a word
                    }
                    continue;
                }
                if (is_punct(t) && !d.is_word_start && !r.words.empty() && n_in_word > 0) {
                    r.words.back().w += t;  // punctuation: no timing of its own, not part of p
                } else if (d.is_word_start || r.words.empty() || n_in_word == 0) {
                    r.words.push_back({ t, off + d.t0 / 100.0, off + d.t1 / 100.0, d.p });
                    n_in_word = 1;
                } else {
                    word & w = r.words.back();
                    w.w += t;
                    w.e = std::max(w.e, off + d.t1 / 100.0);
                    w.p = (w.p * n_in_word + d.p) / (n_in_word + 1);
                    ++n_in_word;
                }
            }
        }
    }
    parakeet_free(ctx);
    return true;
}

bool run_whisper(const args & a, const std::vector<float> & x, result & r, std::string & err) {
    whisper_context_params cp = whisper_context_default_params();
    cp.use_gpu    = a.gpu;
    cp.flash_attn = true;
    whisper_context * ctx = whisper_init_from_file_with_params(a.model.c_str(), cp);
    if (!ctx) {
        err = "failed to load whisper model " + a.model;
        return false;
    }
    whisper_full_params fp = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
    fp.n_threads        = a.threads;
    fp.beam_search.beam_size = 5;
    fp.greedy.best_of   = 5;
    fp.language         = a.lang.empty() ? "auto" : a.lang.c_str();
    fp.detect_language  = false;
    fp.initial_prompt   = a.prompt.empty() ? nullptr : a.prompt.c_str();
    fp.token_timestamps = true;
    fp.max_len          = 1;  // one segment per word
    fp.split_on_word    = true;
    fp.print_progress   = false;
    fp.print_realtime   = false;
    fp.print_timestamps = false;
    if (whisper_full(ctx, fp, x.data(), (int) x.size()) != 0) {
        whisper_free(ctx);
        err = "whisper failed";
        return false;
    }
    r.language = whisper_lang_str(whisper_full_lang_id(ctx));
    for (int i = 0; i < whisper_full_n_segments(ctx); ++i) {
        const double s = whisper_full_get_segment_t0(ctx, i) / 100.0;
        const double e = whisper_full_get_segment_t1(ctx, i) / 100.0;
        std::string t = whisper_full_get_segment_text(ctx, i);
        const size_t first = t.find_first_not_of(' ');
        t = first == std::string::npos ? "" : t.substr(first);
        if (t.empty()) {
            continue;
        }
        double p = 0;
        int n = 0;
        for (int j = 0; j < whisper_full_n_tokens(ctx, i); ++j) {
            if (whisper_full_get_token_id(ctx, i, j) < whisper_token_eot(ctx)) {
                p += whisper_full_get_token_p(ctx, i, j);
                ++n;
            }
        }
        r.words.push_back({ t, s, e, n ? p / n : 0.0 });
        r.segments.push_back({ s, e, t });
    }
    whisper_free(ctx);
    return true;
}

// length of the well-formed UTF-8 sequence at s[i] (RFC 3629: no overlongs, no surrogates,
// nothing above U+10FFFF), or 0
size_t utf8_len(const std::string & s, size_t i) {
    const unsigned char c = s[i];
    size_t        n  = 0;
    unsigned char lo = 0x80, hi = 0xBF;  // allowed range of the second byte
    if (c < 0x80) {
        return 1;
    } else if (c >= 0xC2 && c <= 0xDF) {
        n = 2;
    } else if (c >= 0xE0 && c <= 0xEF) {
        n  = 3;
        lo = c == 0xE0 ? 0xA0 : 0x80;
        hi = c == 0xED ? 0x9F : 0xBF;
    } else if (c >= 0xF0 && c <= 0xF4) {
        n  = 4;
        lo = c == 0xF0 ? 0x90 : 0x80;
        hi = c == 0xF4 ? 0x8F : 0xBF;
    } else {
        return 0;
    }
    if (i + n > s.size()) {
        return 0;
    }
    const unsigned char c1 = s[i + 1];
    if (c1 < lo || c1 > hi) {
        return 0;
    }
    for (size_t k = 2; k < n; ++k) {
        if (((unsigned char) s[i + k] >> 6) != 0x2) {
            return 0;
        }
    }
    return n;
}

void json_str(std::string & o, const std::string & s0) {
    // model tokens are bytes; replace anything that is not valid UTF-8 with U+FFFD
    std::string s;
    for (size_t i = 0; i < s0.size();) {
        const size_t n = utf8_len(s0, i);
        if (n == 0) {
            s += "\xEF\xBF\xBD";
            ++i;
        } else {
            s.append(s0, i, n);
            i += n;
        }
    }
    o += '"';
    for (unsigned char c : s) {
        switch (c) {
            case '"':  o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break;
            case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break;
            default:
                if (c < 0x20) {
                    char u[8];
                    snprintf(u, sizeof(u), "\\u%04x", c);
                    o += u;
                } else {
                    o += (char) c;
                }
        }
    }
    o += '"';
}

std::string num(double v) {
    char b[32];
    snprintf(b, sizeof(b), "%.3f", v);
    return b;
}

}  // namespace

int main(int argc, char ** argv) {
    args a;
    if (!parse(argc, argv, a)) {
        usage(argv[0]);
        return 2;
    }
    if (a.engine == "parakeet" && (!a.lang.empty() || !a.prompt.empty())) {
        fprintf(stderr, "ox-stt: parakeet detects the language itself and takes no prompt; -l/--prompt ignored\n");
    }
    if (!a.verbose) {
        parakeet_log_set(no_log, nullptr);
        whisper_log_set(no_log, nullptr);
    }
    std::vector<float> x;
    std::string err;
    if (!read_wav(a.file, x, err)) {
        fprintf(stderr, "ox-stt: %s\n", err.c_str());
        return 1;
    }
    const auto t0 = std::chrono::steady_clock::now();
    result r;
    const bool ok = a.engine == "whisper" ? run_whisper(a, x, r, err) : run_parakeet(a, x, r, err);
    if (!ok) {
        fprintf(stderr, "ox-stt: %s\n", err.c_str());
        return 1;
    }
    const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();

    std::string text;
    for (const segment & s : r.segments) {
        text += (text.empty() ? "" : " ") + s.text;
    }
    std::string o = "{\"engine\":";
    json_str(o, a.engine);
    o += ",\"language\":";
    if (r.language.empty()) {
        o += "null";
    } else {
        json_str(o, r.language);
    }
    o += ",\"duration_s\":" + num((double) x.size() / SR) + ",\"elapsed_s\":" + num(elapsed) + ",\"text\":";
    json_str(o, text);
    o += ",\"segments\":[";
    for (size_t i = 0; i < r.segments.size(); ++i) {
        o += (i ? "," : "") + std::string("{\"s\":") + num(r.segments[i].s) + ",\"e\":" + num(r.segments[i].e) + ",\"text\":";
        json_str(o, r.segments[i].text);
        o += "}";
    }
    o += "],\"words\":[";
    for (size_t i = 0; i < r.words.size(); ++i) {
        o += (i ? "," : "") + std::string("{\"w\":");
        json_str(o, r.words[i].w);
        o += ",\"s\":" + num(r.words[i].s) + ",\"e\":" + num(r.words[i].e) + ",\"p\":" + num(r.words[i].p) + "}";
    }
    o += "]}\n";

    if (a.out.empty()) {
        if (fwrite(o.data(), 1, o.size(), stdout) != o.size() || fflush(stdout) != 0 || ferror(stdout)) {
            fprintf(stderr, "ox-stt: cannot write to stdout\n");
            return 1;
        }
    } else {
        FILE * f = fopen(a.out.c_str(), "wb");
        const bool wrote = f && fwrite(o.data(), 1, o.size(), f) == o.size();
        if (!f || fclose(f) != 0 || !wrote) {
            fprintf(stderr, "ox-stt: cannot write %s\n", a.out.c_str());
            return 1;
        }
    }
    return 0;
}
