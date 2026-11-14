// Tests for boost.h: the phrase trie, fail links, score tables, canonical BPE, run state and the term
// parser, on toy vocabularies with hand-computed expectations. Plain asserts, no framework — every
// failing check prints its test name and message and the exit status is 1.
#include "boost.h"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace oxstt::boost;

static int failures = 0;
static const char * cur = "";

#define CHECK(cond, msg)                                                                          \
    do {                                                                                          \
        if (!(cond)) {                                                                            \
            fprintf(stderr, "FAIL [%s] %s:%d: %s\n", cur, __FILE__, __LINE__, msg);               \
            ++failures;                                                                           \
        }                                                                                         \
    } while (0)

static bool near(float a, float b) { return std::fabs(a - b) < 1e-4f; }

static vocab_view view_of(const std::vector<std::string> & pieces) {
    vocab_view v;
    v.n_vocab = (int) pieces.size();
    v.piece = [&pieces](int i) -> const char * { return pieces[(size_t) i].c_str(); };
    return v;
}

// Toy vocabulary: every letter is a piece, every "▁letter" is a piece, so a one-letter word is one token.
//   0 <unk>  1 ▁  2 a  3 b  4 c  5 d  6 x  7 y  8 ▁a  9 ▁b  10 ▁c  11 ▁d  12 ▁x  13 ▁y
static const std::vector<std::string> kToy = { "<unk>", "\xE2\x96\x81", "a", "b", "c", "d", "x", "y",
                                               "\xE2\x96\x81" "a", "\xE2\x96\x81" "b", "\xE2\x96\x81" "c",
                                               "\xE2\x96\x81" "d", "\xE2\x96\x81" "x", "\xE2\x96\x81" "y" };
enum { A = 8, B = 9, C = 10, D = 11, X = 12, Y = 13 };

// Terms "a b x" and "b y" (weight 1, context_score 1, depth_scaling 2). Arc score at depth d>=1 is
// 1*2 + ln(d+1): depth 1 = 2 + ln 2 = 2.693147, depth 2 = 2 + ln 3 = 3.098612.
//   root -A-> n1 (arc 1)            n1 -B-> n2 (arc 2.693147)      n2 -X-> n3 (arc 3.098612, end)
//   root -B-> n4 (arc 1)            n4 -Y-> n5 (arc 2.693147, end)
// node_score: n1 1, n2 3.693147, n3 6.791759, n4 1, n5 3.693147.
// fail: n1 root, n4 root, n2 -> n4 (root has B), n3 root (n4 has no X), n5 root.
// backoff = fail.node_score - node_score, 0 at an end: n1 -1, n4 -1, n2 1-3.693147 = -2.693147, n3 0, n5 0.
struct toy_graph {
    std::shared_ptr<const graph> g;
    int n1, n2, n3, n4, n5;
    toy_graph() {
        const vocab_view v = view_of(kToy);
        g = graph::build({ { "a b x", 1.0f }, { "b y", 1.0f } }, v, params{});
        n1 = g->child(0, A);
        n2 = g->child(n1, B);
        n3 = g->child(n2, X);
        n4 = g->child(0, B);
        n5 = g->child(n4, Y);
    }
};

// Capitalised and lower-case variants of "a b x" use capital letters the toy vocabulary cannot spell, and
// are skipped; as-given alone remains. RED if skipped variants abort the build.
static void t_graph_shape() {
    cur = "t_graph_shape";
    toy_graph t;
    CHECK(t.g->n_nodes() == 6, "root + 3 + 2 nodes");
    CHECK(t.n1 > 0 && t.n2 > 0 && t.n3 > 0 && t.n4 > 0 && t.n5 > 0, "all arcs exist");
    CHECK(t.g->is_end(t.n3) && t.g->is_end(t.n5), "phrase ends");
    CHECK(!t.g->is_end(t.n2) && !t.g->is_end(t.n1), "interior nodes are not ends");
}

// Arc and node scores: the depth scaling. RED if depth_scaling is dropped (arcs would be 1, 1, 1 and the
// node scores 1, 2, 3).
static void t_score_tables() {
    cur = "t_score_tables";
    toy_graph t;
    CHECK(near(t.g->arc_score(t.n1), 1.0f), "depth 0 arc = context_score");
    CHECK(near(t.g->arc_score(t.n2), 2.693147f), "depth 1 arc = 2 + ln 2");
    CHECK(near(t.g->arc_score(t.n3), 3.098612f), "depth 2 arc = 2 + ln 3");
    CHECK(near(t.g->node_score(t.n1), 1.0f), "node score n1");
    CHECK(near(t.g->node_score(t.n2), 3.693147f), "node score n2 = 1 + 2.693147");
    CHECK(near(t.g->node_score(t.n3), 6.791759f), "node score n3 = 3.693147 + 3.098612");
    CHECK(near(t.g->node_score(t.n5), 3.693147f), "node score n5");
}

// Fail links and backoffs, as derived in the table above.
static void t_fail_links() {
    cur = "t_fail_links";
    toy_graph t;
    CHECK(t.g->fail(t.n1) == 0 && t.g->fail(t.n4) == 0, "depth-1 nodes fail to root");
    CHECK(t.g->fail(t.n2) == t.n4, "'a b' falls back to 'b'");
    CHECK(t.g->fail(t.n3) == 0, "'a b x' falls back to root");
    CHECK(t.g->fail(t.n5) == 0, "'b y' falls back to root");
    CHECK(near(t.g->backoff(t.n1), -1.0f), "backoff n1");
    CHECK(near(t.g->backoff(t.n2), -2.693147f), "backoff n2 = 1 - 3.693147");
    CHECK(t.g->backoff(t.n3) == 0.0f && t.g->backoff(t.n5) == 0.0f, "no backoff at a phrase end");
}

// step(): the overlapping-prefix case. At 'a b' there is no arc for Y, but its fail state 'b' has one:
// the match continues as 'b y'. RED if the fail-link fallback returns root instead of following it.
static void t_step_follows_fail() {
    cur = "t_step_follows_fail";
    toy_graph t;
    CHECK(t.g->step(0, A) == t.n1, "root -A-> n1");
    CHECK(t.g->step(t.n1, B) == t.n2, "n1 -B-> n2");
    CHECK(t.g->step(t.n2, X) == t.n3, "n2 -X-> n3");
    CHECK(t.g->step(t.n2, Y) == t.n5, "'a b' then y is the tail of 'b y' via the fail link");
    CHECK(t.g->step(t.n3, B) == t.n4, "after a finished phrase, b starts a new match");
    CHECK(t.g->step(t.n2, D) == 0, "a token nothing continues drops to root");
    CHECK(t.g->step(0, D) == 0, "root stays root");
}

// bias() tables, hand-computed. delta[y] = acc_before + arc - acc_total.
//  root:  A 1, B 1.
//  n1:    chain n1 (acc_total -1): B arc 2.693147 -> 0 + 2.693147 + 1 = 3.693147; then root with acc -1:
//         A -> -1 + 1 + 1 = 1 (B already set).
//  n2:    acc_total -3.693147: X -> 3.098612 + 3.693147 = 6.791759; then n4 with acc -2.693147: Y ->
//         -2.693147 + 2.693147 + 3.693147 = 3.693147; then root with acc -3.693147: A -> 1, B -> 1.
//  n3:    a finished phrase, acc_total 0: only the root arcs, A 1, B 1.
static void t_bias_tables() {
    cur = "t_bias_tables";
    toy_graph t;
    std::vector<float> b(14, 0.0f);
    t.g->bias(0, b.data(), 14);
    CHECK(near(b[A], 1.0f) && near(b[B], 1.0f), "root: entering costs context_score");
    CHECK(b[X] == 0.0f && b[Y] == 0.0f && b[D] == 0.0f, "root: tokens that start no phrase stay 0");

    b.assign(14, 0.0f);
    t.g->bias(t.n1, b.data(), 14);
    CHECK(near(b[B], 3.693147f), "n1: second piece = 2.693147 + 1");
    CHECK(near(b[A], 1.0f), "n1: restarting a phrase = context_score");
    CHECK(b[X] == 0.0f && b[Y] == 0.0f, "n1: unrelated tokens 0");

    b.assign(14, 0.0f);
    t.g->bias(t.n2, b.data(), 14);
    CHECK(near(b[X], 6.791759f), "n2: third piece carries the accumulated score");
    CHECK(near(b[Y], 3.693147f), "n2: the fail-chain continuation 'b y' scores as if 'b' was just emitted");
    CHECK(near(b[A], 1.0f) && near(b[B], 1.0f), "n2: root arcs");

    b.assign(14, 0.0f);
    t.g->bias(t.n3, b.data(), 14);
    CHECK(near(b[A], 1.0f) && near(b[B], 1.0f) && b[X] == 0.0f, "n3: a finished phrase leaves only fresh starts");
}

// per-term weight scales the arcs; shared nodes keep the maximum.
static void t_weight_and_shared_max() {
    cur = "t_weight_and_shared_max";
    const vocab_view v = view_of(kToy);
    // "a b" weight 2 and "a c" weight 1 share n1; its arc is max(2*1, 1*1) = 2. "a b" depth 1: 2*2.693147.
    auto g = graph::build({ { "a b", 2.0f }, { "a c", 1.0f } }, v, params{});
    const int n1 = g->child(0, A);
    CHECK(near(g->arc_score(n1), 2.0f), "shared node keeps the max weight");
    CHECK(near(g->arc_score(g->child(n1, B)), 5.386294f), "weight 2 doubles the depth-1 arc");
    CHECK(near(g->arc_score(g->child(n1, C)), 2.693147f), "weight 1 arc");
}

// run: reset / on_token / fill with alpha, and the changed flag.
static void t_run() {
    cur = "t_run";
    toy_graph t;
    run r(t.g, 2.0f);
    r.reset();
    std::vector<float> logits(14, 0.0f), b(14, 0.0f);
    logits[D] = 5.0f;  // raw argmax is D
    r.fill(logits.data(), b.data(), 14);
    CHECK(near(b[A], 2.0f), "alpha multiplies the root arc (1 * 2)");
    r.on_token(A);  // the bias picked A over the raw D
    CHECK(r.changed().size() == 1 && r.changed()[0], "a token other than the raw argmax is flagged");
    CHECK(r.state() == t.n1, "state advanced to n1");
    b.assign(14, 0.0f);
    logits.assign(14, 0.0f);
    logits[B] = 1.0f;
    r.fill(logits.data(), b.data(), 14);
    CHECK(near(b[B], 2.0f * 3.693147f), "n1: alpha * 3.693147");
    r.on_token(B);  // the raw argmax itself
    CHECK(!r.changed()[1], "the raw argmax is not flagged");
    r.reset();
    CHECK(r.state() == 0 && r.ids().empty() && r.changed().empty(), "reset clears state and records");
}

// canonical_bpe: merge by lowest piece id.
//   ids: 0 <unk> 1 ▁ 2 o 3 x 4 S 5 a 6 y | 7 ▁o 8 ox 9 Sa 10 ay 11 ▁ox 12 Say
// "oxSay" -> [▁ o x S a y]. Candidates: ▁o 7, ox 8, Sa 9, ay 10: lowest ▁o -> [▁o x S a y]. Candidates:
// ▁ox 11, Sa 9, ay 10: Sa -> [▁o x Sa y]. Candidates: ▁ox 11, Say 12: ▁ox -> [▁ox Sa y]. Candidates:
// Say 12 -> [▁ox Say] = {11, 12}.
static void t_canonical_bpe() {
    cur = "t_canonical_bpe";
    const std::string sp = "\xE2\x96\x81";
    std::vector<std::string> p = { "<unk>", sp, "o", "x", "S", "a", "y", sp + "o", "ox", "Sa", "ay", sp + "ox", "Say" };
    CHECK(canonical_bpe(view_of(p), "oxSay") == std::vector<int>({ 11, 12 }), "merge order of the toy vocabulary");

    // The id order, not the longest match, decides: "abc" with ab < bc is [ab c]; with bc < ab, [a bc].
    //   ids: 0 <unk> 1 ▁ 2 a 3 b 4 c, then ab 5 / bc 6 or bc 5 / ab 6.
    std::vector<std::string> r1 = { "<unk>", sp, "a", "b", "c", "ab", "bc" };
    std::vector<std::string> r2 = { "<unk>", sp, "a", "b", "c", "bc", "ab" };
    CHECK(canonical_bpe(view_of(r1), "abc") == std::vector<int>({ 1, 5, 4 }), "ab (id 5) merges first: [▁ ab c]");
    CHECK(canonical_bpe(view_of(r2), "abc") == std::vector<int>({ 1, 2, 5 }), "bc (id 5) merges first: [▁ a bc]");

    CHECK(canonical_bpe(view_of(p), "oxQ").empty(), "a character with no piece cannot be written");
    CHECK(canonical_bpe(view_of(p), "").empty(), "an empty word has no segmentation");
}

// case_variants: an upper-case letter beyond the first -> as given only.
static void t_case_variants() {
    cur = "t_case_variants";
    CHECK(case_variants("github") == std::vector<std::string>({ "github", "Github" }), "lower-case term: as given + capitalised");
    CHECK(case_variants("Devin") == std::vector<std::string>({ "Devin", "devin" }), "capitalised term: as given + lower");
    CHECK(case_variants("GitHub") == std::vector<std::string>({ "GitHub" }), "CamelCase: as given only");
    CHECK(case_variants("OxSay") == std::vector<std::string>({ "OxSay" }), "CamelCase: as given only");
    CHECK(case_variants("Hugging Face") == std::vector<std::string>({ "Hugging Face" }), "capital in a later word: as given only");
    CHECK(case_variants("\xD0\xB4\xD0\xBE\xD0\xBC") ==
              std::vector<std::string>({ "\xD0\xB4\xD0\xBE\xD0\xBC", "\xD0\x94\xD0\xBE\xD0\xBC" }),
          "Cyrillic: capitalised variant");
}

// parse_terms: trims, one term per line, weight after a tab, dedup, min 3 code points, cap 200.
// RED if the min-length check is removed ("ab" and the 2-letter Cyrillic term would be kept).
static void t_parse_terms() {
    cur = "t_parse_terms";
    std::string err;
    auto t = parse_terms("  OxSay \nHormozi\t2.5\r\nab\n\xD0\xB4\xD0\xBE\nabc\n\n# note\nOxSay\n\xD0\xB4\xD0\xBE\xD0\xBC\n", err);
    CHECK(t.size() == 4, "OxSay, Hormozi, abc, дом kept");
    if (t.size() == 4) {
        CHECK(t[0].text == "OxSay" && t[0].weight == 1.0f, "trimmed, default weight 1");
        CHECK(t[1].text == "Hormozi" && near(t[1].weight, 2.5f), "CRLF stripped, tab weight parsed");
        CHECK(t[2].text == "abc", "3 ASCII characters are enough");
        CHECK(t[3].text == "\xD0\xB4\xD0\xBE\xD0\xBC", "3 Cyrillic characters (6 bytes) are enough");
    }
    CHECK(err.find("shorter than 3") != std::string::npos, "short terms are reported");

    t = parse_terms("ab\n\xD0\xB4\xD0\xBE\n", err);
    CHECK(t.empty(), "a 2-character ASCII term and a 2-character Cyrillic term (4 bytes) are dropped");

    t = parse_terms("good\tnope\nfine\t-1\nok3\t0\nwell\t2\nnan1\tnan\n", err);
    CHECK(t.size() == 1 && t[0].text == "well", "a bad, non-positive or non-finite weight drops the line");

    std::string big;
    for (int i = 0; i < 250; ++i) big += "term" + std::to_string(i) + "\n";
    t = parse_terms(big, err);
    CHECK(t.size() == 200, "capped at 200");
    CHECK(err.find("200") != std::string::npos, "the cap is reported");

    t = parse_terms("", err);
    CHECK(t.empty() && err.empty(), "empty input, no error");
}

// build() end to end on the toy vocabulary: skipped variants are reported, the rest still build.
static void t_build_skips() {
    cur = "t_build_skips";
    const vocab_view v = view_of(kToy);
    std::vector<std::string> skipped;
    auto g = graph::build({ { "a b x", 1.0f }, { "q", 1.0f } }, v, params{}, &skipped);
    CHECK(g->n_nodes() == 4, "root + the 3 nodes of 'a b x'; 'q' has no piece");
    bool saw_q = false;
    for (const std::string & s : skipped) saw_q = saw_q || s == "q";
    CHECK(saw_q, "the unspellable term is reported");
    auto empty = graph::build({}, v, params{});
    std::vector<float> b(14, 0.0f);
    empty->bias(0, b.data(), 14);
    float sum = 0;
    for (float f : b) sum += f;
    CHECK(sum == 0.0f && empty->step(0, A) == 0, "an empty graph biases nothing");
}

int main() {
    t_graph_shape();
    t_score_tables();
    t_fail_links();
    t_step_follows_fail();
    t_bias_tables();
    t_weight_and_shared_max();
    t_run();
    t_canonical_bpe();
    t_case_variants();
    t_parse_terms();
    t_build_skips();
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
