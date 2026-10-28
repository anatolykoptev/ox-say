// Edge context for Parakeet decodes (#123). Pure C++17, no whisper/ggml deps, so CI compiles its
// test directly (edge_pad_test.cpp).
//
// Parakeet TDT drops words when a decode window has no quiet context at its edges: a short clip
// that starts on its first phoneme and ends on its last decodes empty (or with a hallucinated tail)
// for a large, take-dependent share of inputs, and a session segment cut mid-speech loses 25-100 %
// of its words. The feature pipeline matches NeMo's (engine/README.md, "Edge context"); the
// measured cure is acoustic context the model can read as "quiet": comfort noise a fixed ratio below
// the chunk's own level, on both sides. Digital silence is not that (it decodes no better and
// flips clips that were fine), and neither is a fixed absolute level.
//
// decode_parakeet decodes pad(chunk), then maps every token back with place(): the pad is a whole
// number of mel hops, so the shift is exact, and tokens the decoder made out of the noise alone
// are dropped.
#pragma once

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace edge_pad {

constexpr size_t  kPadSamples = 16000;  // 1 s on each side: 100 mel hops (see the grid note at place())
constexpr int64_t kPadFrames  = 100;    // the same pad in parakeet's token time unit (10 ms)
constexpr double  kRelDb      = -12.0;  // pad RMS relative to the chunk level
constexpr double  kFloorDbfs  = -60.0;  // frames at or under this RMS count as silence
constexpr double  kFillDbfs   = -80.0;  // edge frames at or under this get the pad noise (see pad())
constexpr double  kClampDb    = 10.0;   // level: frame powers clamped to the 90th percentile + this
constexpr int64_t kDropMarginFrames = 50;  // 0.5 s: see place()
constexpr uint64_t kSeed      = 0x6f782d7374742d31ull;  // fixed: the same audio decodes the same way

// RMS in dBFS; -inf for an empty or all-zero chunk.
inline double rms_dbfs(const float * x, size_t n) {
    double s = 0.0;
    for (size_t i = 0; i < n; ++i) {
        s += (double) x[i] * (double) x[i];
    }
    return s > 0.0 ? 10.0 * std::log10(s / (double) n) : -INFINITY;
}

// splitmix64 + Box-Muller: the same sequence on every standard library (std::normal_distribution's
// output is implementation-defined and differs between libc++ and libstdc++).
struct noise {
    uint64_t s;
    double   spare     = 0.0;
    bool     has_spare = false;

    uint64_t next() {
        uint64_t z = (s += 0x9E3779B97F4A7C15ull);
        z          = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z          = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }
    double uniform() { return ((double) (next() >> 11) + 0.5) * (1.0 / 9007199254740992.0); }  // (0, 1)
    double gauss() {
        if (has_spare) {
            has_spare = false;
            return spare;
        }
        const double two_pi = 6.283185307179586476925286766559;
        const double r = std::sqrt(-2.0 * std::log(uniform())), th = two_pi * uniform();
        spare     = r * std::sin(th);
        has_spare = true;
        return r * std::cos(th);
    }
};

// Where the chunk sits in a padded decode, in parakeet's token time unit (10 ms): tokens before lo
// or after hi were made out of noise alone; shift maps the padded timeline onto the chunk's own,
// which is len long.
struct layout {
    int64_t shift = 0, lo = 0, hi = 0, len = 0;
};

// A chunk of n samples in 10 ms units, rounded up: a token in the last partial hop is speech.
inline int64_t chunk_frames(size_t n) { return (int64_t) ((n + 159) / 160); }

// out = noise | x | noise, each noise kPadSamples long at the chunk's level + rel_db dB.
//
// Level: the mean power of the chunk's 10 ms frames above the floor, each frame clamped to the
// 90th-percentile frame power + kClampDb, so digital silence does not lower it and one click does
// not lift it (a full-scale 10 ms click over -50 dBFS speech would otherwise put the pad 13 dB
// over the speech).
//
// Edge fill: runs of frames at or under kFillDbfs (-80 dBFS) at the chunk's own start and end get
// the same noise added. That bound is absolute on purpose: it is under anything a microphone
// delivers (a quiet room through a laptop mic is -60..-45 dBFS, PCM16's step -96 dBFS), so it
// only ever catches digital silence, a fade-out tail or dither - and a pad outside a second of
// digital zeros gives the decoder no usable context (that input stays empty otherwise). A bound
// relative to the chunk level filled quiet speech (a far speaker before a near one) with noise
// louder than it and moved lo past it, losing the words. Interior pauses are left alone.
//
// Returns false and leaves out/lay untouched when x is empty or has no frame above the floor:
// silence must stay silence, so the caller decodes x as it is.
inline bool pad(const float * x, size_t n, std::vector<float> & out, layout & lay, double rel_db = kRelDb) {
    const size_t hop = 160;
    const size_t nf  = n / hop + (n % hop ? 1 : 0);
    std::vector<double> fdb(nf), pw;  // per-frame dBFS; power of the frames above the floor
    for (size_t k = 0; k < nf; ++k) {
        const size_t s0 = k * hop, len = std::min(hop, n - s0);
        fdb[k] = rms_dbfs(x + s0, len);
        if (fdb[k] > kFloorDbfs) {
            pw.push_back(std::pow(10.0, fdb[k] / 10.0));
        }
    }
    if (pw.empty()) {
        return false;
    }
    std::vector<double> sorted = pw;
    const size_t k90 = (sorted.size() - 1) * 9 / 10;
    std::nth_element(sorted.begin(), sorted.begin() + (std::ptrdiff_t) k90, sorted.end());
    const double cap = sorted[k90] * std::pow(10.0, kClampDb / 10.0);
    double e = 0.0;
    for (double v : pw) {
        e += std::min(v, cap);
    }
    const double level = 10.0 * std::log10(e / (double) pw.size());
    const double amp   = std::pow(10.0, (level + rel_db) / 20.0);
    size_t lead = 0, trail = 0;  // whole frames from the start / from the end
    while (lead < nf && fdb[lead] <= kFillDbfs) {
        ++lead;
    }
    while (trail < nf - lead && fdb[nf - 1 - trail] <= kFillDbfs) {
        ++trail;
    }
    const size_t lead_n  = lead * hop;                           // lead < nf: some frame is above the floor
    const size_t trail_n = trail ? n - (nf - trail) * hop : 0;  // the last frame may be short
    out.assign(n + 2 * kPadSamples, 0.0f);
    noise g{ kSeed };
    for (size_t i = 0; i < kPadSamples + lead_n; ++i) {
        out[i] = (float) (amp * g.gauss());
    }
    for (size_t i = 0; i < n; ++i) {
        out[kPadSamples + i] += x[i];
    }
    for (size_t i = kPadSamples + n - trail_n; i < out.size(); ++i) {
        out[i] += (float) (amp * g.gauss());
    }
    lay.shift = kPadFrames;
    lay.len   = chunk_frames(n);
    lay.lo    = kPadFrames + (int64_t) (lead_n / hop);
    lay.hi    = kPadFrames + chunk_frames(n - trail_n);
    return true;
}

// Maps [t0, t1] on the padded timeline (10 ms units) onto the chunk's own, clamped to [0, len].
// Returns false, leaving t0/t1 as they were, when the span ends more than kDropMarginFrames before
// lay.lo or starts that far after lay.hi: the decoder made it out of the noise. The margin is
// load-bearing: TDT stamps a token at the encoder frame (80 ms) it was emitted on, which for the
// first and last pieces of real speech is often one or two frames inside the pad ("Than|ks" would
// lose "Than" to a margin of 0).
// Grid: token times are encoder frames (80 ms) of the PADDED signal, and 1 s is 12.5 of them, so
// mapped times sit on an 80 ms grid offset by 40 ms from an unpadded decode's: they are exact to
// the 10 ms tick, but no finer than +-40 ms. A 0.96 s pad keeps the grid but was measured worse:
// 6 of 94 cut windows lost the second speaker against 1 of 94 with 1 s (four take pairs).
inline bool place(int64_t & t0, int64_t & t1, const layout & lay) {
    if (t1 <= lay.lo - kDropMarginFrames || t0 >= lay.hi + kDropMarginFrames) {
        return false;
    }
    const int64_t a = t0 - lay.shift, b = t1 - lay.shift;
    t0 = a < 0 ? 0 : (a > lay.len ? lay.len : a);
    t1 = b < t0 ? t0 : (b > lay.len ? lay.len : b);
    return true;
}

// parakeet's own control pieces (parakeet.cpp is_sentencepiece_control): they carry no text.
inline bool is_control(const std::string & p) { return p == "<unk>" || p == "<s>" || p == "</s>" || p == "[BLANK]"; }

// Segment text from raw SentencePiece pieces, by the rules parakeet's own segment text uses:
// U+2581 is a space (none ahead of the first character), control pieces are dropped.
inline std::string join_pieces(const std::vector<std::string> & pieces) {
    const std::string mark = "\xE2\x96\x81";
    std::string text;
    for (const std::string & p : pieces) {
        if (is_control(p)) {
            continue;
        }
        for (size_t i = 0; i < p.size();) {
            if (p.compare(i, mark.size(), mark) == 0) {
                if (!text.empty()) {
                    text += ' ';
                }
                i += mark.size();
            } else {
                text += p[i++];
            }
        }
    }
    return text;
}

// A piece without its U+2581 word-boundary marks.
inline std::string strip_marker(const std::string & piece) {
    std::string s = piece;
    const std::string mark = "\xE2\x96\x81";
    size_t p;
    while ((p = s.find(mark)) != std::string::npos) {
        s.erase(p, mark.size());
    }
    return s;
}

inline bool is_punct(const std::string & t) {
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

// One decoded token: its raw piece, times on the decoded timeline (10 ms units), probability.
struct token {
    std::string piece;
    int64_t     t0, t1;
    double      p;
    bool        word_start;
};

struct word {
    std::string w;
    double      s, e, p;  // seconds; p averaged over the word's pieces (punctuation excluded)
};

struct segment_result {
    bool        keep = false;  // false: every token came from the pads, nothing was said
    double      s = 0.0, e = 0.0;
    std::string text;
    int         n_dropped = 0;  // tokens the decoder made out of a pad alone
};

// The token loop of decode_parakeet for one parakeet segment of one chunk: appends the segment's
// words to `words` (words of earlier segments are not touched) and returns its span and text.
// lay is null for a chunk decoded as it is (under the floor): every token is kept on its own time
// and the text is the library's. With a pad, tokens map back through place(); a dropped token
// resets the word, so a kept continuation piece starts a word of its own. Punctuation right after
// a kept piece is exempt from the drop: parakeet stamps it at that piece's end, which may reach
// into the pad - it belongs to that word (also a word-start piece, the vocab has U+2581"-" and
// U+2581"'"), not to the noise, and it takes the previous kept piece's mapped end as its time.
// When anything was dropped the text is rebuilt from the kept pieces, so text and words agree.
inline segment_result map_segment(const std::vector<token> & toks, const std::string & lib_text, int64_t seg_t0,
                                  int64_t seg_t1, const layout * lay, double off, double end,
                                  std::vector<word> & words) {
    segment_result r;
    std::vector<std::string> kept;
    int     n_in_word = 0;  // pieces averaged into the current word's p
    bool    prev_kept = false;
    int64_t prev_t1   = 0;  // mapped end of the last kept piece
    for (const token & d : toks) {
        const std::string t = strip_marker(d.piece);
        int64_t t0 = d.t0, t1 = d.t1;
        if (lay && !place(t0, t1, *lay)) {
            if (!(prev_kept && is_punct(t))) {
                ++r.n_dropped;
                n_in_word = 0;
                prev_kept = false;
                continue;
            }
            t0 = t1 = prev_t1;
        }
        prev_kept = true;
        prev_t1   = t1;
        kept.push_back(d.piece);
        if (t.empty()) {
            if (d.word_start) {
                n_in_word = 0;  // a lone boundary marker: the next piece starts a word
            }
            continue;
        }
        if (is_punct(t) && !d.word_start && !words.empty() && n_in_word > 0) {
            words.back().w += t;  // punctuation: no timing of its own, not part of p
        } else if (d.word_start || words.empty() || n_in_word == 0) {
            words.push_back({ t, off + t0 / 100.0, off + t1 / 100.0, d.p });
            n_in_word = 1;
        } else {
            word & w = words.back();
            w.w += t;
            w.e = std::max(w.e, off + t1 / 100.0);
            w.p = (w.p * n_in_word + d.p) / (n_in_word + 1);
            ++n_in_word;
        }
    }
    if (lay && kept.empty()) {
        return r;
    }
    int64_t s0 = seg_t0, s1 = seg_t1;
    if (lay) {
        place(s0, s1, *lay);
    }
    r.keep = true;
    r.s    = off + s0 / 100.0;
    r.e    = std::min(end, off + s1 / 100.0);
    r.text = r.n_dropped == 0 ? lib_text : join_pieces(kept);
    return r;
}

}  // namespace edge_pad
