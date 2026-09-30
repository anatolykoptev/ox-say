// VAD segmenter for ox-stt --serve: turns a stream of per-window speech
// probabilities (Silero VAD, window = 512 samples at 16 kHz) into closed audio
// segments as absolute sample ranges [s, e). Pure C++17, no whisper/ggml —
// drives the session decoder queue; compiled and tested standalone.
//
// Feed whole windows; the last window of a feed may be short (the session's
// carried remainder at finish). Memory stays bounded: outside speech the
// segmenter keeps only the previous segment's end and one energy bucket —
// nothing per window; inside speech it keeps ~1.2 s of 10 ms bucket energies,
// only what the hard-cap cut needs.
#ifndef OX_STT_SEGMENTER_H
#define OX_STT_SEGMENTER_H

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <vector>

namespace oxstt {

constexpr int SEG_SR = 16000;   // sample rate
constexpr int SEG_WIN = 512;    // samples per probability window
constexpr int SEG_BUCKET = 160; // samples per energy bucket (10 ms)

struct seg_params {
    float on_p = 0.5f;          // window opens speech at p >= on_p
    float off_p = 0.35f;        // in speech, a window counts as silence at p < off_p
    int close_ms = 400;         // continuous silence that closes a segment
    int min_speech_ms = 250;    // segments with less speech are dropped
    int pad_pre_ms = 200;       // pad before the onset window (clamped to prev end / 0)
    int pad_post_ms = 200;      // pad after the last speech window (within closing silence)
    int cap_ms = 12000;         // open segments are force-cut at this length
    int cap_quiet_ms = 150;     // quiet stretch whose centre becomes the cut
    int cap_lookback_ms = 1000; // search that stretch in the segment's last this-long
};

struct seg_range {
    uint64_t s, e;  // absolute sample offsets from the session start, [s, e)
    bool operator==(const seg_range & o) const { return s == o.s && e == o.e; }
};

class segmenter {
public:
    explicit segmenter(seg_params p = seg_params())
        : p_(p),
          pad_pre_((uint64_t) p.pad_pre_ms * SEG_SR / 1000),
          pad_post_((uint64_t) p.pad_post_ms * SEG_SR / 1000),
          close_((uint64_t) p.close_ms * SEG_SR / 1000),
          min_sp_((uint64_t) p.min_speech_ms * SEG_SR / 1000),
          cap_((uint64_t) p.cap_ms * SEG_SR / 1000),
          cap_lookback_((uint64_t) p.cap_lookback_ms * SEG_SR / 1000),
          cap_quiet_((uint64_t) p.cap_quiet_ms * SEG_SR / 1000),
          // buckets to keep while in speech: the cap search plus slack
          keep_((uint64_t) (p.cap_lookback_ms + p.cap_quiet_ms + 100) * SEG_SR / 1000) {}

    // probs[i] is the speech probability of window i; samples are that
    // window's audio. All windows are SEG_WIN samples except the last of a
    // call, which may be short (n_samples <= n_probs*SEG_WIN, the rest full).
    // Emitted closed segments are appended to out.
    void feed(const float * probs, size_t n_probs, const float * samples, size_t n_samples,
              std::vector<seg_range> & out) {
        ingest_energy(samples, n_samples);
        for (size_t i = 0; i < n_probs; ++i) {
            const size_t off = (size_t) i * SEG_WIN;
            if (off >= n_samples) {
                break;
            }
            const uint64_t w0 = pos_;
            const size_t wl = std::min<size_t>(SEG_WIN, n_samples - off);
            pos_ += wl;
            const float p = probs[i];
            if (!in_speech_) {
                if (p >= p_.on_p) {
                    in_speech_ = true;
                    last_speech_end_ = pos_;
                    speech_samples_ = wl;
                    seg_start_ = w0 > pad_pre_ ? w0 - pad_pre_ : 0;
                    if (seg_start_ < prev_end_) {
                        seg_start_ = prev_end_;
                    }
                }
            } else if (p >= p_.off_p) {
                last_speech_end_ = pos_;
                speech_samples_ += wl;
            } else if (pos_ - last_speech_end_ >= close_) {
                close(std::min(last_speech_end_ + pad_post_, pos_), out);
            }
            if (in_speech_ && pos_ - seg_start_ >= cap_) {
                cut_at_cap(out);
            }
        }
        bump_floor();
        prune_energy();
    }

    // Close an open segment: end pad clamped to the samples seen, min-speech
    // rule applies.
    void finish(std::vector<seg_range> & out) {
        if (in_speech_) {
            close(std::min(last_speech_end_ + pad_post_, pos_), out);
        }
        bump_floor();
    }

    // Lowest absolute offset a future emit can still reference: the open
    // segment's start while in speech; while silent, nothing before the next
    // onset's pre-pad reach or the previous segment's end. Monotone — the
    // caller may drop buffered audio below it.
    uint64_t floor() const { return floor_; }

private:
    // floor_ tracks the highest value the emit lower-bound has reached; the
    // bound itself is max(prev_end_, pos_-pad_pre_) out of speech and
    // seg_start_ in speech.
    void bump_floor() {
        uint64_t f;
        if (in_speech_) {
            f = seg_start_;
        } else {
            f = pos_ > pad_pre_ ? pos_ - pad_pre_ : 0;
            if (f < prev_end_) {
                f = prev_end_;
            }
        }
        if (f > floor_) {
            floor_ = f;
        }
    }

    void close(uint64_t end, std::vector<seg_range> & out) {
        if (speech_samples_ >= min_sp_) {
            out.push_back({ seg_start_, end });
            prev_end_ = end;
        }
        in_speech_ = false;
    }

    // Cut the open segment at the centre of the quietest cap_quiet_ stretch in
    // [pos - cap_lookback_, pos_]; the segment continues from the cut, still in
    // speech.
    void cut_at_cap(std::vector<seg_range> & out) {
        const uint64_t hi = pos_;
        const uint64_t lo = hi - cap_lookback_;
        const uint64_t nb = cap_quiet_ / SEG_BUCKET;              // buckets per stretch
        const uint64_t b0 = (lo + SEG_BUCKET - 1) / SEG_BUCKET;   // first bucket in range
        const uint64_t b_max = hi / SEG_BUCKET >= nb ? hi / SEG_BUCKET - nb : 0;
        uint64_t cut = 0;
        if (b_max >= b0 && nb > 0) {
            double best = 0;
            uint64_t bk = b0;
            for (uint64_t k = 0; k < nb; ++k) {
                best += bucket(b0 + k);
            }
            double sum = best;
            for (uint64_t b = b0 + 1; b <= b_max; ++b) {
                sum += bucket(b + nb - 1) - bucket(b - 1);
                if (sum < best) {
                    best = sum;
                    bk = b;
                }
            }
            cut = bk * SEG_BUCKET + cap_quiet_ / 2;
        } else {
            cut = (lo + hi) / 2;  // parameters leave no full stretch: centre it
        }
        out.push_back({ seg_start_, cut });
        prev_end_ = cut;
        seg_start_ = cut;
        // speech_samples_ is NOT reset: the count belongs to the utterance, not
        // the emitted piece. The min-speech rule exists to drop isolated noise
        // blips — a continuation that ends 160 ms after the cut is the tail of
        // a real utterance and must reach the decoder.
    }

    // Sample energy per SEG_BUCKET-aligned absolute bucket; only kept while in
    // speech for the cap search.
    void ingest_energy(const float * x, size_t n) {
        for (size_t i = 0; i < n; ++i) {
            const uint64_t g = pos_ + i;
            const uint64_t b = g / SEG_BUCKET;
            if (buckets_.empty()) {
                buckets_off_ = b * SEG_BUCKET;
            } else if (b * SEG_BUCKET < buckets_off_) {
                continue;  // already pruned: cannot happen for in-order feeds
            }
            while (buckets_off_ + buckets_.size() * SEG_BUCKET <= b * SEG_BUCKET) {
                buckets_.push_back(0.0);
            }
            buckets_[(size_t) (b - buckets_off_ / SEG_BUCKET)] += (double) x[i] * x[i];
        }
    }

    // Drop buckets the cap search can never reach again: while in speech it
    // only reads [pos_-keep_, pos_); while silent nothing is kept.
    void prune_energy() {
        const uint64_t keep_from = in_speech_ && pos_ > keep_ ? pos_ - keep_ : (in_speech_ ? 0 : pos_);
        while (!buckets_.empty() && buckets_off_ + SEG_BUCKET <= keep_from) {
            buckets_.pop_front();
            buckets_off_ += SEG_BUCKET;
        }
    }

    double bucket(uint64_t b) const {
        if (b * SEG_BUCKET < buckets_off_ || b - buckets_off_ / SEG_BUCKET >= buckets_.size()) {
            return 0.0;
        }
        return buckets_[(size_t) (b - buckets_off_ / SEG_BUCKET)];
    }

    seg_params p_;
    const uint64_t pad_pre_, pad_post_, close_, min_sp_, cap_, cap_lookback_, cap_quiet_, keep_;

    uint64_t pos_ = 0;             // real samples consumed
    uint64_t seg_start_ = 0;       // open segment's start (post-pad)
    uint64_t last_speech_end_ = 0; // end of the last speech window
    uint64_t speech_samples_ = 0;  // in-speech windows counted toward min_speech
    uint64_t prev_end_ = 0;        // end of the last emitted segment (pre-pad floor)
    uint64_t floor_ = 0;           // see bump_floor()
    bool in_speech_ = false;

    std::deque<double> buckets_;   // energy per SEG_BUCKET bucket
    uint64_t buckets_off_ = 0;     // absolute sample index of buckets_.front()'s start
};

}  // namespace oxstt

#endif
