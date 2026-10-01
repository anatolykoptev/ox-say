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

// A cap that fires in the silence right after an utterance must not emit an
// empty or inverted continuation. Speech ends at 186368 (364 windows); the
// cap fires at 192000 before the 400 ms pause can close the segment, and the
// quietest stretch (true zeros from 189600) puts the cut at 190800, past the
// speech end + 200 ms pad (189568).
// RED when: close() drops its end > start check (emits [190800,189568)).
static void t_cap_after_speech_no_inversion() {
    stream s;
    s.add(364, 0.9f);           // 11.65 s of speech
    s.add(37, 0.05f, 0.001f);   // faint noise, then zeros below
    s.silence_at(189600, s.x.size());
    const std::vector<seg_range> got = run(s);
    bool ok = !got.empty();
    for (const seg_range & r : got) {
        ok = ok && r.e > r.s;
    }
    if (!ok || !eq(got, { {0, 190800} })) {
        dump("t_cap_after_speech_no_inversion", got);
        CHECK(false, "expected exactly [{0,190800}] and no empty or inverted range");
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

// The same utterance as t_one_utterance reports why it closed: a 400 ms
// silence is a pause cut, and the quiet run it saw is at least close_ms.
// RED when: the pause path stops stamping cut (cut stays the zero value).
static void t_cut_pause() {
    stream s;
    s.add(20, 0.1f);
    s.add(30, 0.9f);
    s.add(30, 0.1f);
    const std::vector<seg_range> got = run(s);
    if (!eq(got, { {7040, 28800} })) {
        dump("t_cut_pause", got);
        CHECK(false, "expected exactly [{7040,28800}]");
    }
    CHECK(got[0].cut == oxstt::seg_cut::pause, "cut != pause on a silence-closed segment");
    CHECK(got[0].quiet_ms >= 400, "quiet_ms < close_ms on a pause cut");
    CHECK(got[0].min_p == 0.1f, "min_p != the silence floor");
}

// A 13.4 s utterance whose pauses dip to p=0.2 for only 320 ms each is cut by
// the cap, never by a pause; quiet_ms shows how close the dips came.
// RED when: the cap path stamps cut=pause, or quiet_ms stops accumulating
// (0 instead of the 320 ms dip).
static void t_cut_cap() {
    stream s;
    s.add(100, 0.9f);
    s.add(10, 0.2f);   // 320 ms dip: quiet but too short to close
    s.add(100, 0.9f);
    s.add(10, 0.2f);
    s.add(200, 0.6f);  // post-cap windows never dip below the piece's 0.3 floor
    s.add(13, 0.3f);   // the pause closes the post-cap continuation
    const std::vector<seg_range> got = run(s);
    if (!eq(got, { {0, 177200}, {177200, 218240} })) {
        dump("t_cut_cap", got);
        CHECK(false, "expected exactly [{0,177200},{177200,218240}]");
    }
    CHECK(got[0].cut == oxstt::seg_cut::cap, "first piece cut != cap");
    CHECK(got[0].quiet_ms == 320, "cap piece quiet_ms != the 320 ms dip");
    CHECK(got[0].min_p == 0.2f, "cap piece min_p != the dip's 0.2");
    CHECK(got[1].cut == oxstt::seg_cut::pause, "continuation cut != pause");
    // 0.3 not 0.2: the continuation's counters start fresh at the cap.
    CHECK(got[1].min_p == 0.3f, "continuation min_p inherited the pre-cap dip");
    CHECK(got[1].quiet_ms == 416, "continuation quiet_ms != its closing run");
}

// An utterance still open when the stream ends is closed by finish().
// RED when: finish() routes through the pause cut.
static void t_cut_finish() {
    stream s;
    s.add(5, 0.1f);
    s.add(30, 0.9f);
    s.add(5, 0.1f);  // 160 ms: too short to close on its own
    segmenter seg;
    std::vector<seg_range> got;
    seg.feed(s.p.data(), s.p.size(), s.x.data(), s.x.size(), got);
    seg.finish(got);
    if (!eq(got, { {0, 20480} })) {
        dump("t_cut_finish", got);
        CHECK(false, "expected exactly [{0,20480}]");
    }
    CHECK(got[0].cut == oxstt::seg_cut::finish, "cut != finish");
    CHECK(got[0].quiet_ms == 160, "quiet_ms != the 160 ms trailing dip");
}

// min_p is the lowest p of any window while the segment was open — here the
// 0.15 mid-utterance dip, below the 0.3 closing-silence floor. The 0.05
// leading noise is outside the segment and must not count.
// RED when: min_p is taken over every fed window (0.05 wins) or never updated
// (stays 1.0).
static void t_min_p() {
    stream s;
    s.add(10, 0.05f);
    s.add(15, 0.9f);
    s.add(4, 0.15f);   // 128 ms dip, the lowest p while open
    s.add(15, 0.9f);
    s.add(13, 0.3f);   // closing silence above the dip
    const std::vector<seg_range> got = run(s);
    if (!eq(got, { {1920, 25728} })) {
        dump("t_min_p", got);
        CHECK(false, "expected exactly [{1920,25728}]");
    }
    CHECK(got[0].min_p == 0.15f, "min_p != the lowest p fed while open");
    CHECK(got[0].cut == oxstt::seg_cut::pause, "cut != pause");
    CHECK(got[0].quiet_ms == 416, "quiet_ms != the closing 416 ms run");
}

// A second, independent segment must not inherit the first segment's
// counters: the onset reset makes each emitted range describe only the
// windows while it was open. min_p carries the check — quiet_ms cannot:
// a quiet run beyond close_ms closes the segment, so the closing run is
// always the longest a pause-closed segment can report.
// RED when: min_p_ is not reset at onset — seg 2 would report seg 1's 0.1.
static void t_diag_reset_between_segments() {
    stream s;
    s.add(10, 0.05f);
    s.add(20, 0.9f);
    s.add(2, 0.1f);    // seg 1's dip: 64 ms quiet, min_p 0.1
    s.add(20, 0.9f);
    s.add(14, 0.3f);   // closes seg 1 on the 13th window: quiet_ms 416
    s.add(20, 0.9f);   // seg 2: onset resets both counters
    s.add(13, 0.3f);   // closes seg 2
    const std::vector<seg_range> got = run(s);
    if (!eq(got, { {1920, 29824}, {30592, 47232} })) {
        dump("t_diag_reset_between_segments", got);
        CHECK(false, "expected exactly [{1920,29824},{30592,47232}]");
    }
    CHECK(got[0].min_p == 0.1f && got[0].quiet_ms == 416, "seg 1 diagnostics wrong");
    CHECK(got[1].min_p == 0.3f, "seg 2 min_p inherited seg 1's 0.1 dip");
    CHECK(got[1].quiet_ms == 416, "seg 2 quiet_ms != its closing run");
}

int main() {
    t_one_utterance();
    t_short_pause_no_split();
    t_blip_dropped();
    t_hysteresis();
    t_hard_cap();
    t_cap_tail_kept();
    t_cap_after_speech_no_inversion();
    t_finish_flush();
    t_pre_pad_no_overlap();
    t_chunk_invariant();
    t_cut_pause();
    t_cut_cap();
    t_cut_finish();
    t_min_p();
    t_diag_reset_between_segments();
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
