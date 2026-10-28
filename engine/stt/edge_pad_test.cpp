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

// pad(): noise | chunk | noise, the chunk bit-exact in the middle, each pad at chunk RMS + kRelDb.
// RED if: the pad length changes, the chunk is copied at the wrong offset, or the level is not
// taken relative to the chunk.
static void t_pad_layout_and_level() {
    const std::vector<float> x = tone(22000, 0.3f);  // 1.375 s, -13.5 dBFS, no quiet edge
    std::vector<float> out;
    edge_pad::layout lay;
    CHECK(edge_pad::pad(x.data(), x.size(), out, lay), "a speech-level chunk was not padded");
    CHECK(out.size() == x.size() + 2 * edge_pad::kPadSamples, "padded size != chunk + 2 pads");
    bool same = out.size() == x.size() + 2 * edge_pad::kPadSamples;
    for (size_t i = 0; same && i < x.size(); ++i) {
        same = out[edge_pad::kPadSamples + i] == x[i];
    }
    CHECK(same, "chunk is not bit-exact between the pads");
    const double chunk_db = edge_pad::rms_dbfs(x.data(), x.size());
    const double lead_db  = edge_pad::rms_dbfs(out.data(), edge_pad::kPadSamples);
    const double trail_db = edge_pad::rms_dbfs(out.data() + edge_pad::kPadSamples + x.size(), edge_pad::kPadSamples);
    CHECK(std::fabs(lead_db - (chunk_db + edge_pad::kRelDb)) < 0.5, "lead pad level is not chunk RMS + kRelDb");
    CHECK(std::fabs(trail_db - (chunk_db + edge_pad::kRelDb)) < 0.5, "trail pad level is not chunk RMS + kRelDb");
    bool differ = false;
    for (size_t i = 0; i < edge_pad::kPadSamples; ++i) {
        differ = differ || out[i] != out[edge_pad::kPadSamples + x.size() + i];
    }
    CHECK(differ, "lead and trail pads are the same samples");
    CHECK(lay.shift == 100 && lay.lo == 100 && lay.hi == 100 + 138 && lay.len == 138,
          "layout of an edge-less chunk != {shift 100, lo 100, hi 238, len 138}");
}

// Quiet edges inside the chunk (here 0.5 s of digital zeros before and 0.3 s after the speech)
// get the pad noise too, and the level ignores them; the pause in the middle is left alone.
// RED if the edge fill goes (the zeros stay zeros: that input decodes empty), if it reaches the
// interior pause, or if the zeros lower the level.
static void t_pad_fills_quiet_edges() {
    std::vector<float> x(8000, 0.0f);
    const std::vector<float> s = tone(8000, 0.3f);
    x.insert(x.end(), s.begin(), s.end());
    x.insert(x.end(), 3200, 0.0f);  // interior pause
    x.insert(x.end(), s.begin(), s.end());
    x.insert(x.end(), 4800, 0.0f);
    std::vector<float> out;
    edge_pad::layout lay;
    CHECK(edge_pad::pad(x.data(), x.size(), out, lay), "chunk with quiet edges was not padded");
    const size_t P = edge_pad::kPadSamples;
    const double tone_db = edge_pad::rms_dbfs(s.data(), s.size());
    const double lead_db = edge_pad::rms_dbfs(out.data() + P, 8000);
    const double tail_db = edge_pad::rms_dbfs(out.data() + P + x.size() - 4800, 4800);
    CHECK(std::fabs(lead_db - (tone_db + edge_pad::kRelDb)) < 0.5, "leading zeros not filled at the pad level");
    CHECK(std::fabs(tail_db - (tone_db + edge_pad::kRelDb)) < 0.5, "trailing zeros not filled at the pad level");
    bool pause_kept = true;
    for (size_t i = 16000; i < 16000 + 3200; ++i) {
        pause_kept = pause_kept && out[P + i] == 0.0f;
    }
    CHECK(pause_kept, "the interior pause was filled");
    bool speech_kept = true;
    for (size_t i = 8000; i < 16000; ++i) {
        speech_kept = speech_kept && out[P + i] == x[i];
    }
    CHECK(speech_kept, "speech samples were changed");
    CHECK(lay.lo == 100 + 50 && lay.hi == 100 + (int64_t) (x.size() - 4800) / 160 && lay.len == (int64_t) x.size() / 160,
          "layout does not bound the filled edges");
}

// The pad is a whole number of 160-sample hops, so the token shift is exact in 10 ms units.
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
// dropped; the rest shift and clamp to [0, len]. RED if the shift is dropped (times land ~1 s
// late), if pad tokens are kept, or if the margin goes: the first piece of real speech is often
// stamped a frame or two inside the pad, and a margin of 0 cuts "Thanks" to "ks".
static void t_place() {
    edge_pad::layout lay;
    lay.shift = 100, lay.lo = 130, lay.hi = 220, lay.len = 137;  // 0.3 s quiet lead, 0.17 s quiet tail
    CHECK(edge_pad::kDropMarginFrames == 50, "drop margin is not 0.5 s");
    int64_t t0 = 8, t1 = 72;
    CHECK(!edge_pad::place(t0, t1, lay), "token in the outer lead pad kept");
    CHECK(t0 == 8 && t1 == 72, "a dropped token's times were changed");
    t0 = 88, t1 = 96;
    CHECK(edge_pad::place(t0, t1, lay) && t0 == 0 && t1 == 0, "early-stamped first piece dropped or not clamped to 0");
    t0 = 104, t1 = 128;
    CHECK(edge_pad::place(t0, t1, lay) && t0 == 4 && t1 == 28, "piece inside the filled quiet lead dropped or not shifted");
    t0 = 140, t1 = 160;
    CHECK(edge_pad::place(t0, t1, lay) && t0 == 40 && t1 == 60, "token inside the chunk not shifted by the pad");
    t0 = 216, t1 = 248;
    CHECK(edge_pad::place(t0, t1, lay) && t0 == 116 && t1 == 137, "token straddling the chunk end not clamped to len");
    t0 = 232, t1 = 240;
    CHECK(edge_pad::place(t0, t1, lay) && t0 == 132 && t1 == 137, "late-stamped last piece dropped or not clamped");
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

// join_pieces(): segment text from the tokens that were kept, SentencePiece rules: U+2581 is a
// space (none before the first piece), control pieces like <unk> are dropped.
static void t_join_pieces() {
    const std::string sp = "\xE2\x96\x81";
    CHECK(edge_pad::join_pieces({ sp + "Ok", "ay", sp + "is", sp + "ready", "." }) == "Okay is ready.",
          "pieces not joined as SentencePiece text");
    CHECK(edge_pad::join_pieces({ "<unk>", sp + "Hi" }) == "Hi", "control piece kept or space left before the first word");
    CHECK(edge_pad::join_pieces({}).empty(), "no pieces is not empty text");
}

int main() {
    t_pad_layout_and_level();
    t_pad_fills_quiet_edges();
    t_pad_is_whole_hops();
    t_pad_deterministic_and_pinned();
    t_floor();
    t_place();
    t_chunk_frames();
    t_join_pieces();
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
