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
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace edge_pad {

constexpr size_t  kPadSamples = 16000;  // 1 s at 16 kHz on each side: 100 hops of 160 samples
constexpr int64_t kPadFrames  = 100;    // the same 1 s in parakeet's token time unit (10 ms)
constexpr double  kRelDb      = -12.0;  // pad RMS relative to the chunk RMS
constexpr double  kFloorDbfs  = -60.0;  // frames at or under this RMS count as silence
constexpr double  kFillBelowDb = -10.0; // edge frames this far under the pad level get the pad noise too
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

// out = noise | x | noise, each noise kPadSamples long at the chunk's level + rel_db dB, where the
// level is the RMS of the chunk's 10 ms frames above the floor (digital silence in a file does not
// lower it). Quiet runs at the chunk's own edges (frames more than kFillBelowDb under the pad level:
// digital silence, a dither floor, a far-down room tone) get the same noise added: a pad outside a
// second of digital zeros gives the decoder no usable context, and that input stays empty
// otherwise. Interior pauses are left alone.
// Returns false and leaves out/lay untouched when x is empty or has no frame above the floor:
// silence must stay silence, so the caller decodes x as it is.
inline bool pad(const float * x, size_t n, std::vector<float> & out, layout & lay, double rel_db = kRelDb) {
    const size_t hop = 160;
    const size_t nf  = n / hop + (n % hop ? 1 : 0);
    std::vector<double> fdb(nf);
    double e = 0.0;
    size_t ne = 0;
    for (size_t k = 0; k < nf; ++k) {
        const size_t s0 = k * hop, len = std::min(hop, n - s0);
        fdb[k] = rms_dbfs(x + s0, len);
        if (fdb[k] > kFloorDbfs) {
            for (size_t i = s0; i < s0 + len; ++i) {
                e += (double) x[i] * (double) x[i];
            }
            ne += len;
        }
    }
    if (ne == 0) {
        return false;
    }
    const double level = 10.0 * std::log10(e / (double) ne);
    const double amp   = std::pow(10.0, (level + rel_db) / 20.0);
    const double fill  = level + rel_db + kFillBelowDb;
    size_t lead = 0, trail = 0;  // whole frames from the start / from the end
    while (lead < nf && fdb[lead] < fill) {
        ++lead;
    }
    while (trail < nf - lead && fdb[nf - 1 - trail] < fill) {
        ++trail;
    }
    const size_t lead_n  = lead * hop;                           // lead < nf: some frame is >= level
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
inline bool place(int64_t & t0, int64_t & t1, const layout & lay) {
    if (t1 <= lay.lo - kDropMarginFrames || t0 >= lay.hi + kDropMarginFrames) {
        return false;
    }
    const int64_t a = t0 - lay.shift, b = t1 - lay.shift;
    t0 = a < 0 ? 0 : (a > lay.len ? lay.len : a);
    t1 = b < t0 ? t0 : (b > lay.len ? lay.len : b);
    return true;
}

// Segment text from raw SentencePiece pieces, by the rules parakeet's own segment text uses:
// U+2581 is a space (none ahead of the first character), control pieces ("<unk>", ...) are dropped.
inline std::string join_pieces(const std::vector<std::string> & pieces) {
    const std::string mark = "\xE2\x96\x81";
    std::string text;
    for (const std::string & p : pieces) {
        if (p.size() >= 2 && p.front() == '<' && p.back() == '>') {
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

}  // namespace edge_pad
