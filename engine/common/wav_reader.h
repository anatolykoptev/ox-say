// wav_reader.h — the one WAV reader behind ox-stt and ox-align (#13).
//
// 16 kHz mono PCM16 or float32 WAV -> float samples. Header-only, pure C++17 (no whisper/ggml
// deps), so engine/common/wav_reader_test.cpp builds standalone on any host and in CI.
//
// Two ways in, one decoder:
//   read_bytes / read_file          samples only (ox-stt)
//   read_bytes_padded / read_file_padded
//                                   samples decoded straight into the caller's buffer at offset
//                                   `head`, zeros before and after (ox-align's padded window
//                                   buffer): the unpadded copy never exists.
// Accept/reject behaviour and every error message are the same on every path.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace oxwav {

constexpr uint32_t kRate = 16000;

namespace detail {

inline uint32_t rd32(const unsigned char * p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t) p[3] << 24; }
inline uint16_t rd16(const unsigned char * p) { return (uint16_t) (p[0] | p[1] << 8); }

// Where the samples are and how they are stored; nothing is decoded yet.
struct Layout {
    size_t body = 0;      // byte offset of the first sample
    size_t n    = 0;      // sample count
    bool   f32  = false;  // float32 (else PCM16)
};

inline bool locate(const unsigned char * buf, size_t size, Layout & lo, std::string & err) {
    if (size < 12 || memcmp(buf, "RIFF", 4) != 0 || memcmp(buf + 8, "WAVE", 4) != 0) {
        err = "not a RIFF/WAVE file";
        return false;
    }
    int fmt = 0, ch = 0, bits = 0;
    uint32_t rate = 0;
    for (size_t off = 12; off + 8 <= size;) {
        const uint32_t len = rd32(buf + off + 4);
        const size_t body = off + 8;
        if (body + len > size && memcmp(buf + off, "data", 4) != 0) {
            break;
        }
        if (memcmp(buf + off, "fmt ", 4) == 0 && len >= 16) {
            fmt  = rd16(buf + body);
            ch   = rd16(buf + body + 2);
            rate = rd32(buf + body + 4);
            bits = rd16(buf + body + 14);
            if (fmt == 0xFFFE && len >= 26) {  // WAVE_FORMAT_EXTENSIBLE: sub-format code
                fmt = rd16(buf + body + 24);
            }
        } else if (memcmp(buf + off, "data", 4) == 0) {
            if (rate != kRate || ch != 1 || !((fmt == 1 && bits == 16) || (fmt == 3 && bits == 32))) {
                err = "need 16 kHz mono PCM16 or float32 (got rate " + std::to_string(rate) + ", channels " +
                      std::to_string(ch) + ", format " + std::to_string(fmt) + "/" + std::to_string(bits) + " bit)";
                return false;
            }
            // a streaming writer leaves the length 0 or 0xFFFFFFFF: take the rest of the file
            const size_t avail = (len == 0 || len == 0xFFFFFFFFu) ? size - body : std::min<size_t>(len, size - body);
            lo.body = body;
            lo.f32  = fmt == 3;
            lo.n    = avail / (lo.f32 ? 4 : 2);
            if (lo.n == 0) {
                err = "no audio samples";
                return false;
            }
            return true;
        }
        off = body + len + (len & 1);  // chunks are word-aligned: an odd size carries a pad byte
    }
    err = "no data chunk";
    return false;
}

inline bool decode(const unsigned char * buf, const Layout & lo, float * dst, std::string & err) {
    const unsigned char * p = buf + lo.body;
    if (!lo.f32) {
        for (size_t i = 0; i < lo.n; ++i) {
            dst[i] = (int16_t) rd16(p + 2 * i) / 32768.0f;
        }
        return true;
    }
    memcpy(dst, p, lo.n * 4);
    for (size_t i = 0; i < lo.n; ++i) {
        if (!std::isfinite(dst[i])) {
            err = "float WAV has non-finite samples";
            return false;
        }
    }
    return true;
}

inline bool slurp(const std::string & path, std::vector<unsigned char> & buf, std::string & err) {
    FILE * f = fopen(path.c_str(), "rb");
    if (!f) {
        err = "cannot open " + path;
        return false;
    }
    if (fseek(f, 0, SEEK_END) == 0) {
        const long size = ftell(f);
        if (size > 0) {
            buf.reserve((size_t) size);
        }
        fseek(f, 0, SEEK_SET);
    }
    unsigned char tmp[1 << 16];
    size_t n;
    while ((n = fread(tmp, 1, sizeof(tmp), f)) > 0) {
        buf.insert(buf.end(), tmp, tmp + n);
    }
    fclose(f);
    return true;
}

}  // namespace detail

// Samples at out[head .. head+n), out[0..head) and the `tail(n)` samples after them zero. `out` is
// sized once, to head + n + tail(n): it is the only sample allocation. Its content is defined only when
// the call returns true.
template <class TailFn>
bool read_bytes_padded(const unsigned char * buf, size_t size, std::vector<float> & out, std::string & err,
                       size_t head, TailFn tail) {
    detail::Layout lo;
    if (!detail::locate(buf, size, lo, err)) {
        return false;
    }
    out.assign(head + lo.n + (size_t) tail(lo.n), 0.0f);
    return detail::decode(buf, lo, out.data() + head, err);
}

template <class TailFn>
bool read_file_padded(const std::string & path, std::vector<float> & out, std::string & err, size_t head,
                      TailFn tail) {
    std::vector<unsigned char> buf;
    if (!detail::slurp(path, buf, err)) {
        return false;
    }
    return read_bytes_padded(buf.data(), buf.size(), out, err, head, tail);
}

// ox-align's tail: `ctx` zeros of context plus enough zeros to round the n decoded samples up to whole
// windows of `win` samples (so n < win gets one padded window, n = win none). win must be > 0.
inline size_t window_tail(size_t n, int64_t win, int64_t ctx) {
    const int64_t ni  = (int64_t) n;
    const int64_t ext = ((-ni) % win + win) % win;
    return (size_t) (ctx + ext);
}

inline bool read_bytes(const unsigned char * buf, size_t size, std::vector<float> & out, std::string & err) {
    return read_bytes_padded(buf, size, out, err, 0, [](size_t) { return (size_t) 0; });
}

inline bool read_file(const std::string & path, std::vector<float> & out, std::string & err) {
    return read_file_padded(path, out, err, 0, [](size_t) { return (size_t) 0; });
}

}  // namespace oxwav
