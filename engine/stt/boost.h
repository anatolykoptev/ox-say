// Decoder-side term boosting for Parakeet TDT greedy decoding. Pure C++17, no whisper/ggml deps, so CI
// compiles its test directly (boost_test.cpp).
//
// The method is NeMo's GPU-PB (Apache-2.0; weights published in "TurboBias", arXiv 2508.07014): the
// terms form a phrase trie over the model's BPE pieces with Aho-Corasick fail links; every arc carries
// a depth-scaled score, and at each step a token that continues (or restarts) a partial match gets the
// accumulated score relative to a token that matches nothing. ox-stt adds it to the joint logits
// through the token-bias hook of engine/patches/whisper/0001-parakeet-token-bias-hook.patch, which
// only re-ranks among non-blank tokens: it can swap a word for a listed term, never create one in
// silence, and it never touches the duration head or the reported probability.
//
//   canonical_bpe  one segmentation of a word by the vocabulary's own merge order
//   graph          immutable trie + fail links + scores
//   run            per-decode state (reset / on_token / fill)
//   parse_terms    stdin text -> terms
#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace oxstt::boost {

// Upper bounds, applied in double before any float cast: strtod accepts 1e100, which is finite as a double
// and infinite as a float, and an infinite bias would corrupt every decode step it reaches.
inline constexpr double kMaxAlpha = 100.0;
inline constexpr double kMaxWeight = 100.0;

struct params {
    float alpha = 1.0f;          // decode-time weight (NeMo boosting_tree_alpha)
    float context_score = 1.0f;  // arc score at depth 0
    float depth_scaling = 2.0f;  // arcs after the first: context_score * depth_scaling + ln(depth + 1)
};

struct term {
    std::string text;                 // the written form: what the user wants in the output
    float weight = 1.0f;              // multiplies the phrase's arcs (NeMo's per-phrase alpha)
    bool spoken_only = false;         // the written form is an ordinary word: boost only the spoken forms
    std::vector<std::string> spoken;  // spellings the model writes when the term is SPOKEN (e.g. Cyrillic
                                      // for a Latin name in Russian speech); boosted like the written form
                                      // and mapped back to `text` by map_spoken() after the decode
    term() = default;
    term(std::string t, float w = 1.0f, std::vector<std::string> sp = {})
        : text(std::move(t)), weight(w), spoken(std::move(sp)) {}
};

// The vocabulary as the decoder exposes it: piece(i) is the text of token i (SentencePiece spelling,
// "▁" for a word start), or null.
struct vocab_view {
    int n_vocab = 0;
    std::function<const char *(int)> piece;
};

inline constexpr const char * kWordStart = "\xE2\x96\x81";  // U+2581 LOWER ONE EIGHTH BLOCK

namespace detail {

// UTF-8 code points of s as strings; a byte that does not start a well-formed sequence is its own unit.
inline std::vector<std::string> utf8_chars(const std::string & s) {
    std::vector<std::string> out;
    for (size_t i = 0; i < s.size();) {
        const unsigned char c = (unsigned char) s[i];
        size_t n = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3 : (c >> 3) == 0x1E ? 4 : 1;
        if (i + n > s.size()) {
            n = 1;
        }
        out.push_back(s.substr(i, n));
        i += n;
    }
    return out;
}

inline uint32_t decode_cp(const std::string & ch) {
    const unsigned char c0 = (unsigned char) ch[0];
    if (ch.size() == 1) return c0;
    if (ch.size() == 2) return ((c0 & 0x1Fu) << 6) | ((unsigned char) ch[1] & 0x3Fu);
    if (ch.size() == 3) return ((c0 & 0x0Fu) << 12) | (((unsigned char) ch[1] & 0x3Fu) << 6) | ((unsigned char) ch[2] & 0x3Fu);
    return ((c0 & 0x07u) << 18) | (((unsigned char) ch[1] & 0x3Fu) << 12) | (((unsigned char) ch[2] & 0x3Fu) << 6) |
           ((unsigned char) ch[3] & 0x3Fu);
}

inline std::string encode_cp(uint32_t cp) {
    std::string o;
    if (cp < 0x80) {
        o += (char) cp;
    } else if (cp < 0x800) {
        o += (char) (0xC0 | (cp >> 6));
        o += (char) (0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        o += (char) (0xE0 | (cp >> 12));
        o += (char) (0x80 | ((cp >> 6) & 0x3F));
        o += (char) (0x80 | (cp & 0x3F));
    } else {
        o += (char) (0xF0 | (cp >> 18));
        o += (char) (0x80 | ((cp >> 12) & 0x3F));
        o += (char) (0x80 | ((cp >> 6) & 0x3F));
        o += (char) (0x80 | (cp & 0x3F));
    }
    return o;
}

// Case mapping for ASCII and Cyrillic, the scripts the glossary holds; anything else maps to itself.
inline uint32_t to_lower_cp(uint32_t c) {
    if (c >= 'A' && c <= 'Z') return c + 32;
    if (c >= 0x410 && c <= 0x42F) return c + 32;
    if (c >= 0x400 && c <= 0x40F) return c + 80;
    return c;
}
inline uint32_t to_upper_cp(uint32_t c) {
    if (c >= 'a' && c <= 'z') return c - 32;
    if (c >= 0x430 && c <= 0x44F) return c - 32;
    if (c >= 0x450 && c <= 0x45F) return c - 80;
    return c;
}
inline bool is_upper_cp(uint32_t c) { return to_lower_cp(c) != c; }

}  // namespace detail

// Number of Unicode code points (what "3 characters" means for a Cyrillic term).
inline size_t cp_count(const std::string & s) { return detail::utf8_chars(s).size(); }

// "▁" + word segmented by the vocabulary's merge order: start from single characters and repeatedly
// merge the adjacent pair whose concatenation is a piece with the lowest id. For SentencePiece BPE the
// piece id is the merge rank, so this reproduces the training-time segmentation without the model's
// merge table. Empty when a character has no piece of its own (the word cannot be written in this
// vocabulary) or the word is empty.
// piece text -> id, the lowest id winning; built once per graph::build, not once per word
using piece_map = std::unordered_map<std::string, int>;

inline piece_map make_piece_map(const vocab_view & v) {
    piece_map id;
    if (!v.piece) return id;
    id.reserve((size_t) std::max(v.n_vocab, 0) * 2);
    for (int i = 0; i < v.n_vocab; ++i) {
        const char * p = v.piece(i);
        if (p && *p) {
            id.emplace(p, i);
        }
    }
    return id;
}

inline std::vector<int> canonical_bpe(const piece_map & id, const std::string & word) {
    if (word.empty() || id.empty()) {
        return {};
    }
    std::vector<std::string> sym = { kWordStart };
    for (const std::string & c : detail::utf8_chars(word)) {
        sym.push_back(c);
    }
    std::vector<int> ids(sym.size());
    for (size_t i = 0; i < sym.size(); ++i) {
        const auto it = id.find(sym[i]);
        if (it == id.end()) {
            return {};
        }
        ids[i] = it->second;
    }
    for (;;) {
        int best = std::numeric_limits<int>::max();
        size_t at = 0;
        for (size_t i = 0; i + 1 < sym.size(); ++i) {
            const auto it = id.find(sym[i] + sym[i + 1]);
            if (it != id.end() && it->second < best) {
                best = it->second;
                at = i;
            }
        }
        if (best == std::numeric_limits<int>::max()) {
            break;
        }
        sym[at] += sym[at + 1];
        ids[at] = best;
        sym.erase(sym.begin() + (long) at + 1);
        ids.erase(ids.begin() + (long) at + 1);
    }
    return ids;
}

inline std::vector<int> canonical_bpe(const vocab_view & v, const std::string & word) {
    return canonical_bpe(make_piece_map(v), word);
}

// Case variants of a term as written (research: the model writes cased text): a term with an upper-case
// letter beyond the first (acronyms, CamelCase, "Hugging Face") is boosted as given only; any other is
// boosted as given, capitalised-first and lower-case. Distinct strings only, as-given first.
inline std::vector<std::string> case_variants(const std::string & t) {
    std::vector<std::string> out = { t };
    const std::vector<std::string> ch = detail::utf8_chars(t);
    for (size_t i = 1; i < ch.size(); ++i) {
        if (detail::is_upper_cp(detail::decode_cp(ch[i]))) {
            return out;
        }
    }
    std::string lower, cap;
    for (size_t i = 0; i < ch.size(); ++i) {
        const uint32_t c = detail::decode_cp(ch[i]);
        lower += detail::encode_cp(detail::to_lower_cp(c));
        cap += i == 0 ? detail::encode_cp(detail::to_upper_cp(c)) : ch[i];
    }
    for (const std::string & s : { cap, lower }) {
        if (std::find(out.begin(), out.end(), s) == out.end()) {
            out.push_back(s);
        }
    }
    return out;
}

// Immutable phrase trie with Aho-Corasick fail links.
class graph {
  public:
    // Builds the graph. A term variant with a word the vocabulary cannot spell is skipped and its text
    // appended to *skipped (fail-open: one bad term never blocks the rest).
    static std::shared_ptr<const graph> build(const std::vector<term> & terms, const vocab_view & v, const params & p,
                                              std::vector<std::string> * skipped = nullptr) {
        auto g = std::make_shared<graph>();
        g->nodes_.emplace_back();  // root
        g->word_start_.assign((size_t) std::max(v.n_vocab, 0), false);
        for (int i = 0; i < v.n_vocab; ++i) {
            const char * pc = v.piece ? v.piece(i) : nullptr;
            g->word_start_[(size_t) i] = pc && std::string(pc).compare(0, 3, kWordStart) == 0;
        }
        const piece_map pieces = make_piece_map(v);
        for (const term & t : terms) {
            std::vector<std::string> forms;
            if (!t.spoken_only) forms = case_variants(t.text);
            for (const std::string & sp : t.spoken) {
                for (const std::string & cv : case_variants(sp)) {
                    if (std::find(forms.begin(), forms.end(), cv) == forms.end()) forms.push_back(cv);
                }
            }
            for (const std::string & variant : forms) {
                std::vector<int> toks;
                bool ok = true;
                size_t start = 0;
                while (ok && start <= variant.size()) {
                    size_t sp = variant.find_first_of(" \t", start);
                    if (sp == std::string::npos) sp = variant.size();
                    if (sp > start) {
                        const std::vector<int> w = canonical_bpe(pieces, variant.substr(start, sp - start));
                        ok = !w.empty();
                        toks.insert(toks.end(), w.begin(), w.end());
                    }
                    start = sp + 1;
                }
                if (!ok || toks.empty()) {
                    if (skipped) skipped->push_back(variant);
                    continue;
                }
                g->insert(toks, clamp_weight(t.weight), p);
            }
        }
        g->finish();
        return g;
    }

    int root() const { return 0; }
    // True when token starts a word ("▁..." piece). The guard in run::fill uses it.
    bool word_start(int token) const {
        return token >= 0 && (size_t) token < word_start_.size() && word_start_[(size_t) token];
    }
    size_t n_nodes() const { return nodes_.size(); }

    // Next state after emitting token: the arc of the nearest state on the fail chain that has one, else
    // the root. (A token no state on the chain continues drops the whole partial match.)
    int step(int state, int token) const {
        for (int s = state; s >= 0; s = nodes_[(size_t) s].fail) {
            const auto it = nodes_[(size_t) s].next.find(token);
            if (it != nodes_[(size_t) s].next.end()) {
                return it->second;
            }
        }
        return 0;
    }

    // NeMo's advance() relative to the unmatched baseline. Walk the fail chain from state accumulating
    // backoff = fail.node_score - node.node_score (0 at a phrase end, so a finished phrase's bonus is never
    // taken back); the first state on the chain with an arc for token y gives
    //     delta[y] = (backoff accumulated before that state) + arc score - (backoff of the whole chain),
    // i.e. how much better y scores than a token that matches nothing. Unmatched tokens stay 0. Every
    // delta is >= the arc score > 0 (the whole-chain backoff is <= 0), so a non-zero entry marks a token
    // already set by a nearer state. bias[] must arrive zeroed.
    void bias(int state, float * bias, int n_vocab) const {
        std::vector<std::pair<int, float>> e;
        bias_sparse(state, e);
        for (const auto & [tok, v] : e) {
            if (tok >= 0 && tok < n_vocab) bias[tok] = v;
        }
    }

    // The same table as (token, delta) pairs, one per token that gets a non-zero bias: a decode step
    // touches a handful of tokens, not the whole vocabulary.
    // `mark` (size n_vocab, zero-initialised, owned by the caller) makes the "already set by a nearer state"
    // test O(1); it is left zeroed again on return.
    void bias_sparse(int state, std::vector<std::pair<int, float>> & out, std::vector<unsigned char> * mark = nullptr) const {
        out.clear();
        const float total = nodes_[(size_t) state].acc_total;
        float acc = 0.0f;
        for (int s = state; s >= 0; s = nodes_[(size_t) s].fail) {
            for (const auto & kv : nodes_[(size_t) s].next) {
                const int tok = kv.first;
                bool seen;
                if (mark && tok >= 0 && (size_t) tok < mark->size()) {
                    seen = (*mark)[(size_t) tok] != 0;
                    (*mark)[(size_t) tok] = 1;
                } else {
                    seen = std::any_of(out.begin(), out.end(), [tok](const std::pair<int, float> & p) { return p.first == tok; });
                }
                if (!seen) out.emplace_back(tok, acc + nodes_[(size_t) kv.second].arc_in - total);
            }
            acc += nodes_[(size_t) s].backoff;
        }
        if (mark) {
            for (const auto & p : out) {
                if (p.first >= 0 && (size_t) p.first < mark->size()) (*mark)[(size_t) p.first] = 0;
            }
        }
    }

    // Introspection for tests.
    float node_score(int s) const { return nodes_[(size_t) s].node_score; }
    float arc_score(int s) const { return nodes_[(size_t) s].arc_in; }
    float backoff(int s) const { return nodes_[(size_t) s].backoff; }
    int fail(int s) const { return nodes_[(size_t) s].fail; }
    bool is_end(int s) const { return nodes_[(size_t) s].end; }
    int child(int s, int token) const {
        const auto it = nodes_[(size_t) s].next.find(token);
        return it == nodes_[(size_t) s].next.end() ? -1 : it->second;
    }

    graph() = default;

  private:
    struct node {
        std::map<int, int> next;  // token -> child
        float arc_in = 0.0f;      // score of the arc that enters this node (max over the phrases sharing it)
        float node_score = 0.0f;  // sum of arc_in from the root
        float backoff = 0.0f;     // fail.node_score - node_score; 0 at a phrase end
        float acc_total = 0.0f;   // backoff summed along the whole fail chain
        int fail = -1;
        int depth = 0;
        bool end = false;
    };
    std::vector<node> nodes_;
    std::vector<bool> word_start_;

    // A weight outside (0, kMaxWeight] (or NaN) can only come from a caller that skipped parse_terms; keep
    // every arc score finite regardless.
    static float clamp_weight(float w) {
        if (!(w > 0.0f)) return 1.0f;
        return w > (float) kMaxWeight ? (float) kMaxWeight : w;
    }

    static float arc_score_at(size_t depth, float weight, const params & p) {
        const float base = depth == 0 ? p.context_score
                                      : p.context_score * p.depth_scaling + std::log((float) depth + 1.0f);
        return base * weight;
    }

    void insert(const std::vector<int> & toks, float weight, const params & p) {
        int s = 0;
        for (size_t d = 0; d < toks.size(); ++d) {
            const float w = arc_score_at(d, weight, p);
            auto it = nodes_[(size_t) s].next.find(toks[d]);
            if (it == nodes_[(size_t) s].next.end()) {
                const int id = (int) nodes_.size();
                nodes_.emplace_back();
                nodes_[(size_t) id].depth = (int) d + 1;
                nodes_[(size_t) s].next[toks[d]] = id;
                it = nodes_[(size_t) s].next.find(toks[d]);
            }
            const int c = it->second;
            nodes_[(size_t) c].arc_in = std::max(nodes_[(size_t) c].arc_in, w);
            s = c;
        }
        nodes_[(size_t) s].end = true;
    }

    // BFS: fail links, node scores, backoffs.
    void finish() {
        std::vector<int> q;
        for (const auto & [tok, c] : nodes_[0].next) {
            nodes_[(size_t) c].fail = 0;
            q.push_back(c);
        }
        for (size_t qi = 0; qi < q.size(); ++qi) {
            const int u = q[qi];
            for (const auto & [tok, c] : nodes_[(size_t) u].next) {
                int f = nodes_[(size_t) u].fail;
                int target = 0;
                for (;;) {
                    const auto it = nodes_[(size_t) f].next.find(tok);
                    if (it != nodes_[(size_t) f].next.end()) {
                        target = it->second;
                        break;
                    }
                    if (f == 0) break;
                    f = nodes_[(size_t) f].fail;
                }
                nodes_[(size_t) c].fail = target;
                q.push_back(c);
            }
        }
        // parents before children (BFS order); fail has smaller depth, so it is final first
        std::vector<int> order = { 0 };
        order.insert(order.end(), q.begin(), q.end());
        std::vector<int> parent(nodes_.size(), -1);
        for (size_t i = 0; i < nodes_.size(); ++i) {
            for (const auto & [tok, c] : nodes_[i].next) parent[(size_t) c] = (int) i;
        }
        for (const int u : order) {
            if (u == 0) continue;
            nodes_[(size_t) u].node_score = nodes_[(size_t) parent[(size_t) u]].node_score + nodes_[(size_t) u].arc_in;
        }
        for (const int u : order) {
            if (u == 0) continue;
            node & n = nodes_[(size_t) u];
            n.backoff = n.end ? 0.0f : nodes_[(size_t) n.fail].node_score - n.node_score;
            n.acc_total = n.backoff + nodes_[(size_t) n.fail].acc_total;
        }
    }
};

// Per-decode state: one per parakeet_full call, driven by the three callbacks.
class run {
  public:
    explicit run(std::shared_ptr<const graph> g, float alpha = 1.0f)
        : g_(std::move(g)), alpha_(std::isfinite(alpha) && alpha > 0.0f ? std::min(alpha, (float) kMaxAlpha) : 0.0f) {}

    void reset() {  // encoder_begin_callback
        state_ = g_->root();
        raw_best_ = -1;
        changed_.clear();
        ids_.clear();
    }

    void on_token(int token) {  // new_token_callback
        ids_.push_back(token);
        changed_.push_back(raw_best_ >= 0 && raw_best_ != token);
        raw_best_ = -1;
        state_ = g_->step(state_, token);
    }

    // token_bias_callback: logits = the raw joint logits, bias[n_vocab] arrives zeroed. Also remembers the
    // unbiased argmax, so on_token can tell whether the bias changed the token.
    //
    // Word-boundary guard: when the raw argmax starts a new word, a bias never selects a token that
    // continues the previous word. Without it a partial match swallows the space ("до" + "за..." ->
    // "дозор...") and an alias completes inside a longer word; with it an alias can only replace a token
    // of the same kind (word start for word start, continuation for continuation).
    void fill(const float * logits, float * bias, int n_vocab) {
        int best = 0;
        for (int i = 1; i < n_vocab; ++i) {
            if (logits[i] > logits[best]) best = i;
        }
        raw_best_ = n_vocab > 0 ? best : -1;
        if (mark_.size() != (size_t) n_vocab) mark_.assign((size_t) n_vocab, 0);
        g_->bias_sparse(state_, scratch_, &mark_);
        const bool raw_starts_word = n_vocab > 0 && g_->word_start(best);
        for (const auto & [tok, v] : scratch_) {
            if (tok < 0 || tok >= n_vocab) continue;
            bias[tok] = (raw_starts_word && !g_->word_start(tok)) ? 0.0f : v * alpha_;
        }
    }

    int state() const { return state_; }
    // One entry per emitted token of the decode, in emission order.
    const std::vector<int> & ids() const { return ids_; }
    const std::vector<bool> & changed() const { return changed_; }

  private:
    std::shared_ptr<const graph> g_;
    float alpha_;
    int state_ = 0;
    int raw_best_ = -1;
    std::vector<std::pair<int, float>> scratch_;
    std::vector<unsigned char> mark_;
    std::vector<int> ids_;
    std::vector<bool> changed_;
};

// stdin text -> terms. One term per line: "written[\tfield...]". A second field that parses as a finite
// positive number is the weight; every other field is a spoken form (an alias the model writes when the
// term is said aloud, e.g. "GitHub\tГитхаб\tГитхаб"), so "OxSay\t2.5\tОкс Сей" is weight 2.5 with the
// alias "Окс Сей", and "OxSay\tОкс Сей" is weight 1 with the same alias. Only the second field can be a
// weight; a number further along is an alias. Surrounding whitespace is trimmed, blank lines are
// skipped, duplicate written forms dropped (first wins), terms and aliases under 3 characters (code
// points) dropped — the paper filtered 2-letter phrases to limit false accepts — at most 200 terms and 8
// aliases per term kept. A weight that is not a finite positive number is just an alias, unless the field
// looks like a number with junk after it ("2.5x"), which drops the line. err collects one line per
// problem; the terms that were fine are still returned (a malformed list degrades, it never fails the
// decode).
inline constexpr size_t kMinTermChars = 3;

// Parses a --boost-alpha / daemon alpha: a finite number in [0, kMaxAlpha], nothing after it.
inline bool parse_alpha(const std::string & s, float & out) {
    if (s.empty()) return false;
    char * end = nullptr;
    const double d = std::strtod(s.c_str(), &end);
    if (end == s.c_str() || *end != '\0' || !std::isfinite(d) || d < 0.0 || d > kMaxAlpha) return false;
    out = (float) d;
    return true;
}

// The one stderr line about terms the vocabulary cannot spell. Terms are the user's glossary: a count
// only, never their text.
inline std::string skip_report(const std::vector<std::string> & skipped) {
    if (skipped.empty()) return std::string();
    return "ox-stt: boost: " + std::to_string(skipped.size()) +
           " term form(s) cannot be spelled with the model's vocabulary, skipped\n";
}
inline constexpr size_t kMaxTerms = 200;
inline constexpr size_t kMaxAliases = 8;
// A term-line field that marks a written form which is an ordinary word of its language: only the spoken forms are
// boosted. "@" cannot start a heard form (glossary heard forms carry letters, digits, spaces, ' and - only).
inline constexpr const char * kSpokenOnly = "@spoken-only";

inline std::string trim(const std::string & s) {
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) ++b;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r' || s[e - 1] == '\n')) --e;
    return s.substr(b, e - b);
}

inline std::vector<term> parse_terms(const std::string & text, std::string & err) {
    std::vector<term> out;
    err.clear();
    size_t line_no = 0;
    for (size_t pos = 0; pos <= text.size();) {
        size_t nl = text.find('\n', pos);
        if (nl == std::string::npos) nl = text.size();
        const std::string line = text.substr(pos, nl - pos);
        pos = nl + 1;
        ++line_no;
        std::vector<std::string> f;
        for (size_t b = 0;;) {
            const size_t tab = line.find('\t', b);
            f.push_back(trim(line.substr(b, tab == std::string::npos ? std::string::npos : tab - b)));
            if (tab == std::string::npos) break;
            b = tab + 1;
        }
        const std::string & t = f[0];
        if (t.empty()) continue;  // the format has no comments: every non-empty line is a term, whatever it starts with
        const std::string at = "line " + std::to_string(line_no) + ": ";
        term tm;
        tm.text = t;
        bool bad = false;
        for (size_t i = 1; i < f.size() && !bad; ++i) {
            if (f[i].empty()) continue;
            if (f[i] == kSpokenOnly) {  // a flag, not an alias, in any position
                tm.spoken_only = true;
                continue;
            }
            if (i == 1) {
                char * end = nullptr;
                const double d = std::strtod(f[i].c_str(), &end);
                const bool numeric = end != f[i].c_str() && *end == '\0';
                const bool numberish = end != f[i].c_str() && (std::isdigit((unsigned char) f[i][0]) || f[i][0] == '-' || f[i][0] == '.');
                if (numeric) {
                    if (!std::isfinite(d) || d <= 0.0 || d > kMaxWeight) {
                        err += at + "bad weight\n";
                        bad = true;
                    } else {
                        tm.weight = (float) d;
                    }
                    continue;
                }
                if (numberish) {
                    err += at + "bad weight\n";
                    bad = true;
                    continue;
                }
            }
            if (cp_count(f[i]) < kMinTermChars) {
                err += at + "spoken form shorter than 3 characters\n";
                continue;
            }
            if (std::find(tm.spoken.begin(), tm.spoken.end(), f[i]) == tm.spoken.end() && f[i] != t &&
                tm.spoken.size() < kMaxAliases) {
                tm.spoken.push_back(f[i]);
            }
        }
        if (bad) continue;
        if (cp_count(t) < kMinTermChars) {
            err += at + "term shorter than 3 characters\n";
            continue;
        }
        const bool dup = std::any_of(out.begin(), out.end(), [&](const term & x) { return x.text == t; });
        if (dup) continue;
        if (out.size() >= kMaxTerms) {
            err += at + "more than 200 terms, rest ignored\n";
            break;
        }
        out.push_back(std::move(tm));
    }
    return out;
}

// Spoken -> written, after the decode. Replaces each whole-word, case-insensitive occurrence of a spoken
// form with its term's written form. "Whole word" means the characters on both sides are not letters or
// digits, so an alias that the decoder completed inside a longer word ("дозорного" for the alias "дозор")
// is left alone. Longest alias first; ё and е are the same letter. Done here and not in the Go glossary
// pass because the decoder knows exactly which forms it was asked to find, and the match has to respect the
// decode's own word boundaries; the glossary pass (heard -> meant, learned from usage) still runs after.
namespace detail {
inline bool is_letter_cp(uint32_t c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= 0xC0 && c <= 0x24F) || (c >= 0x400 && c <= 0x4FF);
}
inline std::vector<uint32_t> fold_cps(const std::string & s) {
    std::vector<uint32_t> o;
    for (const std::string & ch : utf8_chars(s)) {
        uint32_t c = to_lower_cp(decode_cp(ch));
        if (c == 0x451) c = 0x435;  // ё -> е
        o.push_back(c);
    }
    return o;
}
}  // namespace detail

// The aliases folded once; map() is then allocation-light enough to run per word and per segment.
class speller {
  public:
    explicit speller(const std::vector<term> & terms) {
        for (const term & t : terms) {
            for (const std::string & sp : t.spoken) {
                std::vector<uint32_t> f = detail::fold_cps(sp);
                if (!f.empty()) als_.push_back({ std::move(f), t.text });
            }
        }
        std::stable_sort(als_.begin(), als_.end(), [](const al & a, const al & b) { return a.f.size() > b.f.size(); });
    }

    std::string map(const std::string & text) const {
        if (als_.empty()) return text;
        const std::vector<std::string> ch = detail::utf8_chars(text);
        std::vector<uint32_t> fold, raw;
        fold.reserve(ch.size());
        raw.reserve(ch.size());
        for (const std::string & c : ch) {
            uint32_t cp = detail::decode_cp(c);
            raw.push_back(cp);
            cp = detail::to_lower_cp(cp);
            fold.push_back(cp == 0x451 ? 0x435 : cp);
        }
        std::string out;
        for (size_t i = 0; i < ch.size();) {
            bool hit = false;
            if (i == 0 || !detail::is_letter_cp(raw[i - 1])) {
                for (const al & a : als_) {
                    const size_t n = a.f.size();
                    if (i + n > ch.size() || fold[i] != a.f[0] || !std::equal(a.f.begin(), a.f.end(), fold.begin() + (long) i)) continue;
                    if (i + n < ch.size() && detail::is_letter_cp(raw[i + n])) continue;
                    out += a.written;
                    i += n;
                    hit = true;
                    break;
                }
            }
            if (!hit) {
                out += ch[i];
                ++i;
            }
        }
        return out;
    }

  private:
    struct al {
        std::vector<uint32_t> f;
        std::string written;
    };
    std::vector<al> als_;
};

inline std::string map_spoken(const std::string & text, const std::vector<term> & terms) {
    return speller(terms).map(text);
}

}  // namespace oxstt::boost
