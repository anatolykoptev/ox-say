// Re-decode at release for ox-stt --serve sessions (issue #88): a streamed
// session decodes every VAD segment alone and loses ~1.5-2 WER points at the
// joins, so POST .../finish on a session that had cuts and is short enough
// decodes the whole recording once — the same padded path /transcribe runs —
// and answers that text. Pure C++17, no whisper/ggml — the decision is
// unit-tested in CI (redecode_test.cpp), the decode itself needs the model.
#ifndef OX_STT_REDECODE_H
#define OX_STT_REDECODE_H

#include <string>
#include <vector>

namespace oxstt {

// Whether a finished session is worth one more decode: the stream was cut
// (more than one decoded segment — a single-segment session has no join to
// lose), its audio is at most max_s seconds, and the feature is on
// (max_s > 0; 0 disables).
inline bool should_redecode(size_t n_segments, double total_s, double max_s) {
    return max_s > 0.0 && n_segments > 1 && total_s <= max_s;
}

// What the finish answer's "text" is: the re-decoded text only when the
// re-decode ran AND produced text. A failed or empty re-decode must never
// lose the text the streamed segments already decoded — it answers the
// streamed join (the caller logs why).
inline const std::string & final_text(bool redecoded_ok, const std::string & redecoded_text,
                                      const std::string & streamed_text) {
    return redecoded_ok && !redecoded_text.empty() ? redecoded_text : streamed_text;
}

// Keep the whole recording while the finish re-decode can still run (#88):
// appends `fresh` to re_pcm while the total stays within the cap
// ((max_s + 1 s) * sr samples); the first append that would pass it frees the
// buffer (swap, not clear) and sets `dropped`, which is sticky: a buffer with
// a hole in it must never be refilled and decoded. A single chunk larger than
// the cap drops at once. max_s <= 0 (feature off) or an already-dropped
// buffer is a no-op.
inline void append_or_drop(std::vector<float> & re_pcm, bool & dropped,
                           const std::vector<float> & fresh, double max_s, int sr) {
    if (max_s <= 0.0 || dropped) {
        return;
    }
    const size_t cap = (size_t) ((max_s + 1.0) * sr);
    if (re_pcm.size() + fresh.size() <= cap) {
        re_pcm.insert(re_pcm.end(), fresh.begin(), fresh.end());
    } else {
        std::vector<float>().swap(re_pcm);
        dropped = true;
    }
}

// Whether the re-decode copy holds every sample the session received
// (audio_base + audio.size() at finish). A copy with a hole or a stale
// longer one is not the recording and must not be decoded.
inline bool redecode_buffer_complete(size_t re_pcm_size, unsigned long long total) {
    return (unsigned long long) re_pcm_size == total;
}

}  // namespace oxstt

#endif  // OX_STT_REDECODE_H
