// The wire form of a per-request boost list: {"alpha":2,"terms":["OxSay\tОкс Сей","Devin"]}, each string one
// term line in the boost.h format (written<TAB>spoken...). It rides in the body of POST /sessions and, as
// base64url, in the X-Ox-Terms header of POST /transcribe. A minimal reader instead of a JSON library: the
// only shapes it accepts are an object with an optional numeric "alpha" and a "terms" array of strings;
// anything else is refused whole, and the caller then decodes without boosting (fail-open, never a failed
// decode). Never logs, never prints term text.
#pragma once

#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

#include "boost.h"

namespace oxstt::boost {

// The header (base64url) is capped at 4 KB; a session body at 16 KB. Larger input is refused unread.
inline constexpr size_t kMaxTermsHeader = 4 << 10;
inline constexpr size_t kMaxTermsBody = 16 << 10;

struct wire {
    float alpha = 0.0f;         // 0 when absent: no boosting
    std::string lines;          // the terms, one per line, ready for parse_terms
};

// base64url (RFC 4648 section 5), padding optional. False on any character outside the alphabet.
inline bool base64url_decode(const std::string & in, std::string & out) {
    out.clear();
    uint32_t acc = 0;
    int bits = 0;
    size_t n = in.size();
    while (n > 0 && in[n - 1] == '=') --n;
    for (size_t i = 0; i < n; ++i) {
        const char c = in[i];
        int v;
        if (c >= 'A' && c <= 'Z') v = c - 'A';
        else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
        else if (c >= '0' && c <= '9') v = c - '0' + 52;
        else if (c == '-') v = 62;
        else if (c == '_') v = 63;
        else return false;
        acc = (acc << 6) | (uint32_t) v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.push_back((char) ((acc >> bits) & 0xFF));
        }
    }
    return true;
}

namespace detail {

inline void skip_ws(const std::string & s, size_t & i) {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) ++i;
}

inline void put_utf8(std::string & o, uint32_t cp) {
    if (cp < 0x80) {
        o.push_back((char) cp);
    } else if (cp < 0x800) {
        o.push_back((char) (0xC0 | (cp >> 6)));
        o.push_back((char) (0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        o.push_back((char) (0xE0 | (cp >> 12)));
        o.push_back((char) (0x80 | ((cp >> 6) & 0x3F)));
        o.push_back((char) (0x80 | (cp & 0x3F)));
    } else {
        o.push_back((char) (0xF0 | (cp >> 18)));
        o.push_back((char) (0x80 | ((cp >> 12) & 0x3F)));
        o.push_back((char) (0x80 | ((cp >> 6) & 0x3F)));
        o.push_back((char) (0x80 | (cp & 0x3F)));
    }
}

inline bool hex4(const std::string & s, size_t i, uint32_t & v) {
    if (i + 4 > s.size()) return false;
    v = 0;
    for (size_t k = 0; k < 4; ++k) {
        const char c = s[i + k];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= (uint32_t) (c - '0');
        else if (c >= 'a' && c <= 'f') v |= (uint32_t) (c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (uint32_t) (c - 'A' + 10);
        else return false;
    }
    return true;
}

// A JSON string starting at s[i] == '"'; i ends one past the closing quote.
inline bool read_string(const std::string & s, size_t & i, std::string & out) {
    out.clear();
    if (i >= s.size() || s[i] != '"') return false;
    ++i;
    while (i < s.size()) {
        const unsigned char c = (unsigned char) s[i++];
        if (c == '"') return true;
        if (c < 0x20) return false;
        if (c != '\\') {
            out.push_back((char) c);
            continue;
        }
        if (i >= s.size()) return false;
        const char e = s[i++];
        switch (e) {
            case '"': out.push_back('"'); break;
            case '\\': out.push_back('\\'); break;
            case '/': out.push_back('/'); break;
            case 'b': out.push_back('\b'); break;
            case 'f': out.push_back('\f'); break;
            case 'n': out.push_back('\n'); break;
            case 'r': out.push_back('\r'); break;
            case 't': out.push_back('\t'); break;
            case 'u': {
                uint32_t cp;
                if (!hex4(s, i, cp)) return false;
                i += 4;
                if (cp >= 0xD800 && cp < 0xDC00) {  // high surrogate: a low one must follow
                    uint32_t lo;
                    if (i + 6 > s.size() || s[i] != '\\' || s[i + 1] != 'u' || !hex4(s, i + 2, lo) || lo < 0xDC00 || lo > 0xDFFF) {
                        return false;
                    }
                    i += 6;
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                    return false;
                }
                put_utf8(out, cp);
                break;
            }
            default: return false;
        }
    }
    return false;  // unterminated
}

}  // namespace detail

// Parses the wire JSON. False (and out untouched) on anything malformed, oversize or of another shape;
// unknown keys are refused too, so a typo cannot silently drop the list.
inline bool parse_wire(const std::string & json, wire & out) {
    if (json.empty() || json.size() > kMaxTermsBody) return false;
    size_t i = 0;
    detail::skip_ws(json, i);
    if (i >= json.size() || json[i] != '{') return false;
    ++i;
    wire w;
    bool have_terms = false;
    detail::skip_ws(json, i);
    if (i < json.size() && json[i] == '}') return false;  // {} carries no list
    for (;;) {
        detail::skip_ws(json, i);
        std::string key;
        if (!detail::read_string(json, i, key)) return false;
        detail::skip_ws(json, i);
        if (i >= json.size() || json[i] != ':') return false;
        ++i;
        detail::skip_ws(json, i);
        if (key == "alpha") {
            size_t j = i;
            while (j < json.size() && (std::isdigit((unsigned char) json[j]) || json[j] == '.' || json[j] == '-' ||
                                       json[j] == '+' || json[j] == 'e' || json[j] == 'E')) {
                ++j;
            }
            if (!parse_alpha(json.substr(i, j - i), w.alpha)) return false;
            i = j;
        } else if (key == "terms") {
            if (have_terms || i >= json.size() || json[i] != '[') return false;
            have_terms = true;
            ++i;
            detail::skip_ws(json, i);
            if (i < json.size() && json[i] == ']') {
                ++i;
            } else {
                for (;;) {
                    detail::skip_ws(json, i);
                    std::string line;
                    if (!detail::read_string(json, i, line)) return false;
                    // one string is one term line: a decoded newline would split it into two terms (and a "# x"
                    // style first field of the second would parse as another term), so such a string is skipped
                    if (line.find_first_of("\n\r") == std::string::npos) {
                        w.lines += line;
                        w.lines += '\n';
                    }
                    detail::skip_ws(json, i);
                    if (i < json.size() && json[i] == ',') {
                        ++i;
                        continue;
                    }
                    if (i < json.size() && json[i] == ']') {
                        ++i;
                        break;
                    }
                    return false;
                }
            }
        } else {
            return false;
        }
        detail::skip_ws(json, i);
        if (i < json.size() && json[i] == ',') {
            ++i;
            continue;
        }
        if (i < json.size() && json[i] == '}') {
            ++i;
            break;
        }
        return false;
    }
    detail::skip_ws(json, i);
    if (i != json.size() || !have_terms) return false;
    out = std::move(w);
    return true;
}

// The X-Ox-Terms header value: size cap, base64url, then the same JSON. False when refused.
inline bool parse_header(const std::string & value, wire & out) {
    if (value.empty() || value.size() > kMaxTermsHeader) return false;
    std::string json;
    return base64url_decode(value, json) && parse_wire(json, out);
}

}  // namespace oxstt::boost
