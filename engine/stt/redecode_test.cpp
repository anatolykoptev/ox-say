// Tests for redecode.h (issue #88): the finish re-decode decision and the
// answer-text fallback. Plain asserts, no framework — every check prints what
// failed and exits 1. Each test names the mutation that turns it RED.
#include "redecode.h"

#include <cstdio>
#include <string>

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

int main() {
    t_should_redecode();
    t_final_text_fallback();
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
