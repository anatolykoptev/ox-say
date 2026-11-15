// Tests for terms_wire.h: the per-request wire form of the boost list (JSON body, base64url header).
// Plain asserts; every failing check prints its test name and message and the exit status is 1.
#include "terms_wire.h"

#include <cstdio>
#include <string>

using namespace oxstt::boost;

static int failures = 0;
static const char * cur = "";

#define CHECK(cond, msg)                                                            \
    do {                                                                            \
        if (!(cond)) {                                                              \
            fprintf(stderr, "FAIL [%s] %s:%d: %s\n", cur, __FILE__, __LINE__, msg); \
            ++failures;                                                             \
        }                                                                           \
    } while (0)

static std::string b64url(const std::string & s) {
    static const char * k = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    std::string o;
    uint32_t acc = 0;
    int bits = 0;
    for (unsigned char c : s) {
        acc = (acc << 8) | c;
        bits += 8;
        while (bits >= 6) {
            bits -= 6;
            o.push_back(k[(acc >> bits) & 63]);
        }
    }
    if (bits > 0) o.push_back(k[(acc << (6 - bits)) & 63]);
    return o;  // RawURLEncoding: no padding, as Go's base64.RawURLEncoding writes it
}

static void t_base64url() {
    cur = "t_base64url";
    std::string out;
    CHECK(base64url_decode(b64url("{\"a\":\"\xD0\x9E\xD0\xBA\xD1\x81\"}?>"), out) && out == "{\"a\":\"\xD0\x9E\xD0\xBA\xD1\x81\"}?>",
          "round trip with '-' and '_' in the alphabet");
    CHECK(base64url_decode("QQ==", out) && out == "A", "padding is tolerated");
    CHECK(!base64url_decode("QQ+/", out), "standard-alphabet characters are refused");
}

static void t_parse_wire() {
    cur = "t_parse_wire";
    wire w;
    CHECK(parse_wire("{\"alpha\":2,\"terms\":[\"OxSay\\t\\u041e\\u043a\\u0441 \\u0421\\u0435\\u0439\",\"Devin\"]}", w), "valid body parses");
    CHECK(w.alpha == 2.0f, "alpha read");
    CHECK(w.lines == "OxSay\t\xD0\x9E\xD0\xBA\xD1\x81 \xD0\xA1\xD0\xB5\xD0\xB9\nDevin\n", "escapes decoded, one line per term");

    CHECK(parse_wire(" { \"terms\" : [ ] , \"alpha\" : 1.5 } ", w) && w.alpha == 1.5f && w.lines.empty(), "whitespace, empty list, key order");
    CHECK(parse_wire("{\"terms\":[\"\xD0\x9E\xD0\xBA\xD1\x81\"]}", w) && w.alpha == 0.0f, "alpha absent means 0 (no boost)");
    CHECK(parse_wire("{\"alpha\":1,\"terms\":[\"a\\ud83d\\ude00b\"]}", w) && w.lines == "a\xF0\x9F\x98\x80" "b\n", "surrogate pair");

    const char * bad[] = {
        "", "{}", "[]", "{\"terms\":[\"x\"]", "{\"terms\":[\"x\"]}x", "{\"terms\":\"x\"}", "{\"terms\":[1]}",
        "{\"alpha\":1e100,\"terms\":[]}", "{\"alpha\":-1,\"terms\":[]}", "{\"alpha\":\"2\",\"terms\":[]}",
        "{\"alpha\":2}", "{\"alpa\":2,\"terms\":[]}", "{\"terms\":[\"\\ud83d\"]}", "{\"terms\":[\"\\q\"]}",
        "{\"terms\":[\"a\nb\"]}", "{\"terms\":[],\"terms\":[]}", "{\"terms\":[\"x\",]}",
    };
    for (const char * b : bad) {
        wire x;
        x.alpha = 7.0f;
        CHECK(!parse_wire(b, x), b);
        CHECK(x.alpha == 7.0f, "a refused body leaves the output untouched");
    }
    std::string big = "{\"alpha\":2,\"terms\":[\"";
    big.append(kMaxTermsBody, 'a');
    big += "\"]}";
    CHECK(!parse_wire(big, w), "an oversize body is refused unread");
}

static void t_parse_header() {
    cur = "t_parse_header";
    wire w;
    const std::string json = "{\"alpha\":2,\"terms\":[\"OxSay\\t\\u041e\\u043a\\u0441\"]}";
    CHECK(parse_header(b64url(json), w) && w.alpha == 2.0f && w.lines == "OxSay\t\xD0\x9E\xD0\xBA\xD1\x81\n", "header decodes to the same wire");
    CHECK(!parse_header("", w), "an empty header is refused");
    CHECK(!parse_header("!!!!", w), "garbage is refused");
    CHECK(!parse_header(b64url("not json"), w), "valid base64 of non-JSON is refused");
    CHECK(!parse_header(std::string(kMaxTermsHeader + 1, 'A'), w), "an oversize header is refused");
}

int main() {
    t_base64url();
    t_parse_wire();
    t_parse_header();
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
