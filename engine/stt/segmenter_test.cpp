// Tests for segmenter.h: plain asserts, no framework. Every check prints what
// failed and exits 1. Each test names the mutation that turns it RED.
#include "segmenter.h"

#include <algorithm>
#include <cstdio>
#include <initializer_list>
#include <vector>

using oxstt::seg_range;
using oxstt::segmenter;

static int failures = 0;

#define CHECK(cond, msg)                                                                          \
    do {                                                                                          \
        if (!(cond)) {                                                                            \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg);                          \
            ++failures;                                                                           \
        }                                                                                         \
    } while (0)

// A stream of per-window probabilities plus matching constant-amplitude samples.
struct stream {
    std::vector<float> p;
    std::vector<float> x;  // x.size() == p.size() * 512

    void add(int n_windows, float prob, float amp = 0.8f) {
        for (int i = 0; i < n_windows; ++i) {
            p.push_back(prob);
        }
        x.insert(x.end(), (size_t) n_windows * 512, amp);
    }
    void silence_at(size_t s, size_t e) {  // zero out samples [s, e)
        for (size_t i = s; i < e && i < x.size(); ++i) {
            x[i] = 0.0f;
        }
    }
};

static std::vector<seg_range> run(const stream & s, int chunk = 0) {
    segmenter seg;
    std::vector<seg_range> out;
    if (chunk <= 0) {
        seg.feed(s.p.data(), s.p.size(), s.x.data(), s.x.size(), out);
    } else {
        for (size_t i = 0; i < s.p.size(); i += (size_t) chunk) {
            const size_t n = std::min((size_t) chunk, s.p.size() - i);
            seg.feed(s.p.data() + i, n, s.x.data() + i * 512, n * 512, out);
        }
    }
    seg.finish(out);
    return out;
}

static bool eq(const std::vector<seg_range> & got, std::initializer_list<seg_range> want) {
    if (got.size() != want.size()) {
        return false;
    }
    size_t i = 0;
    for (const seg_range & w : want) {
        if (got[i].s != w.s || got[i].e != w.e) {
            return false;
        }
        ++i;
    }
    return true;
}

static void dump(const char * name, const std::vector<seg_range> & v) {
    fprintf(stderr, "%s:", name);
    for (const seg_range & r : v) {
        fprintf(stderr, " [%llu,%llu)", (unsigned long long) r.s, (unsigned long long) r.e);
    }
    fprintf(stderr, "\n");
}

// One utterance closed by a 400 ms pause: pads land exactly.
// RED when: pre-pad 200 ms -> 100 ms (start 7040 -> 8640).
static void t_one_utterance() {
    stream s;
    s.add(20, 0.1f);  // 0..10239 silence
    s.add(30, 0.9f);  // 10240..25599 speech
    s.add(30, 0.1f);  // close after 6400 samples of silence (window 62)
    const std::vector<seg_range> got = run(s);
    if (!eq(got, { {7040, 28800} })) {
        dump("t_one_utterance", got);
        CHECK(false, "expected exactly [{7040,28800}]");
    }
}

// A 300 ms pause inside speech must not split the segment.
// RED when: close threshold 400 ms -> 300 ms (the 320 ms pause splits it in two).
static void t_short_pause_no_split() {
    stream s;
    s.add(10, 0.1f);
    s.add(20, 0.9f);  // speech 5120..15359
    s.add(10, 0.1f);  // 320 ms pause < 400 ms
    s.add(20, 0.9f);  // speech 20480..30719
    s.add(13, 0.1f);  // closes
    const std::vector<seg_range> got = run(s);
    if (!eq(got, { {1920, 33920} })) {
        dump("t_short_pause_no_split", got);
        CHECK(false, "expected exactly [{1920,33920}]");
    }
}

// A 192 ms blip below the 250 ms minimum is dropped, not emitted.
// RED when: min speech 250 ms -> 100 ms (the blip survives as its own segment).
static void t_blip_dropped() {
    stream s;
    s.add(10, 0.1f);
    s.add(6, 0.9f);   // 6 * 512 = 3072 samples = 192 ms of speech
    s.add(30, 0.1f);
    const std::vector<seg_range> got = run(s);
    if (!got.empty()) {
        dump("t_blip_dropped", got);
        CHECK(false, "expected no segments (blip under min speech)");
    }
}

// Hysteresis: windows in [0.35, 0.5) while in speech are neither an onset nor
// silence; a long 0.4 stretch must not close the segment.
// RED when: the in-speech silence test uses p < on (0.5) instead of p < off
// (0.35) — the 0.4 windows then close the segment and a second segment opens.
static void t_hysteresis() {
    stream s;
    s.add(10, 0.1f);
    s.add(1, 0.9f);    // onset
    s.add(14, 0.4f);   // band windows: not silence
    s.add(15, 0.6f);   // clear speech
    s.add(10, 0.4f);   // band again
    s.add(13, 0.1f);   // real silence closes it
    const std::vector<seg_range> got = run(s);
    if (!eq(got, { {1920, 28800} })) {
        dump("t_hysteresis", got);
        CHECK(false, "expected exactly [{1920,28800}]");
    }
}

// Hard cap: a 12 s open segment is cut at the centre of the quietest 150 ms
// stretch inside its last second. The stream is 12.8 s of speech with a
// 150 ms silent dip at [180000,182400), then a closing pause.
// RED when: the cut lands at the stretch start instead of its centre
// (181200 -> 180000).
static void t_hard_cap() {
    stream s;
    s.add(400, 0.9f);  // 12.8 s of speech; cap fires when pos reaches 192000
    s.add(13, 0.1f);   // then a pause closes the continuation
    s.silence_at(180000, 182400);
    const std::vector<seg_range> got = run(s);
    if (!eq(got, { {0, 181200}, {181200, 208000} })) {
        dump("t_hard_cap", got);
        CHECK(false, "expected exactly [{0,181200},{181200,208000}]");
    }
}

// A segment continued from a cap cut keeps the whole utterance's speech count:
// the tail is part of a real utterance, not an isolated blip, so the 250 ms
// minimum must not drop it. 380 speech windows (12.16 s) force the cap at
// 12.0 s; the cut lands at 177200 with only 5 speech windows (160 ms) left in
// the continuation, then silence closes it.
// RED when: cut_at_cap resets speech_samples_ to 0 (the tail is dropped and
// only {0,177200} is emitted).
static void t_cap_tail_kept() {
    stream s;
    s.add(380, 0.9f);  // 12.16 s of speech; cap fires when pos reaches 192000
    s.add(30, 0.1f);   // silence closes the continuation
    const std::vector<seg_range> got = run(s);
    if (!eq(got, { {0, 177200}, {177200, 197760} })) {
        dump("t_cap_tail_kept", got);
        CHECK(false, "expected exactly [{0,177200},{177200,197760}]");
    }
}

// finish() closes an open segment with the end pad clamped to the samples fed.
// RED when: the end is left unclamped (emits 21120, past the last sample 20480).
static void t_finish_flush() {
    stream s;
    s.add(5, 0.1f);
    s.add(30, 0.9f);
    s.add(5, 0.1f);  // pause too short to close
    segmenter seg;
    std::vector<seg_range> got;
    seg.feed(s.p.data(), s.p.size(), s.x.data(), s.x.size(), got);
    seg.finish(got);
    if (!eq(got, { {0, 20480} })) {
        dump("t_finish_flush", got);
        CHECK(false, "expected exactly [{0,20480}]");
    }
}

// The next segment's pre-pad must not overlap the previous segment's end; at
// the minimal legal gap the new start sits exactly at the old end + the pad
// reach. RED when: post-pad 200 ms -> 600 ms (seg1 end runs into the next
// onset's pre-pad and the ranges overlap).
static void t_pre_pad_no_overlap() {
    stream s;
    s.add(20, 0.9f);   // speech 0..10239
    s.add(13, 0.1f);   // closes at window 32: end = 13440
    s.add(20, 0.9f);   // onset at 16896 -> start max(13696, 13440) = 13696
    s.add(13, 0.1f);   // closes: end = 27136+3200 = 30336
    const std::vector<seg_range> got = run(s);
    if (!eq(got, { {0, 13440}, {13696, 30336} })) {
        dump("t_pre_pad_no_overlap", got);
        CHECK(false, "expected exactly [{0,13440},{13696,30336}]");
    }
    CHECK(got.size() == 2 && got[1].s >= got[0].e, "pre-pad overlaps previous segment end");
}

// Feeding the same stream in different chunk sizes must produce identical
// output; this stream also carries a dropped blip between two kept segments.
// RED when: feed() processes only the first window of a multi-window call.
static void t_chunk_invariant() {
    stream s;
    s.add(10, 0.1f);
    s.add(25, 0.9f);   // utterance 1
    s.add(13, 0.1f);   // closes: {1920,21120}
    s.add(6, 0.9f);    // 192 ms blip
    s.add(13, 0.1f);   // closes: dropped
    s.add(20, 0.9f);   // utterance 2
    s.add(13, 0.1f);   // closes: {31104,47744}
    const std::vector<seg_range> one = run(s);
    const std::vector<seg_range> per = run(s, 1);
    const std::vector<seg_range> sev = run(s, 7);
    const std::vector<seg_range> big = run(s, 37);
    if (!eq(one, { {1920, 21120}, {31104, 47744} })) {
        dump("t_chunk_invariant one", one);
        CHECK(false, "whole-stream result wrong");
    }
    CHECK(per == one && sev == one && big == one, "output differs across chunk sizes");
}

int main() {
    t_one_utterance();
    t_short_pause_no_split();
    t_blip_dropped();
    t_hysteresis();
    t_hard_cap();
    t_cap_tail_kept();
    t_finish_flush();
    t_pre_pad_no_overlap();
    t_chunk_invariant();
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
