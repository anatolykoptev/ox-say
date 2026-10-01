// ox-stt: speech-to-text with word timings, JSON out. Parakeet TDT (default) or Whisper via whisper.cpp.
//
//   ox-stt -m <model> -f <16 kHz mono WAV> [--engine parakeet|whisper] [-l lang] [--prompt text]
//          [-t threads] [-ng] [--chunk-s 30] [-o out.json] [-v]
//
//   ox-stt --serve -m <parakeet model> --port <port> [--vad <silero VAD model>]
//          [-t threads] [-ng] [--chunk-s 30] [-v]
//          loads the model once, warms it up, then serves loopback HTTP (whisper stays CLI-only):
//            GET  /health      -> 200 {"status":"ok"}
//            POST /transcribe  -> body is a 16 kHz mono WAV sent as Content-Type: audio/wav with a
//                                 Content-Length; 200 with the same JSON the CLI prints
//          with --vad, streaming dictation sessions:
//            POST /sessions              -> {"id":<32 lowercase hex>}; application/json, body ignored;
//                                 429 "at most 4 sessions", 500 "failed to init VAD context",
//                                 500 "no entropy"
//            POST /sessions/<id>/audio   -> raw little-endian float32 mono 16 kHz PCM
//                                 (application/octet-stream, <= 30 s per call); Silero VAD cuts the
//                                 stream at pauses and finished pieces decode in the background;
//                                 200 {"segments":[...],"words":[...],"pending":N} with what decoded
//                                 since the previous response; 429 "decode backlog" when the
//                                 session has more than 8 segments queued or decoding (the audio
//                                 is NOT taken, so the client can retry or fall back);
//                                 500 "decode failed" once any of the session's decodes failed
//            POST /sessions/<id>/finish  -> flushes the open segment, waits out the queued decodes,
//                                 200 with the same fields plus "done":true and the whole "text";
//                                 500 "decode failed" (the session is deleted) after a decode
//                                 failure, 504 when the 60 s drain bound is hit
//            DELETE /sessions/<id>       -> drops the session and its queued work
//          without --vad the session routes answer 501. The Host header must name loopback.
//          Anything else is refused (403, 405, 411, 415); methods other than GET, HEAD, POST
//          and DELETE are refused before their body would be read.
//          Client rule: on any non-200 from a session route the stream is unreliable (a failed
//          decode cannot pass for silence — words would go missing); upload the whole recording
//          to POST /transcribe or the daemon's one-shot route instead.
//
// Output: {"engine","language","duration_s","elapsed_s","text","segments":[{"s","e","text"}],
//          "words":[{"w","s","e","p"}]}, times in seconds.
//
// Parakeet runs on chunks of at most --chunk-s seconds, cut at the quietest 10 ms frame near the end of
// each window: one graph per chunk keeps every GPU command buffer short (a GPU that drives the display
// is killed by the macOS watchdog after a few seconds) and the encoder's attention cost linear in length.
#include "parakeet.h"
#include "whisper.h"

#include "segmenter.h"

#include "httplib.h"

#include <arpa/inet.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <unordered_map>
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
    std::string model, file, out, engine = "parakeet", lang, prompt, vad;
    int threads = 6;
    bool gpu = true, verbose = false, serve = false;
    int port = 0;  // set to a valid 1..65535 value by parse, or flagged invalid
    double chunk_s = 30.0;
};

void usage(const char * argv0) {
    fprintf(stderr,
            "usage: %s -m model -f audio.wav [--engine parakeet|whisper] [-l lang] [--prompt text]\n"
            "          [-t threads] [-ng] [--chunk-s 30] [-o out.json] [-v]\n"
            "       %s --serve -m model --port port [--vad silero-vad.bin] [-t threads] [-ng]\n"
            "          [--chunk-s 30] [-v]\n"
            "audio must be a 16 kHz mono WAV (PCM16 or float32): ffmpeg -i in -ar 16000 -ac 1 out.wav\n"
            "--vad enables the /sessions routes: POST /sessions, then raw little-endian float32\n"
            "mono 16 kHz PCM chunks to /sessions/<id>/audio, POST /sessions/<id>/finish or\n"
            "DELETE /sessions/<id> to end it\n",
            argv0, argv0);
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
        } else if (k == "--serve") {
            a.serve = true;
        } else if (k == "--vad") {
            if (!next(a.vad)) return false;
        } else if (k == "--port") {
            if (!next(v)) return false;
            char * end = nullptr;
            const long p = strtol(v.c_str(), &end, 10);
            const bool whole = !v.empty() && std::isdigit((unsigned char) v[0]) && *end == '\0';
            a.port = !whole || p < 1 ? -1 : (p > 65535 ? 65536 : (int) p);  // out of range stays invalid
        } else if (k == "-ng" || k == "--no-gpu") {
            a.gpu = false;
        } else if (k == "-v" || k == "--verbose") {
            a.verbose = true;
        } else {
            fprintf(stderr, "unknown argument: %s\n", k.c_str());
            return false;
        }
    }
    if (a.model.empty() || (a.engine != "parakeet" && a.engine != "whisper") ||
        !std::isfinite(a.chunk_s) || a.chunk_s < 5.0) {
        return false;
    }
    if (a.serve) {
        // serve mode is parakeet only and takes audio over HTTP, not from flags
        return a.engine == "parakeet" && a.file.empty() && a.out.empty() && a.lang.empty() &&
               a.prompt.empty() && a.port >= 1 && a.port <= 65535;
    }
    return a.port == 0 && !a.file.empty() && a.vad.empty();
}

uint32_t rd32(const unsigned char * p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t) p[3] << 24; }
uint16_t rd16(const unsigned char * p) { return (uint16_t) (p[0] | p[1] << 8); }

// 16 kHz mono PCM16 or float32 WAV -> float samples
bool read_wav_bytes(const unsigned char * buf, size_t size, std::vector<float> & out, std::string & err) {
    if (size < 12 || memcmp(buf, "RIFF", 4) != 0 || memcmp(buf + 8, "WAVE", 4) != 0) {
        err = "not a RIFF/WAVE file";
        return false;
    }
    int fmt = 0, ch = 0, bits = 0;
    uint32_t rate = 0;
    for (size_t off = 12; off + 8 <= size;) {
        const uint32_t len = rd32(buf + off + 4);
        const size_t body = off + 8;
        if (body + len > size && memcmp(buf + off, "data", 4) != 0) {
            break;
        }
        if (memcmp(buf + off, "fmt ", 4) == 0 && len >= 16) {
            fmt  = rd16(buf + body);
            ch   = rd16(buf + body + 2);
            rate = rd32(buf + body + 4);
            bits = rd16(buf + body + 14);
            if (fmt == 0xFFFE && len >= 26) {  // WAVE_FORMAT_EXTENSIBLE: sub-format code
                fmt = rd16(buf + body + 24);
            }
        } else if (memcmp(buf + off, "data", 4) == 0) {
            if (rate != SR || ch != 1 || !((fmt == 1 && bits == 16) || (fmt == 3 && bits == 32))) {
                err = "need 16 kHz mono PCM16 or float32 (got rate " + std::to_string(rate) + ", channels " +
                      std::to_string(ch) + ", format " + std::to_string(fmt) + "/" + std::to_string(bits) + " bit)";
                return false;
            }
            // a streaming writer leaves the length 0 or 0xFFFFFFFF: take the rest of the file
            const size_t avail = (len == 0 || len == 0xFFFFFFFFu) ? size - body : std::min<size_t>(len, size - body);
            if (fmt == 1) {
                out.resize(avail / 2);
                for (size_t i = 0; i < out.size(); ++i) {
                    out[i] = (int16_t) rd16(buf + body + 2 * i) / 32768.0f;
                }
            } else {
                out.resize(avail / 4);
                memcpy(out.data(), buf + body, out.size() * 4);
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
    return read_wav_bytes(buf.data(), buf.size(), out, err);
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

// Loads the model and checks --chunk-s against its audio context once; the returned context is
// reused for every decode (CLI: one run; --serve: one per request).
parakeet_context * load_parakeet(const args & a, std::string & err) {
    parakeet_context_params cp = parakeet_context_default_params();
    cp.use_gpu = a.gpu;
    parakeet_context * ctx = parakeet_init_from_file_with_params(a.model.c_str(), cp);
    if (!ctx) {
        err = "failed to load parakeet model " + a.model;
        return nullptr;
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
        return nullptr;
    }
    return ctx;
}

bool decode_parakeet(parakeet_context * ctx, const args & a, const std::vector<float> & x, result & r,
                     std::string & err) {
    const std::vector<size_t> b = chunk_bounds(x, (size_t) (a.chunk_s * SR));
    for (size_t c = 0; c + 1 < b.size(); ++c) {
        const double off = (double) b[c] / SR;
        parakeet_full_params fp = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY);
        fp.n_threads  = a.threads;
        fp.no_context = true;
        if (parakeet_full(ctx, fp, x.data() + b[c], (int) (b[c + 1] - b[c])) != 0) {
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
    return true;
}

bool run_parakeet(const args & a, const std::vector<float> & x, result & r, std::string & err) {
    parakeet_context * ctx = load_parakeet(a, err);
    if (!ctx) {
        return false;
    }
    const bool ok = decode_parakeet(ctx, a, x, r, err);
    parakeet_free(ctx);
    return ok;
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

// session segments report min_p at two decimals
std::string num2(double v) {
    char b[32];
    snprintf(b, sizeof(b), "%.2f", v);
    return b;
}

// The one JSON shape of ox-stt, shared by the CLI (stdout/-o) and POST /transcribe. Trailing
// newline included.
std::string result_json(const std::string & engine, const result & r, size_t n_samples, double elapsed) {
    std::string text;
    for (const segment & s : r.segments) {
        text += (text.empty() ? "" : " ") + s.text;
    }
    std::string o = "{\"engine\":";
    json_str(o, engine);
    o += ",\"language\":";
    if (r.language.empty()) {
        o += "null";
    } else {
        json_str(o, r.language);
    }
    o += ",\"duration_s\":" + num((double) n_samples / SR) + ",\"elapsed_s\":" + num(elapsed) + ",\"text\":";
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
    return o;
}

std::string error_json(const std::string & err) {
    std::string o = "{\"error\":";
    json_str(o, err);
    o += "}";
    return o;
}

// One decoded VAD segment of a session: absolute times, all its words, and
// the segmenter's own record of why it was cut (cut) and what the VAD saw
// while it was open (min_p, quiet_ms) — the dictation diagnostic.
struct decoded_seg {
    double s, e;
    std::string text;
    std::vector<word> words;
    oxstt::seg_cut cut;
    float min_p;
    int quiet_ms;
};

const char * cut_name(oxstt::seg_cut c) {
    switch (c) {
        case oxstt::seg_cut::pause:  return "pause";
        case oxstt::seg_cut::cap:    return "cap";
        case oxstt::seg_cut::finish: return "finish";
    }
    return "unknown";
}

// Segment/words JSON shared by POST .../audio and .../finish: the segments
// decoded since the session's previous response. `done` adds "done":true and
// the session's full "text" (segments joined with single spaces, as
// result_json joins them).
std::string session_json(const std::vector<decoded_seg> & segs, size_t from, size_t pending, bool done,
                         const std::string & text) {
    std::string o = "{\"segments\":[";
    for (size_t i = from; i < segs.size(); ++i) {
        o += (i > from ? "," : "") + std::string("{\"s\":") + num(segs[i].s) + ",\"e\":" +
             num(segs[i].e) + ",\"cut\":\"" + cut_name(segs[i].cut) + "\",\"min_p\":" +
             num2(segs[i].min_p) + ",\"quiet_ms\":" + std::to_string(segs[i].quiet_ms) + ",\"text\":";
        json_str(o, segs[i].text);
        o += "}";
    }
    o += "],\"words\":[";
    bool first = true;
    for (size_t i = from; i < segs.size(); ++i) {
        for (const word & w : segs[i].words) {
            o += (first ? "" : ",") + std::string("{\"w\":");
            json_str(o, w.w);
            o += ",\"s\":" + num(w.s) + ",\"e\":" + num(w.e) + ",\"p\":" + num(w.p) + "}";
            first = false;
        }
    }
    o += "],\"pending\":" + std::to_string(pending);
    if (done) {
        o += ",\"done\":true,\"text\":";
        json_str(o, text);
    }
    o += "}";
    return o;
}

// A streaming dictation session: its own Silero VAD context (the LSTM state is
// per stream), the segmenter, the audio backlog for not-yet-emitted ranges and
// the decoded results. Everything mutable sits behind mu; the decode worker
// never holds mu while decoding.
struct session {
    std::mutex mu;
    std::condition_variable cv;
    whisper_vad_context * vad = nullptr;
    oxstt::segmenter   seg;
    std::vector<float> audio;        // samples [audio_base, audio_base+size)
    uint64_t           audio_base = 0;
    uint64_t           vad_pos = 0;      // samples already run through VAD
    std::vector<decoded_seg> results;    // decoded segments in order
    size_t             returned = 0;     // results below this were already sent
    size_t             inflight = 0;     // segments queued or decoding
    bool               failed = false;   // a segment decode failed: /audio + /finish answer 500
    bool               dead = false;     // deleted/reaped: keep nothing
    std::atomic<long long> touch{0};     // last request, epoch seconds (steady_clock)

    ~session() {
        if (vad) {
            whisper_vad_free(vad);
        }
    }
};

struct decode_job {
    std::shared_ptr<session> sess;
    uint64_t s, e;
    oxstt::seg_cut cut;
    float min_p;
    int quiet_ms;
    std::vector<float> pcm;
};

// "/sessions/<one path segment>/audio" or ".../finish": the required media
// type for the POST; "/sessions" itself; anything else -> nullptr.
const char * session_post_type(const std::string & path) {
    static const std::string pre = "/sessions/";
    if (path == "/sessions") {
        return "application/json";
    }
    if (path.compare(0, pre.size(), pre) != 0) {
        return nullptr;
    }
    const size_t mid = path.find('/', pre.size());
    if (mid == std::string::npos || mid == pre.size()) {
        return nullptr;
    }
    const std::string tail = path.substr(mid);
    if (tail == "/audio") {
        return "application/octet-stream";
    }
    if (tail == "/finish") {
        return "application/json";
    }
    return nullptr;
}

bool is_session_path(const std::string & path) {
    static const std::string pre = "/sessions/";
    return path == "/sessions" || path.compare(0, pre.size(), pre) == 0;
}

std::string new_session_id() {
    unsigned char b[16];
    std::random_device rd;
    for (int i = 0; i < 16; i += 4) {
        const uint32_t v = rd();
        memcpy(b + i, &v, 4);
    }
    char hex[33];
    for (int i = 0; i < 16; ++i) {
        snprintf(hex + 2 * i, 3, "%02x", b[i]);
    }
    return std::string(hex, 32);
}

// "host:port", "[v6]:port" or "host" -> the host without port or brackets
std::string host_without_port(const std::string & h) {
    if (!h.empty() && h[0] == '[') {
        const size_t e = h.find(']');
        return e == std::string::npos ? h : h.substr(1, e - 1);
    }
    const size_t c = h.find(':');
    if (c != std::string::npos && h.find(':', c + 1) == std::string::npos) {
        return h.substr(0, c);  // one colon: a name or an IPv4 address with a port
    }
    return h;  // no port, or a bare IPv6 literal
}

// localhost, 127.0.0.0/8 or ::1 (strict literals via inet_pton)
bool is_loopback_host(const std::string & h) {
    std::string s = h;
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char ch) { return (char) std::tolower(ch); });
    if (s == "localhost") {
        return true;
    }
    unsigned char v4[4];
    if (inet_pton(AF_INET, s.c_str(), v4) == 1) {
        return v4[0] == 127;
    }
    unsigned char v6[16];
    if (inet_pton(AF_INET6, s.c_str(), v6) == 1) {
        static const unsigned char loop6[16] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
        return memcmp(v6, loop6, sizeof(loop6)) == 0;
    }
    return false;
}

// Loopback HTTP front for the resident parakeet context. No SIGTERM handler: the default action
// kills the process, which is what the supervisor's TERM-then-KILL expects — prompt exit regardless
// of what the session decode worker is doing. parakeet_context is not thread-safe while httplib
// serves on a thread pool, so decodes run one at a time under decode_mu.
int serve(const args & a) {
    std::string err;
    parakeet_context * ctx = load_parakeet(a, err);
    if (!ctx) {
        fprintf(stderr, "ox-stt: %s\n", err.c_str());
        return 1;
    }
    // Warm up before listening: the first decode after a load pays for allocating the compute
    // buffers and paging in the weights (measured 1.8-4.5 s for a 4.7 s phrase, against 0.9 s
    // warm). One second of silence costs ~0.3 s here, so /health answering means warm, not just
    // loaded.
    {
        result r;
        if (!decode_parakeet(ctx, a, std::vector<float>(SR, 0.0f), r, err)) {
            fprintf(stderr, "ox-stt: warm-up decode failed: %s\n", err.c_str());
            parakeet_free(ctx);
            return 1;
        }
    }
    // The VAD model gates the session routes; fail like the parakeet model before listening.
    if (!a.vad.empty()) {
        whisper_vad_context_params vp = whisper_vad_default_context_params();
        vp.use_gpu = false;  // the VAD stays on the CPU even when parakeet uses the GPU
        whisper_vad_context * probe = whisper_vad_init_from_file_with_params(a.vad.c_str(), vp);
        if (!probe) {
            fprintf(stderr, "ox-stt: failed to load VAD model %s\n", a.vad.c_str());
            parakeet_free(ctx);
            return 1;
        }
        // The model's window comes from the file but SEG_WIN is compiled into
        // the segmenter: a shorter n_window emits more probs than fed windows
        // and pump_session would index past the samples it copied. One silent
        // window must yield exactly one prob.
        std::vector<float> zwin(oxstt::SEG_WIN, 0.0f);
        if (!whisper_vad_detect_speech_no_reset(probe, zwin.data(), oxstt::SEG_WIN) ||
            whisper_vad_n_probs(probe) != 1) {
            fprintf(stderr, "ox-stt: VAD model window is not 512 samples\n");
            whisper_vad_free(probe);
            parakeet_free(ctx);
            return 1;
        }
        whisper_vad_free(probe);
    }
    std::mutex decode_mu;

    // Session store + the single background decode worker (FIFO across sessions).
    // Lock order, everywhere: sessions_mu < session.mu < jobs_mu — never nested
    // the other way, and no lock is held across a decode or a wait.
    std::mutex                                          sessions_mu;
    std::unordered_map<std::string, std::shared_ptr<session>> sessions;
    std::mutex                                          jobs_mu;
    std::condition_variable                             jobs_cv;
    std::deque<decode_job>                              jobs;
    bool                                                stopping = false;

    const auto now_s = [] {
        return std::chrono::duration_cast<std::chrono::seconds>(
                   std::chrono::steady_clock::now().time_since_epoch())
            .count();
    };
    // Drop sessions idle past 120 s. Lazy — runs under sessions_mu inside every
    // handler that already touches the map, so no extra thread or lock domain.
    auto reap_idle = [&] {
        const long long now = now_s();
        for (auto it = sessions.begin(); it != sessions.end();) {
            session & s = *it->second;
            if (now - s.touch.load() > 120) {
                {
                    std::lock_guard<std::mutex> sl(s.mu);
                    s.dead = true;
                }
                it = sessions.erase(it);
            } else {
                ++it;
            }
        }
    };
    // Enqueue one emitted segment for background decode. Called with the
    // session's mu held; the job copies its samples so audio can be trimmed.
    auto enqueue_segment = [&](const std::shared_ptr<session> & sp, const oxstt::seg_range & r) {
        if (r.e <= r.s) {
            return;  // the segmenter never emits one; never let one underflow the copy below
        }
        session & s = *sp;
        decode_job j;
        j.sess = sp;
        j.s = r.s;
        j.e = r.e;
        j.cut = r.cut;
        j.min_p = r.min_p;
        j.quiet_ms = r.quiet_ms;
        const size_t off = (size_t) (r.s - s.audio_base);
        j.pcm.assign(s.audio.begin() + off, s.audio.begin() + off + (size_t) (r.e - r.s));
        ++s.inflight;
        {
            std::lock_guard<std::mutex> jl(jobs_mu);
            jobs.push_back(std::move(j));
        }
        jobs_cv.notify_one();
    };
    // Run VAD over the whole new windows, feed the segmenter, enqueue whatever
    // it closes. False on a VAD failure (the session is then killed). mu held.
    auto pump_session = [&](const std::shared_ptr<session> & sp) -> bool {
        session & s = *sp;
        const uint64_t total = s.audio_base + (uint64_t) s.audio.size();
        const size_t n_win = (size_t) ((total - s.vad_pos) / oxstt::SEG_WIN);
        if (n_win == 0) {
            return true;
        }
        const float * pcm = s.audio.data() + (size_t) (s.vad_pos - s.audio_base);
        if (!whisper_vad_detect_speech_no_reset(s.vad, pcm, (int) (n_win * oxstt::SEG_WIN))) {
            return false;
        }
        const int np = whisper_vad_n_probs(s.vad);
        std::vector<oxstt::seg_range> segs;
        s.seg.feed(whisper_vad_probs(s.vad), (size_t) np, pcm, (size_t) np * oxstt::SEG_WIN, segs);
        s.vad_pos += (uint64_t) np * oxstt::SEG_WIN;
        for (const oxstt::seg_range & r : segs) {
            enqueue_segment(sp, r);
        }
        // drop audio nothing can reference any more: the segmenter's floor is
        // the lowest offset a future emit can still touch, so memory is bound
        // to the open segment plus a few seconds of slack, silence included
        const uint64_t floor_ = s.seg.floor();
        if (floor_ > s.audio_base && floor_ - s.audio_base > 4u * SR) {
            s.audio.erase(s.audio.begin(), s.audio.begin() + (size_t) (floor_ - s.audio_base));
            s.audio_base = floor_;
        }
        return true;
    };

    std::thread worker([&] {
        for (;;) {
            decode_job j;
            {
                std::unique_lock<std::mutex> jl(jobs_mu);
                jobs_cv.wait(jl, [&] { return stopping || !jobs.empty(); });
                if (stopping) {
                    return;
                }
                j = std::move(jobs.front());
                jobs.pop_front();
            }
            {
                std::lock_guard<std::mutex> sl(j.sess->mu);
                if (j.sess->dead || j.sess->failed) {
                    // deleted or failed sessions have no consumer for the
                    // result: drop the job before paying decode_mu for it
                    --j.sess->inflight;
                    j.sess->cv.notify_all();
                    continue;
                }
            }
            result r;
            std::string derr;
            bool ok;
            {
                std::lock_guard<std::mutex> dl(decode_mu);
                ok = decode_parakeet(ctx, a, j.pcm, r, derr);
            }
            {
                std::lock_guard<std::mutex> sl(j.sess->mu);
                if (ok) {
                    if (!j.sess->dead) {
                        decoded_seg d;
                        d.s = (double) j.s / SR;
                        d.e = (double) j.e / SR;
                        d.cut = j.cut;
                        d.min_p = j.min_p;
                        d.quiet_ms = j.quiet_ms;
                        for (const segment & sg : r.segments) {
                            d.text += (d.text.empty() ? "" : " ") + sg.text;
                        }
                        d.words = std::move(r.words);
                        for (word & w : d.words) {
                            w.s += d.s;
                            w.e += d.s;
                        }
                        j.sess->results.push_back(std::move(d));
                    }
                } else {
                    // a failed decode must not pass for an empty segment: the
                    // session is failed and the client restarts one-shot
                    fprintf(stderr, "ox-stt: session segment decode failed: %s\n", derr.c_str());
                    j.sess->failed = true;
                }
                --j.sess->inflight;
            }
            j.sess->cv.notify_all();
        }
    });
    auto join_worker = [&] {
        {
            std::lock_guard<std::mutex> jl(jobs_mu);
            stopping = true;
        }
        jobs_cv.notify_all();
        worker.join();
    };

    httplib::Server srv;
    srv.set_payload_max_length(64 << 20);
    // Local-only, as tts-server (engine/patches/qwentts/0002-tts-server-local-only.patch): the
    // supervising daemon is the one client. The Host header must name loopback (DNS rebinding), and
    // a POST must carry Content-Type audio/wav: a web page can send a cross-site "simple" request
    // (text/plain, form data) without a preflight, but not this type. No request may be chunked:
    // httplib reads a chunked body, for any method, past set_payload_max_length; a POST must carry
    // a Content-Length.
    srv.set_pre_routing_handler([&](const httplib::Request & req, httplib::Response & res) {
        if (!is_loopback_host(host_without_port(req.get_header_value("Host")))) {
            res.status = 403;
            res.set_content(error_json("host not allowed"), "application/json");
            return httplib::Server::HandlerResponse::Handled;
        }
        // GET, HEAD, POST and DELETE are the only routed methods; refuse the
        // rest before any body is read. httplib's pre-routing handler runs
        // before read_content for every method (routing(), httplib.h:7023 vs
        // 7077), and it treats PUT and PATCH as body-bearing
        // (expect_content, httplib.h:5459): with neither Content-Length nor
        // Transfer-Encoding the body is read until the connection closes,
        // past set_payload_max_length (read_content_without_length,
        // httplib.h:4386). DELETE is a real route and exempt: read_content_core
        // returns without reading when a DELETE has no Content-Length
        // (httplib.h:6842).
        if (req.method != "GET" && req.method != "HEAD" && req.method != "POST" &&
            req.method != "DELETE") {
            res.status = 405;
            res.set_content(error_json("method not allowed"), "application/json");
            return httplib::Server::HandlerResponse::Handled;
        }
        // without --vad the session route space does not exist at all
        if (a.vad.empty() && is_session_path(req.path)) {
            res.status = 501;
            res.set_content(error_json("sessions need --vad"), "application/json");
            return httplib::Server::HandlerResponse::Handled;
        }
        // httplib reads a chunked body for any method, not only POST, so refuse it everywhere
        if (req.has_header("Transfer-Encoding") || (req.method == "POST" && !req.has_header("Content-Length"))) {
            res.status = 411;
            res.set_content(error_json("a Content-Length body is required"), "application/json");
            return httplib::Server::HandlerResponse::Handled;
        }
        if (req.method == "POST") {
            // per route: exact media type, parameters allowed — a web page can
            // send a cross-site "simple" request (text/plain, form data)
            // without a preflight, but none of these types
            const char * want =
                req.path == "/transcribe" ? "audio/wav" : session_post_type(req.path);
            if (want) {
                std::string ctype = req.get_header_value("Content-Type");
                std::transform(ctype.begin(), ctype.end(), ctype.begin(),
                               [](unsigned char ch) { return (char) std::tolower(ch); });
                const size_t semi = ctype.find(';');
                std::string mime = ctype.substr(0, semi);
                mime.erase(mime.find_last_not_of(" \t") + 1);
                if (mime != want) {
                    res.status = 415;
                    res.set_content(error_json(std::string("Content-Type must be ") + want),
                                    "application/json");
                    return httplib::Server::HandlerResponse::Handled;
                }
            }
        }
        return httplib::Server::HandlerResponse::Unhandled;
    });
    // httplib defaults to SO_REUSEPORT: a second server on the same port would bind silently and
    // split requests. SO_REUSEADDR keeps rebind-after-crash fast while an occupied port fails.
    srv.set_socket_options([](socket_t s) {
        int on = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char *) &on, sizeof(on));
    });
    srv.Get("/health", [](const httplib::Request &, httplib::Response & res) {
        res.set_content("{\"status\":\"ok\"}", "application/json");
    });
    srv.Post("/transcribe", [&](const httplib::Request & req, httplib::Response & res) {
        {
            std::lock_guard<std::mutex> ml(sessions_mu);
            reap_idle();
        }
        std::vector<float> x;
        std::string err;
        if (!read_wav_bytes((const unsigned char *) req.body.data(), req.body.size(), x, err)) {
            res.status = 400;
            res.set_content(error_json(err), "application/json");
            return;
        }
        const auto t0 = std::chrono::steady_clock::now();
        result r;
        bool ok;
        {
            std::lock_guard<std::mutex> lock(decode_mu);
            ok = decode_parakeet(ctx, a, x, r, err);
        }
        const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        if (!ok) {
            res.status = 500;
            res.set_content(error_json(err), "application/json");
            return;
        }
        res.set_content(result_json("parakeet", r, x.size(), elapsed), "application/json");
    });

    // find a live session by hex id: the shared_ptr, or nullptr (404 already
    // set by the caller). Reaps idle sessions while the map is locked.
    auto find_session = [&](const std::string & id) -> std::shared_ptr<session> {
        std::lock_guard<std::mutex> ml(sessions_mu);
        reap_idle();
        const auto it = sessions.find(id);
        return it == sessions.end() ? nullptr : it->second;
    };

    srv.Post("/sessions", [&](const httplib::Request &, httplib::Response & res) {
        std::shared_ptr<session> s = std::make_shared<session>();
        // the VAD context is built before taking the lock: init reads the
        // model file and would serialize every session route behind
        // sessions_mu. A rejected session frees it via ~session.
        whisper_vad_context_params vp = whisper_vad_default_context_params();
        vp.n_threads = a.threads;
        vp.use_gpu   = false;
        s->vad = whisper_vad_init_from_file_with_params(a.vad.c_str(), vp);
        if (!s->vad) {
            res.status = 500;
            res.set_content(error_json("failed to init VAD context"), "application/json");
            return;
        }
        std::string id;
        try {
            // count check and insert under the same lock, or two POSTs could
            // both win the 4-session cap; the id re-rolls while it collides
            std::lock_guard<std::mutex> ml(sessions_mu);
            reap_idle();
            if (sessions.size() >= 4) {
                res.status = 429;
                res.set_content(error_json("at most 4 sessions"), "application/json");
                return;
            }
            do {
                id = new_session_id();
            } while (sessions.count(id) != 0);
            whisper_vad_reset_state(s->vad);
            s->touch.store(now_s());
            sessions.emplace(id, s);
        } catch (...) {
            // std::random_device can throw when the OS refuses entropy; an
            // exception must never escape a request handler
            res.status = 500;
            res.set_content(error_json("no entropy"), "application/json");
            return;
        }
        res.set_content("{\"id\":\"" + id + "\"}", "application/json");
    });

    srv.Post(R"(/sessions/([0-9a-f]{32})/audio)", [&](const httplib::Request & req, httplib::Response & res) {
        const std::string id = req.matches[1].str();
        std::shared_ptr<session> s = find_session(id);
        if (!s) {
            res.status = 404;
            res.set_content(error_json("unknown session"), "application/json");
            return;
        }
        s->touch.store(now_s());
        if (req.body.size() % 4 != 0) {
            res.status = 400;
            res.set_content(error_json("body must be a whole number of float32 samples"),
                            "application/json");
            return;
        }
        if (req.body.size() > 30u * SR * 4) {
            res.status = 413;
            res.set_content(error_json("at most 30 s of audio per request"), "application/json");
            return;
        }
        std::vector<float> fresh(req.body.size() / 4);
        memcpy(fresh.data(), req.body.data(), fresh.size() * 4);
        for (const float v : fresh) {
            if (!std::isfinite(v)) {
                res.status = 400;
                res.set_content(error_json("non-finite sample"), "application/json");
                return;
            }
        }
        bool ok = true;
        {
            std::lock_guard<std::mutex> sl(s->mu);
            if (s->dead) {
                res.status = 404;
                res.set_content(error_json("unknown session"), "application/json");
                return;
            }
            if (s->failed) {
                res.status = 500;
                res.set_content(error_json("decode failed"), "application/json");
                return;
            }
            if (s->inflight > 8) {
                // bound the decode backlog per session; the posted audio is
                // NOT taken, so the client can retry or fall back
                res.status = 429;
                res.set_content(error_json("decode backlog"), "application/json");
                return;
            }
            s->audio.insert(s->audio.end(), fresh.begin(), fresh.end());
            ok = pump_session(s);
        }
        if (!ok) {
            {
                std::lock_guard<std::mutex> sl(s->mu);
                s->dead = true;
            }
            {
                std::lock_guard<std::mutex> ml(sessions_mu);
                sessions.erase(id);
            }
            fprintf(stderr, "ox-stt: VAD failed, session %s dropped\n", id.c_str());
            res.status = 500;
            res.set_content(error_json("VAD failed"), "application/json");
            return;
        }
        std::string out;
        {
            std::lock_guard<std::mutex> sl(s->mu);
            out = session_json(s->results, s->returned, s->inflight, false, "");
            s->returned = s->results.size();
        }
        res.set_content(out, "application/json");
    });

    srv.Post(R"(/sessions/([0-9a-f]{32})/finish)", [&](const httplib::Request & req, httplib::Response & res) {
        const std::string id = req.matches[1].str();
        std::shared_ptr<session> s;
        {
            // gone from the map at once: nothing new may attach while it drains
            std::lock_guard<std::mutex> ml(sessions_mu);
            reap_idle();
            const auto it = sessions.find(id);
            if (it == sessions.end()) {
                res.status = 404;
                res.set_content(error_json("unknown session"), "application/json");
                return;
            }
            s = it->second;
            sessions.erase(it);
        }
        s->touch.store(now_s());
        int status = 0;  // 0 = ok, else the error response
        std::string out, emsg;
        {
            std::unique_lock<std::mutex> sl(s->mu);
            if (s->failed) {
                status = 500;
                emsg = "decode failed";
            } else {
                // the carried remainder becomes one zero-padded VAD window; the
                // segmenter sees only the real samples so its ranges stay exact
                const uint64_t total = s->audio_base + (uint64_t) s->audio.size();
                const size_t rem = (size_t) (total - s->vad_pos);
                bool vad_ok = true;
                if (rem > 0) {
                    float pad[oxstt::SEG_WIN];
                    memcpy(pad, s->audio.data() + (size_t) (s->vad_pos - s->audio_base), rem * 4);
                    memset(pad + rem, 0, (oxstt::SEG_WIN - rem) * 4);
                    if (!whisper_vad_detect_speech_no_reset(s->vad, pad, oxstt::SEG_WIN)) {
                        vad_ok = false;
                    } else {
                        std::vector<oxstt::seg_range> segs;
                        s->seg.feed(whisper_vad_probs(s->vad), 1, pad, rem, segs);
                        for (const oxstt::seg_range & r : segs) {
                            enqueue_segment(s, r);
                        }
                    }
                }
                if (vad_ok) {
                    std::vector<oxstt::seg_range> segs;
                    s->seg.finish(segs);
                    for (const oxstt::seg_range & r : segs) {
                        enqueue_segment(s, r);
                    }
                    if (s->cv.wait_until(sl,
                                         std::chrono::steady_clock::now() + std::chrono::seconds(60),
                                         [&] { return s->inflight == 0 || s->failed; })) {
                        if (s->failed) {
                            status = 500;
                            emsg = "decode failed";
                        } else {
                            std::string text;
                            for (const decoded_seg & d : s->results) {
                                text += (text.empty() ? "" : " ") + d.text;
                            }
                            out = session_json(s->results, s->returned, s->inflight, true, text);
                            s->returned = s->results.size();
                        }
                    } else {
                        status = 504;
                        emsg = "decode did not finish in time";
                    }
                } else {
                    status = 500;
                    emsg = "VAD failed";
                }
            }
            if (status != 0) {
                s->dead = true;  // queued and in-flight jobs drop their results
                s->cv.notify_all();
            }
        }
        if (status == 0) {
            res.set_content(out, "application/json");
        } else {
            res.status = status;
            res.set_content(error_json(emsg), "application/json");
        }
    });

    srv.Delete(R"(/sessions/([0-9a-f]{32}))", [&](const httplib::Request & req, httplib::Response & res) {
        const std::string id = req.matches[1].str();
        std::shared_ptr<session> s;
        {
            std::lock_guard<std::mutex> ml(sessions_mu);
            reap_idle();
            const auto it = sessions.find(id);
            if (it == sessions.end()) {
                res.status = 404;
                res.set_content(error_json("unknown session"), "application/json");
                return;
            }
            s = it->second;
            sessions.erase(it);
        }
        {
            std::lock_guard<std::mutex> sl(s->mu);
            s->dead = true;  // queued and in-flight jobs drop their results
        }
        s->cv.notify_all();
        res.set_content("{}", "application/json");
    });

    if (!srv.listen("127.0.0.1", a.port)) {
        fprintf(stderr, "ox-stt: cannot bind 127.0.0.1:%d\n", a.port);
        join_worker();
        parakeet_free(ctx);
        return 1;
    }
    join_worker();
    parakeet_free(ctx);
    return 0;
}

}  // namespace

int main(int argc, char ** argv) {
    args a;
    if (!parse(argc, argv, a)) {
        usage(argv[0]);
        return 2;
    }
    if (!a.gpu) {
        // -ng must not touch Metal at all. The ggml backend registry eagerly creates
        // every Metal device on first enumeration — MTLCreateSystemDefaultDevice plus
        // compiling the whole embedded shader library (~47 s cold per binary, and it
        // can wake a discrete GPU) — before use_gpu is even read. GGML_METAL_DEVICES=0
        // registers none, so -ng sees no GPU and never pays for it.
        setenv("GGML_METAL_DEVICES", "0", 1);
    }
    if (a.engine == "parakeet" && (!a.lang.empty() || !a.prompt.empty())) {
        fprintf(stderr, "ox-stt: parakeet detects the language itself and takes no prompt; -l/--prompt ignored\n");
    }
    if (!a.verbose) {
        parakeet_log_set(no_log, nullptr);
        whisper_log_set(no_log, nullptr);
    }
    if (a.serve) {
        return serve(a);
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
    const std::string o = result_json(a.engine, r, x.size(), elapsed);

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
