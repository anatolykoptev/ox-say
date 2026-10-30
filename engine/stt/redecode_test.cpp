// Tests for redecode.h (issue #88): the finish re-decode decision and the
// answer-text fallback. Plain asserts, no framework — every check prints what
// failed and exits 1. Each test names the mutation that turns it RED.
#include "redecode.h"

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

// should_redecode(): the session had a cut (more than one decoded segment),
// its audio fits the bound, and the feature is on.
// RED if: the segment gate drops below 2 (single-segment sessions would
// pay the re-decode for nothing), the length gate turns strict (<), or the
// max_s <= 0 disable is lost.
static void t_should_redecode() {
    CHECK(oxstt::should_redecode(2, 10.0, 15.0), "a cut session inside the bound re-decodes");
    CHECK(oxstt::should_redecode(3, 15.0, 15.0), "exactly max_s still re-decodes");
    CHECK(!oxstt::should_redecode(1, 10.0, 15.0), "a single segment has no join to lose");
    CHECK(!oxstt::should_redecode(0, 10.0, 15.0), "an empty session does not re-decode");
    CHECK(!oxstt::should_redecode(2, 15.001, 15.0), "past the bound is out");
    CHECK(!oxstt::should_redecode(2, 10.0, 0.0), "0 disables");
    CHECK(!oxstt::should_redecode(2, 10.0, -1.0), "a negative bound disables");
    // Only the max_s > 0.0 clause decides these: an empty recording fits any
    // bound, so losing the "0 disables" rule would let them through.
    CHECK(!oxstt::should_redecode(2, 0.0, 0.0), "0 disables even an empty recording");
    CHECK(!oxstt::should_redecode(2, 0.0, -1.0), "a negative bound disables even an empty recording");
}

// final_text(): the re-decoded text answers only when the re-decode ran and
// produced text; anything else keeps the streamed join — a failed or empty
// re-decode must never lose the words the stream already decoded.
// RED if: the re-decoded text is returned unconditionally (an empty
// re-decode would erase a non-empty streamed text — the F2 mutant), or the
// streamed join is returned unconditionally (the re-decode's answer would
// never be used — the F1 mutant's unit-level twin).
static void t_final_text_fallback() {
    const std::string re = "the whole thing";
    const std::string str = "streamed in pieces";
    CHECK(oxstt::final_text(true, re, str) == re, "a good re-decode answers its text");
    CHECK(oxstt::final_text(true, "", str) == str, "an empty re-decode must not erase the streamed text");
    CHECK(oxstt::final_text(false, re, str) == str, "a failed re-decode must not ship its text");
    CHECK(oxstt::final_text(false, "", str) == str, "failure and empty still answers streamed");
    CHECK(oxstt::final_text(true, "", "").empty(), "both empty stays empty");
}

// append_or_drop(): the session's whole-recording copy grows while it fits
// cap = (max_s + 1 s) * sr, and is freed for good (sticky) the first time an
// append would pass it, including one 30 s-sized chunk that alone overflows.
// RED if: the cap loses its + 1 s, the comparison turns strict (<), the drop
// is not sticky (a later small chunk would refill a buffer with a hole in
// it), the drop keeps the old samples, or max_s <= 0 stops being a no-op.
static void t_append_or_drop() {
    const int sr = 10;  // 10 samples/s keeps the numbers readable; cap for max_s=2 is 30
    std::vector<float> buf;
    bool dropped = false;
    const std::vector<float> ten(10, 1.0f);
    oxstt::append_or_drop(buf, dropped, ten, 2.0, sr);
    CHECK(!dropped && buf.size() == 10, "a fitting chunk is kept");
    oxstt::append_or_drop(buf, dropped, ten, 2.0, sr);
    oxstt::append_or_drop(buf, dropped, ten, 2.0, sr);
    CHECK(!dropped && buf.size() == 30, "exactly the cap (max + 1 s) still fits");
    oxstt::append_or_drop(buf, dropped, std::vector<float>(1, 1.0f), 2.0, sr);
    CHECK(dropped && buf.empty() && buf.capacity() == 0, "one sample past the cap frees the buffer");
    oxstt::append_or_drop(buf, dropped, std::vector<float>(1, 1.0f), 2.0, sr);
    CHECK(dropped && buf.empty(), "the drop is sticky: a later small chunk is not appended");

    // One chunk on its own bigger than the cap (a 30 s chunk against a 15 s bound).
    std::vector<float> big;
    bool big_dropped = false;
    oxstt::append_or_drop(big, big_dropped, std::vector<float>(31, 1.0f), 2.0, sr);
    CHECK(big_dropped && big.empty(), "a single chunk over the cap drops at once");

    // Feature off: nothing is kept, nothing is flagged.
    std::vector<float> off;
    bool off_dropped = false;
    oxstt::append_or_drop(off, off_dropped, ten, 0.0, sr);
    CHECK(!off_dropped && off.empty(), "max_s <= 0 keeps nothing and drops nothing");
}

// redecode_buffer_complete(): the copy may be decoded only if it holds every
// sample the session received (audio_base + audio.size()); a buffer with a
// hole, or a stale longer one, must not be re-decoded.
// RED if: the size equality is dropped (always true), or loosened to >= / <=.
static void t_redecode_buffer_complete() {
    CHECK(oxstt::redecode_buffer_complete(160, 160), "equal sizes are complete");
    CHECK(!oxstt::redecode_buffer_complete(159, 160), "a short copy has a hole");
    CHECK(!oxstt::redecode_buffer_complete(161, 160), "a longer copy is not the recording");
    CHECK(!oxstt::redecode_buffer_complete(0, 160), "an empty copy of a non-empty session");
}

int main() {
    t_should_redecode();
    t_final_text_fallback();
    t_append_or_drop();
    t_redecode_buffer_complete();
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
