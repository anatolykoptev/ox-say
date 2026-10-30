// Re-decode at release for ox-stt --serve sessions (issue #88): a streamed
// session decodes every VAD segment alone and loses ~1.5-2 WER points at the
// joins, so POST .../finish on a session that had cuts and is short enough
// decodes the whole recording once — the same padded path /transcribe runs —
// and answers that text. Pure C++17, no whisper/ggml — the decision is
// unit-tested in CI (redecode_test.cpp), the decode itself needs the model.
#ifndef OX_STT_REDECODE_H
#define OX_STT_REDECODE_H

#include <string>

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

}  // namespace oxstt

#endif  // OX_STT_REDECODE_H
