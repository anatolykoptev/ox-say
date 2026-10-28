// Tests for edge_pad.h: plain asserts, no framework. Every check prints what
// failed and exits 1. Each test names the mutation that turns it RED.
#include "edge_pad.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

static int failures = 0;

#define CHECK(cond, msg)                                                                          \
    do {                                                                                          \
        if (!(cond)) {                                                                            \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg);                          \
            ++failures;                                                                           \
        }                                                                                         \
    } while (0)

static std::vector<float> tone(size_t n, float amp) {
    std::vector<float> x(n);
    for (size_t i = 0; i < n; ++i) {
        x[i] = amp * (float) std::sin(2.0 * 3.14159265358979323846 * 440.0 * (double) i / 16000.0);
    }
    return x;
}

static double rms_db(const std::vector<float> & x, size_t at, size_t n) { return edge_pad::rms_dbfs(x.data() + at, n); }

static bool same_samples(const std::vector<float> & out, size_t at, const std::vector<float> & x) {
    for (size_t i = 0; i < x.size(); ++i) {
        if (out[at + i] != x[i]) {
            return false;
        }
    }
    return true;
}

static void append(std::vector<float> & x, const std::vector<float> & y) { x.insert(x.end(), y.begin(), y.end()); }

// pad(): noise | chunk | noise, the chunk bit-exact in the middle, each pad at chunk RMS + kRelDb.
// RED if: the pad length changes, the chunk is copied at the wrong offset, or the level is not
// taken relative to the chunk.
static void t_pad_layout_and_level() {
    const std::vector<float> x = tone(22000, 0.3f);  // 1.375 s, -13.5 dBFS, no quiet edge
    std::vector<float> out;
    edge_pad::layout lay;
    const size_t P = edge_pad::kPadSamples;
    CHECK(edge_pad::pad(x.data(), x.size(), out, lay), "a speech-level chunk was not padded");
    CHECK(out.size() == x.size() + 2 * P, "padded size != chunk + 2 pads");
    CHECK(out.size() == x.size() + 2 * P && same_samples(out, P, x), "chunk is not bit-exact between the pads");
    const double chunk_db = edge_pad::rms_dbfs(x.data(), x.size());
    CHECK(std::fabs(rms_db(out, 0, P) - (chunk_db + edge_pad::kRelDb)) < 0.5, "lead pad level is not chunk RMS + kRelDb");
    CHECK(std::fabs(rms_db(out, P + x.size(), P) - (chunk_db + edge_pad::kRelDb)) < 0.5, "trail pad level is not chunk RMS + kRelDb");
    bool differ = false;
    for (size_t i = 0; i < P; ++i) {
        differ = differ || out[i] != out[P + x.size() + i];
    }
    CHECK(differ, "lead and trail pads are the same samples");
    CHECK(lay.shift == 100 && lay.lo == 100 && lay.hi == 100 + 138 && lay.len == 138,
          "layout of an edge-less chunk != {shift 100, lo 100, hi 238, len 138}");
}

// Digital silence at the chunk's own edges (0.5 s before, 0.3 s after the speech) gets the pad
// noise too, and does not lower the level; the pause in the middle is left alone.
// RED if the edge fill goes (that input decodes empty), if it reaches the interior pause, or if
// the zeros lower the level.
static void t_pad_fills_digital_silence_edges() {
    std::vector<float> x(8000, 0.0f);
    const std::vector<float> s = tone(8000, 0.3f);
    append(x, s);
    x.insert(x.end(), 3200, 0.0f);  // interior pause
    append(x, s);
    x.insert(x.end(), 4800, 0.0f);
    std::vector<float> out;
    edge_pad::layout lay;
    CHECK(edge_pad::pad(x.data(), x.size(), out, lay), "chunk with silent edges was not padded");
    const size_t P = edge_pad::kPadSamples;
    const double tone_db = edge_pad::rms_dbfs(s.data(), s.size());
    CHECK(std::fabs(rms_db(out, P, 8000) - (tone_db + edge_pad::kRelDb)) < 0.5, "leading zeros not filled at the pad level");
    CHECK(std::fabs(rms_db(out, P + x.size() - 4800, 4800) - (tone_db + edge_pad::kRelDb)) < 0.5,
          "trailing zeros not filled at the pad level");
    bool pause_kept = true;
    for (size_t i = 16000; i < 16000 + 3200; ++i) {
        pause_kept = pause_kept && out[P + i] == 0.0f;
    }
    CHECK(pause_kept, "the interior pause was filled");
    CHECK(same_samples(out, P + 8000, s), "speech samples were changed");
    CHECK(lay.lo == 100 + 50 && lay.hi == 100 + (int64_t) (x.size() - 4800) / 160 && lay.len == (int64_t) x.size() / 160,
          "layout does not bound the filled edges");
}

// Quiet speech at the edges is speech: a lead 30 dB and a tail 36 dB under the rest (a far speaker
// before a near one; -43.5 and -49.5 dBFS here) is never filled, its samples stay bit-exact, and
// lo/hi stay at the chunk's ends. RED if the fill bound goes back to one relative to the chunk
// level (it filled anything 22 dB under the level with noise LOUDER than the speech under it, and
// moved lo past it, so "Thanks a lot." came back as nothing).
static void t_quiet_speech_edges_unchanged() {
    const std::vector<float> lead = tone(8000, 0.3f * 0.0316228f), tail = tone(8000, 0.3f * 0.0158489f);
    std::vector<float> x = lead;
    append(x, tone(16000, 0.3f));
    append(x, tail);
    std::vector<float> out;
    edge_pad::layout lay;
    CHECK(edge_pad::pad(x.data(), x.size(), out, lay), "chunk with quiet speech edges was not padded");
    CHECK(same_samples(out, edge_pad::kPadSamples, x), "quiet speech at the edges was changed");
    CHECK(lay.lo == lay.shift && lay.hi == lay.shift + lay.len, "lo/hi moved past quiet speech");
}

// The level is robust to a click: -50 dBFS speech with one full-scale 10 ms frame gets a pad under
// the speech, not 13 dB over it. RED if the level goes back to the plain mean power.
static void t_level_ignores_a_click() {
    std::vector<float> x = tone(16000, 0.00447f);  // -50 dBFS RMS
    for (size_t i = 8000; i < 8160; ++i) {
        x[i] = (i % 2) ? 1.0f : -1.0f;
    }
    std::vector<float> out;
    edge_pad::layout lay;
    CHECK(edge_pad::pad(x.data(), x.size(), out, lay), "quiet speech with a click was not padded");
    const double pad_db = rms_db(out, 0, edge_pad::kPadSamples);
    CHECK(pad_db < -50.0 + edge_pad::kRelDb + 3.0, "a single click lifted the pad above the speech level");
}

// The pad is a whole number of 160-sample mel hops, so the shift is exact in 10 ms ticks.
// RED if kPadSamples and kPadFrames drift apart.
static void t_pad_is_whole_hops() {
    CHECK(edge_pad::kPadSamples % 160 == 0, "pad is not a whole number of mel hops");
    CHECK((int64_t) (edge_pad::kPadSamples / 160) == edge_pad::kPadFrames, "kPadFrames != kPadSamples / 160");
}

// Same input, same seed -> same samples, on every standard library: the noise comes from
// splitmix64 + Box-Muller, not std::normal_distribution (whose output differs between libc++
// and libstdc++). Pinned values: RED if the generator changes, which would silently change
// every decode.
static void t_pad_deterministic_and_pinned() {
    const std::vector<float> x(16000, 0.1f);  // -20 dBFS DC
    std::vector<float> a, b;
    edge_pad::layout la, lb;
    edge_pad::pad(x.data(), x.size(), a, la);
    edge_pad::pad(x.data(), x.size(), b, lb);
    CHECK(a == b, "two pads of the same chunk differ");
    edge_pad::noise g{ edge_pad::kSeed };
    const double v0 = g.gauss(), v1 = g.gauss(), v2 = g.gauss();
    if (!(std::fabs(v0 - 0.199825932) < 1e-6 && std::fabs(v1 - 0.659803513) < 1e-6 &&
          std::fabs(v2 - -0.687310616) < 1e-6)) {
        fprintf(stderr, "noise[0..2] = %.9f %.9f %.9f\n", v0, v1, v2);
        CHECK(false, "noise sequence changed (pinned first three values)");
    }
}

// Silence stays silence: a chunk with no frame above the floor is not padded (out untouched), so
// the decoder never sees noise where there was nothing. RED if the floor check goes or flips.
static void t_floor() {
    std::vector<float> out = { 7.0f };
    edge_pad::layout lay;
    const std::vector<float> zeros(16000, 0.0f);
    CHECK(!edge_pad::pad(zeros.data(), zeros.size(), out, lay), "digital silence was padded");
    CHECK(out.size() == 1 && out[0] == 7.0f && lay.len == 0, "out/layout touched for an unpadded chunk");
    const std::vector<float> quiet = tone(16000, 0.0005f);  // -69 dBFS
    CHECK(!edge_pad::pad(quiet.data(), quiet.size(), out, lay), "a chunk under the floor was padded");
    CHECK(!edge_pad::pad(nullptr, 0, out, lay), "an empty chunk was padded");
    const std::vector<float> above = tone(16000, 0.003f);  // -53.5 dBFS
    CHECK(edge_pad::pad(above.data(), above.size(), out, lay), "a chunk above the floor was not padded");
}

// place(): tokens ending more than kDropMarginFrames before lo (or starting that far after hi) are
// dropped; the rest shift and clamp to [0, len]. RED if the shift is dropped, if pad tokens are
// kept, or if the margin goes.
static void t_place() {
    edge_pad::layout lay;
    lay.shift = 100, lay.lo = 130, lay.hi = 220, lay.len = 137;  // 0.3 s silent lead, 0.17 s silent tail
    CHECK(edge_pad::kDropMarginFrames == 50, "drop margin is not 0.5 s");
    int64_t t0 = 8, t1 = 72;
    CHECK(!edge_pad::place(t0, t1, lay), "token in the outer lead pad kept");
    CHECK(t0 == 8 && t1 == 72, "a dropped token's times were changed");
    t0 = 88, t1 = 96;
    CHECK(edge_pad::place(t0, t1, lay) && t0 == 0 && t1 == 0, "early-stamped first piece dropped or not clamped to 0");
    t0 = 104, t1 = 128;
    CHECK(edge_pad::place(t0, t1, lay) && t0 == 4 && t1 == 28, "piece inside the filled lead dropped or not shifted");
    t0 = 140, t1 = 160;
    CHECK(edge_pad::place(t0, t1, lay) && t0 == 40 && t1 == 60, "token inside the chunk not shifted by the pad");
    t0 = 216, t1 = 248;
    CHECK(edge_pad::place(t0, t1, lay) && t0 == 116 && t1 == 137, "token straddling the chunk end not clamped to len");
    t0 = 270, t1 = 278;
    CHECK(!edge_pad::place(t0, t1, lay), "token in the outer trail pad kept");
    t0 = 0, t1 = 337;  // the whole decode: a segment
    CHECK(edge_pad::place(t0, t1, lay) && t0 == 0 && t1 == 137, "whole-decode span not mapped onto [0, len]");
}

// chunk_frames(): 10 ms units, rounded up, so a token in the last partial hop is not "in the pad".
static void t_chunk_frames() {
    CHECK(edge_pad::chunk_frames(16000) == 100, "1 s != 100 frames");
    CHECK(edge_pad::chunk_frames(16001) == 101, "partial last hop not rounded up");
}

// join_pieces(): segment text from the tokens that were kept, by parakeet's own rules: U+2581 is a
// space (none before the first character), and exactly the library's control pieces are dropped
// (parakeet.cpp is_sentencepiece_control: <unk>, <s>, </s>, [BLANK]). RED if the list widens to
// "anything in <...>" or loses one.
static void t_join_pieces() {
    const std::string sp = "\xE2\x96\x81";
    CHECK(edge_pad::join_pieces({ sp + "Ok", "ay", sp + "is", sp + "ready", "." }) == "Okay is ready.",
          "pieces not joined as SentencePiece text");
    CHECK(edge_pad::join_pieces({ "<unk>", "<s>", sp + "Hi", "</s>", "[BLANK]" }) == "Hi",
          "a library control piece was kept, or a space left before the first word");
    CHECK(edge_pad::join_pieces({ sp + "a", "<b>" }) == "a<b>", "a non-control <...> piece was dropped");
    CHECK(edge_pad::join_pieces({}).empty(), "no pieces is not empty text");
}

static edge_pad::token tok(const std::string & piece, int64_t t0, int64_t t1) {
    const std::string sp = "\xE2\x96\x81";
    return { piece, t0, t1, 0.9, piece.compare(0, sp.size(), sp) == 0 };
}

static std::string joined(const std::vector<edge_pad::word> & ws, size_t from) {
    std::string s;
    for (size_t i = from; i < ws.size(); ++i) {
        s += (s.empty() ? "" : " ") + ws[i].w;
    }
    return s;
}

// map_segment(): the token loop decode_parakeet runs on every padded segment.
// RED if: the drop rule goes (pad tokens become words), the punctuation exemption goes ("soon."
// loses its period, a word-start "-" vanishes), the shift goes (times 1 s late), the text is
// not rebuilt after a drop (text says "um" while words do not), or a dropped word start lets its
// continuation glue onto the word before.
static void t_map_segment_padded() {
    const std::string sp = "\xE2\x96\x81";
    edge_pad::layout lay;
    lay.shift = 100, lay.lo = 100, lay.hi = 100 + 137, lay.len = 137;  // drop: t1 <= 50 or t0 >= 287
    const std::vector<edge_pad::token> toks = {
        tok(sp + "um", 0, 8),        // noise in the outer lead pad: dropped
        tok(sp + "Than", 92, 100),   // stamped inside the pad, within the margin: kept
        tok("ks", 100, 108),
        tok(sp + "a", 124, 132),
        tok(".", 132, 132),
        tok(sp + "soon", 228, 316),  // runs into the trail pad: kept, clamped to len
        tok(".", 316, 316),          // punctuation at the last word's end, past the margin: exempt
        tok(sp + "-", 316, 316),     // word-start punctuation (the vocab has U+2581- and U+2581'): exempt
        tok(sp + "noise", 300, 308), // noise in the outer trail pad: dropped
        tok(".", 308, 308),          // punctuation after a dropped token: dropped too
    };
    std::vector<edge_pad::word> ws = { { "before", 0.0, 0.5, 1.0 } };
    const edge_pad::segment_result r = edge_pad::map_segment(toks, "LIBRARY TEXT", 0, 337, &lay, 10.0, 11.37, ws);
    CHECK(r.keep, "segment with speech not kept");
    CHECK(r.n_dropped == 3, "dropped count != 3 (um, noise, its period)");
    CHECK(ws.size() == 5 && ws[0].w == "before", "words before the segment were changed or words miscounted");
    CHECK(joined(ws, 1) == "Thanks a. soon. -", "words != Thanks / a. / soon. / -");
    CHECK(r.text == "Thanks a. soon. -", "rebuilt text != the kept words");
    CHECK(r.text == joined(ws, 1), "text and words disagree");
    if (ws.size() == 5) {
        CHECK(std::fabs(ws[1].s - 10.0) < 1e-9 && std::fabs(ws[1].e - 10.08) < 1e-9, "Thanks not at [10.00, 10.08]");
        CHECK(std::fabs(ws[2].s - 10.24) < 1e-9, "a. not at 10.24 (shift dropped?)");
        CHECK(std::fabs(ws[3].s - 11.28) < 1e-9 && std::fabs(ws[3].e - 11.37) < 1e-9, "soon. not clamped to the chunk end");
        CHECK(std::fabs(ws[4].s - 11.37) < 1e-9 && std::fabs(ws[4].e - 11.37) < 1e-9, "word-start - not at the previous word's end");
    }
    CHECK(std::fabs(r.s - 10.0) < 1e-9 && std::fabs(r.e - 11.37) < 1e-9, "segment span not [10.00, 11.37]");

    // A dropped word start must not let its continuation glue onto the word before.
    std::vector<edge_pad::word> w2 = { { "prev", 0.0, 0.5, 1.0 } };
    edge_pad::map_segment({ tok(sp + "Hel", 0, 8), tok("lo", 100, 108) }, "Hello", 0, 337, &lay, 0.0, 1.37, w2);
    CHECK(w2.size() == 2 && w2[0].w == "prev" && w2[1].w == "lo", "continuation of a dropped word start glued on");

    // Nothing but pad: no segment, no words.
    std::vector<edge_pad::word> w3;
    const edge_pad::segment_result r3 = edge_pad::map_segment({ tok(sp + "um", 0, 8) }, "um", 0, 337, &lay, 0.0, 1.37, w3);
    CHECK(!r3.keep && w3.empty() && r3.n_dropped == 1, "a pad-only segment was kept");
}

// Unpadded (a chunk under the floor): every token kept on its raw time, the library's own text.
// RED if the unpadded path starts dropping or rebuilding.
static void t_map_segment_unpadded() {
    const std::string sp = "\xE2\x96\x81";
    std::vector<edge_pad::word> ws;
    const edge_pad::segment_result r =
        edge_pad::map_segment({ tok(sp + "Hi", 0, 8), tok(".", 8, 8) }, "Hi.", 0, 40, nullptr, 2.0, 2.4, ws);
    CHECK(r.keep && r.n_dropped == 0 && r.text == "Hi.", "unpadded segment not kept with the library text");
    CHECK(ws.size() == 1 && ws[0].w == "Hi." && std::fabs(ws[0].s - 2.0) < 1e-9 && std::fabs(ws[0].e - 2.08) < 1e-9,
          "unpadded word not Hi. at [2.00, 2.08]");
    CHECK(std::fabs(r.s - 2.0) < 1e-9 && std::fabs(r.e - 2.4) < 1e-9, "unpadded segment not [2.0, 2.4]");
}

int main() {
    t_pad_layout_and_level();
    t_pad_fills_digital_silence_edges();
    t_quiet_speech_edges_unchanged();
    t_level_ignores_a_click();
    t_pad_is_whole_hops();
    t_pad_deterministic_and_pinned();
    t_floor();
    t_place();
    t_chunk_frames();
    t_join_pieces();
    t_map_segment_padded();
    t_map_segment_unpadded();
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
