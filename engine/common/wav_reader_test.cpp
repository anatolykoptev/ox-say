// Standalone test for wav_reader.h (#13): no whisper/ggml deps.
//   c++ -std=c++17 -O1 -Wall -Wextra -Werror -o wav-reader-test engine/common/wav_reader_test.cpp && ./wav-reader-test
//
// The oracle is the reader ox-stt shipped before it moved here, kept below verbatim (legacy_read): a
// seeded corpus of mangled WAVs must be accepted/rejected identically, with the same samples and message.
#include "wav_reader.h"

#include <atomic>
#include <cstdlib>
#include <new>
#include <random>

// --- allocation counter: sample-sized allocations made while armed -------------------------------
static std::atomic<size_t> g_big_min{0};  // 0 = disarmed
static std::atomic<int>    g_big_count{0};
// All replaced forms pair malloc with free, and are noinline: GCC's -Wmismatched-new-delete otherwise
// inlines operator delete into callers, sees free() applied to the result of the (builtin-allocator)
// operator new and warns, although the replaced pair is consistent.
#define NOINL __attribute__((noinline))
NOINL void * operator new(size_t n) {
    const size_t m = g_big_min.load();
    if (m && n >= m) {
        g_big_count++;
    }
    void * p = malloc(n ? n : 1);
    if (!p) throw std::bad_alloc();
    return p;
}
NOINL void * operator new[](size_t n) { return operator new(n); }
NOINL void operator delete(void * p) noexcept { free(p); }
NOINL void operator delete[](void * p) noexcept { free(p); }
NOINL void operator delete(void * p, size_t) noexcept { free(p); }
NOINL void operator delete[](void * p, size_t) noexcept { free(p); }

static int g_fail = 0;
static const char * g_cur = "";
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s (%s:%d): %s\n", g_cur, __FILE__, __LINE__, #c); ++g_fail; } } while (0)
#define RUN(f) do { g_cur = #f; f(); } while (0)

using Bytes = std::vector<unsigned char>;

static void put32(Bytes & b, uint32_t v) { for (int i = 0; i < 4; ++i) b.push_back((v >> (8 * i)) & 255); }
static void put16(Bytes & b, uint16_t v) { b.push_back(v & 255); b.push_back(v >> 8); }
static void tag(Bytes & b, const char * t) { b.insert(b.end(), t, t + 4); }

static Bytes fmt_chunk(int fmt, int ch, uint32_t rate, int bits) {
    Bytes b;
    tag(b, "fmt "); put32(b, 16);
    put16(b, fmt); put16(b, ch); put32(b, rate);
    put32(b, rate * ch * bits / 8); put16(b, ch * bits / 8); put16(b, bits);
    return b;
}
static Bytes pcm16_data(const std::vector<int16_t> & s) {
    Bytes b; tag(b, "data"); put32(b, (uint32_t) s.size() * 2);
    for (int16_t v : s) put16(b, (uint16_t) v);
    return b;
}
static Bytes f32_data(const std::vector<float> & s) {
    Bytes b; tag(b, "data"); put32(b, (uint32_t) s.size() * 4);
    for (float v : s) { uint32_t u; memcpy(&u, &v, 4); put32(b, u); }
    return b;
}
static Bytes riff(const std::vector<Bytes> & chunks) {
    Bytes body; tag(body, "WAVE");
    for (const Bytes & c : chunks) body.insert(body.end(), c.begin(), c.end());
    Bytes b; tag(b, "RIFF"); put32(b, (uint32_t) body.size());
    b.insert(b.end(), body.begin(), body.end());
    return b;
}
static Bytes odd_chunk(const char * t, size_t n) {  // n payload bytes (odd) + the pad byte
    Bytes b; tag(b, t); put32(b, (uint32_t) n);
    for (size_t i = 0; i < n; ++i) b.push_back(0xAB);
    if (n & 1) b.push_back(0);
    return b;
}

struct R { bool ok; std::vector<float> x; std::string err; };
static R rd(const Bytes & b) {
    R r; r.ok = oxwav::read_bytes(b.data(), b.size(), r.x, r.err); return r;
}

// --- the pre-move ox-stt reader, verbatim, as the differential oracle -----------------------------
static uint32_t lrd32(const unsigned char * p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t) p[3] << 24; }
static uint16_t lrd16(const unsigned char * p) { return (uint16_t) (p[0] | p[1] << 8); }
static bool legacy_read(const unsigned char * buf, size_t size, std::vector<float> & out, std::string & err) {
    const uint32_t SR = 16000;
    if (size < 12 || memcmp(buf, "RIFF", 4) != 0 || memcmp(buf + 8, "WAVE", 4) != 0) {
        err = "not a RIFF/WAVE file";
        return false;
    }
    int fmt = 0, ch = 0, bits = 0;
    uint32_t rate = 0;
    for (size_t off = 12; off + 8 <= size;) {
        const uint32_t len = lrd32(buf + off + 4);
        const size_t body = off + 8;
        if (body + len > size && memcmp(buf + off, "data", 4) != 0) {
            break;
        }
        if (memcmp(buf + off, "fmt ", 4) == 0 && len >= 16) {
            fmt  = lrd16(buf + body);
            ch   = lrd16(buf + body + 2);
            rate = lrd32(buf + body + 4);
            bits = lrd16(buf + body + 14);
            if (fmt == 0xFFFE && len >= 26) {
                fmt = lrd16(buf + body + 24);
            }
        } else if (memcmp(buf + off, "data", 4) == 0) {
            if (rate != SR || ch != 1 || !((fmt == 1 && bits == 16) || (fmt == 3 && bits == 32))) {
                err = "need 16 kHz mono PCM16 or float32 (got rate " + std::to_string(rate) + ", channels " +
                      std::to_string(ch) + ", format " + std::to_string(fmt) + "/" + std::to_string(bits) + " bit)";
                return false;
            }
            const size_t avail = (len == 0 || len == 0xFFFFFFFFu) ? size - body : std::min<size_t>(len, size - body);
            if (fmt == 1) {
                out.resize(avail / 2);
                for (size_t i = 0; i < out.size(); ++i) {
                    out[i] = (int16_t) lrd16(buf + body + 2 * i) / 32768.0f;
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

static const std::vector<int16_t> kS = { 0, 1, -1, 16384, -16384, 32767, -32768, 100 };

static void t_pcm16() {
    R r = rd(riff({ fmt_chunk(1, 1, 16000, 16), pcm16_data(kS) }));
    CHECK(r.ok);
    CHECK(r.x.size() == kS.size());
    for (size_t i = 0; i < kS.size() && i < r.x.size(); ++i) CHECK(r.x[i] == kS[i] / 32768.0f);
}
static void t_float32() {
    const std::vector<float> s = { 0.0f, 0.5f, -0.25f, 1.0f };
    R r = rd(riff({ fmt_chunk(3, 1, 16000, 32), f32_data(s) }));
    CHECK(r.ok && r.x == s);
}
static void t_float32_nonfinite() {
    R r = rd(riff({ fmt_chunk(3, 1, 16000, 32), f32_data({ 0.1f, INFINITY }) }));
    CHECK(!r.ok && r.err == "float WAV has non-finite samples");
}
static void t_wrong_rate() {
    R r = rd(riff({ fmt_chunk(1, 1, 44100, 16), pcm16_data(kS) }));
    CHECK(!r.ok);
    CHECK(r.err == "need 16 kHz mono PCM16 or float32 (got rate 44100, channels 1, format 1/16 bit)");
}
static void t_stereo() {  // F3: accepting 2 channels must go red here
    R r = rd(riff({ fmt_chunk(1, 2, 16000, 16), pcm16_data(kS) }));
    CHECK(!r.ok);
    CHECK(r.err == "need 16 kHz mono PCM16 or float32 (got rate 16000, channels 2, format 1/16 bit)");
}
static void t_truncated_data() {  // declared length past EOF: take what is there, whole samples only
    Bytes b = riff({ fmt_chunk(1, 1, 16000, 16), pcm16_data(kS) });
    b.resize(b.size() - 3);  // 8 samples -> 6 whole samples + 1 stray byte
    R r = rd(b);
    CHECK(r.ok && r.x.size() == kS.size() - 2);
    for (size_t i = 0; i < r.x.size(); ++i) CHECK(r.x[i] == kS[i] / 32768.0f);
}
static void t_truncated_to_nothing() {
    Bytes b = riff({ fmt_chunk(1, 1, 16000, 16), pcm16_data(kS) });
    b.resize(b.size() - kS.size() * 2);  // data header, zero payload
    R r = rd(b);
    CHECK(!r.ok && r.err == "no audio samples");
}
static void t_streaming_length() {  // 0 and 0xFFFFFFFF both mean "rest of file"
    for (uint32_t L : { 0u, 0xFFFFFFFFu }) {
        Bytes b = riff({ fmt_chunk(1, 1, 16000, 16), pcm16_data(kS) });
        const size_t at = 12 + 24 + 4;  // data chunk length field
        for (int i = 0; i < 4; ++i) b[at + i] = (L >> (8 * i)) & 255;
        R r = rd(b);
        CHECK(r.ok && r.x.size() == kS.size());
    }
}
static void t_missing_fmt() {
    R r = rd(riff({ pcm16_data(kS) }));
    CHECK(!r.ok && r.err.rfind("need 16 kHz mono PCM16 or float32 (got rate 0,", 0) == 0);
}
static void t_no_data_chunk() {
    R r = rd(riff({ fmt_chunk(1, 1, 16000, 16) }));
    CHECK(!r.ok && r.err == "no data chunk");
}
static void t_not_riff() {
    Bytes b = riff({ fmt_chunk(1, 1, 16000, 16), pcm16_data(kS) });
    b[0] = 'X';
    CHECK(rd(b).err == "not a RIFF/WAVE file");
    CHECK(rd(Bytes(5, 0)).err == "not a RIFF/WAVE file");
}
// Odd-sized chunks before fmt and before data carry a pad byte; skipping it is what keeps the walk
// aligned. Without it the next header is read one byte off and the file is rejected (F1).
static void t_odd_chunks() {
    R r = rd(riff({ odd_chunk("LIST", 5), fmt_chunk(1, 1, 16000, 16), odd_chunk("junk", 3), pcm16_data(kS) }));
    CHECK(r.ok && r.x.size() == kS.size());
}
static void t_extra_chunks_before_data() {
    R r = rd(riff({ fmt_chunk(1, 1, 16000, 16), odd_chunk("LIST", 12), odd_chunk("fact", 4), pcm16_data(kS) }));
    CHECK(r.ok && r.x.size() == kS.size());
}
static void t_extensible() {
    Bytes f; tag(f, "fmt "); put32(f, 40);
    put16(f, 0xFFFE); put16(f, 1); put32(f, 16000); put32(f, 32000); put16(f, 2); put16(f, 16);
    put16(f, 22); put16(f, 16); put32(f, 4);
    put16(f, 1);  // sub-format PCM
    for (int i = 0; i < 14; ++i) f.push_back(0);
    R r = rd(riff({ f, pcm16_data(kS) }));
    CHECK(r.ok && r.x.size() == kS.size());
}

// --- the offset / padding API ----------------------------------------------------------------------
static void t_padded() {
    const size_t ctx = 5, win = 3;
    for (int kind = 0; kind < 2; ++kind) {
        Bytes w = kind == 0 ? riff({ fmt_chunk(1, 1, 16000, 16), pcm16_data(kS) })
                            : riff({ fmt_chunk(3, 1, 16000, 32), f32_data({ 0.5f, -0.5f, 0.25f, 1.0f, 0.0f, -1.0f, 0.125f, 0.75f }) });
        R plain = rd(w);
        CHECK(plain.ok);
        std::vector<float> xp; std::string err;
        // ox-align's shape: ctx before, then ctx + enough zeros to fill whole windows after
        auto tail = [&](size_t n) { return ctx + ((win - n % win) % win); };
        CHECK(oxwav::read_bytes_padded(w.data(), w.size(), xp, err, ctx, tail));
        const size_t n = plain.x.size();
        CHECK(xp.size() == ctx + n + tail(n));
        CHECK((xp.size() - 2 * ctx) % win == 0);
        for (size_t i = 0; i < ctx; ++i) CHECK(xp[i] == 0.0f);                          // head: exactly ctx zeros
        for (size_t i = 0; i < n; ++i) CHECK(xp[ctx + i] == plain.x[i]);                // body == plain read
        for (size_t i = ctx + n; i < xp.size(); ++i) CHECK(xp[i] == 0.0f);              // tail zeros
    }
}
static void t_padded_errors_same() {
    Bytes bad = riff({ fmt_chunk(1, 2, 16000, 16), pcm16_data(kS) });
    std::vector<float> xp; std::string err;
    CHECK(!oxwav::read_bytes_padded(bad.data(), bad.size(), xp, err, 7, [](size_t) { return (size_t) 7; }));
    CHECK(err == rd(bad).err);
}
// The padded buffer is the only sample-sized allocation: no unpadded intermediate (#13.1).
static void t_single_allocation() {
    std::vector<int16_t> s(40000);
    for (size_t i = 0; i < s.size(); ++i) s[i] = (int16_t) (8000 * std::sin(i * 0.05));
    Bytes w = riff({ fmt_chunk(1, 1, 16000, 16), pcm16_data(s) });
    std::vector<float> xp; std::string err;
    g_big_count = 0; g_big_min = s.size() * 4;  // anything as large as the unpadded float samples
    const bool ok = oxwav::read_bytes_padded(w.data(), w.size(), xp, err, 4000, [](size_t) { return (size_t) 4000; });
    g_big_min = 0;
    CHECK(ok);
    CHECK(g_big_count == 1);
    CHECK(xp.capacity() == xp.size());
}

// --- differential: mangled WAVs, old reader vs shared reader ---------------------------------------
static void t_differential() {
    std::mt19937 rng(20261028);
    std::vector<Bytes> seeds = {
        riff({ fmt_chunk(1, 1, 16000, 16), pcm16_data(kS) }),
        riff({ fmt_chunk(3, 1, 16000, 32), f32_data({ 0.5f, -0.5f, 0.25f }) }),
        riff({ odd_chunk("LIST", 5), fmt_chunk(1, 1, 16000, 16), odd_chunk("junk", 3), pcm16_data(kS) }),
        riff({ fmt_chunk(1, 2, 16000, 16), pcm16_data(kS) }),
    };
    int agree_ok = 0, agree_bad = 0;
    for (int it = 0; it < 20000; ++it) {
        Bytes b = seeds[rng() % seeds.size()];
        const int muts = 1 + (int) (rng() % 3);
        for (int m = 0; m < muts; ++m) {
            switch (rng() % 4) {
                case 0: if (!b.empty()) b[rng() % b.size()] = (unsigned char) rng(); break;
                case 1: b.resize(rng() % (b.size() + 1)); break;
                case 2: if (!b.empty()) b[rng() % b.size()] ^= (unsigned char) (1u << (rng() % 8)); break;
                default: b.insert(b.begin() + rng() % (b.size() + 1), (unsigned char) rng()); break;
            }
        }
        std::vector<float> a, c; std::string ea, ec;
        const bool oa = legacy_read(b.data(), b.size(), a, ea);
        const bool oc = oxwav::read_bytes(b.data(), b.size(), c, ec);
        CHECK(oa == oc);
        if (oa != oc) return;
        if (oa) { CHECK(a.size() == c.size() && (a.empty() || memcmp(a.data(), c.data(), a.size() * 4) == 0)); ++agree_ok; }
        else    { CHECK(ea == ec); ++agree_bad; }
    }
    CHECK(agree_ok > 1000 && agree_bad > 1000);  // the corpus exercises both outcomes
}

int main() {
    RUN(t_pcm16); RUN(t_float32); RUN(t_float32_nonfinite); RUN(t_wrong_rate); RUN(t_stereo); RUN(t_truncated_data);
    RUN(t_truncated_to_nothing); RUN(t_streaming_length); RUN(t_missing_fmt); RUN(t_no_data_chunk); RUN(t_not_riff);
    RUN(t_odd_chunks); RUN(t_extra_chunks_before_data); RUN(t_extensible);
    RUN(t_padded); RUN(t_padded_errors_same); RUN(t_single_allocation); RUN(t_differential);
    if (g_fail) { fprintf(stderr, "%d check(s) failed\n", g_fail); return 1; }
    printf("wav_reader_test: ok\n");
    return 0;
}
