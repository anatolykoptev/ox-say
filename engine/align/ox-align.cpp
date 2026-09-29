// ox-align: wav2vec2 CTC emissions on ggml — phase 1 of a forced aligner.
//
//   ox-align -m model.gguf -f audio.wav -o emissions.npy
//            [--window 30] [--context 2] [-t threads] [-ng] [--vocab vocab.json] [-v]
//            [--no-normalize] [--dump-dir DIR]
//   ox-align -m model.gguf --info
//
// Reads a 16 kHz mono WAV, runs the wav2vec2 forward pass per --window-second
// window with --context seconds of padding on each side, crops the context
// frames, and writes log-softmax emissions as a float32 .npy [frames, vocab].
// Text normalization and the Viterbi pass are out of scope here.
//
// Matches the HF reference exactly: per-window zero-mean/unit-variance
// normalization (Wav2Vec2FeatureExtractor do_normalize), the (layer|group)
// feature-extractor norm, pre- or post-LN encoder per do_stable_layer_norm, and
// the grouped positional conv embedding with the last frame dropped.

#include "ggml.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "gguf.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

constexpr int SR = 16000;

// ---------------------------------------------------------------------------
// args

struct args {
    std::string model, file, out, vocab, dump_dir;
    int    threads   = 4;
    double window    = 30.0;
    double context   = 2.0;
    bool   gpu       = true;
    bool   verbose   = false;
    bool   normalize = true;
    bool   info      = false;
    // window/context validated to whole 20 ms frames at parse time
    int64_t win_samples = 0, ctx_samples = 0;
};

void usage(const char * argv0) {
    fprintf(stderr,
            "usage: %s -m model.gguf -f audio.wav -o emissions.npy\n"
            "          [--window 30] [--context 2] [-t threads] [-ng] [--vocab vocab.json] [-v]\n"
            "          [--no-normalize] [--dump-dir DIR]\n"
            "       %s -m model.gguf --info\n"
            "audio must be a 16 kHz mono WAV (PCM16 or float32): ffmpeg -i in -ar 16000 -ac 1 out.wav\n"
            "--window/--context must be multiples of 0.02 s (one 320-sample frame),\n"
            "window <= 600 s, context <= 10 s\n",
            argv0, argv0);
}

bool parse(int argc, char ** argv, args & a) {
    for (int i = 1; i < argc; ++i) {
        const std::string k = argv[i];
        auto next = [&](std::string & v) {
            if (i + 1 >= argc) {
                return false;
            }
            v = argv[++i];
            return true;
        };
        std::string v;
        if (k == "-m" || k == "--model") {
            if (!next(a.model)) return false;
        } else if (k == "-f" || k == "--file") {
            if (!next(a.file)) return false;
        } else if (k == "-o" || k == "--out") {
            if (!next(a.out)) return false;
        } else if (k == "--vocab") {
            if (!next(a.vocab)) return false;
        } else if (k == "--window") {
            if (!next(v)) return false;
            a.window = atof(v.c_str());
        } else if (k == "--context") {
            if (!next(v)) return false;
            a.context = atof(v.c_str());
        } else if (k == "-t" || k == "--threads") {
            if (!next(v)) return false;
            a.threads = std::max(1, atoi(v.c_str()));
        } else if (k == "-ng" || k == "--no-gpu") {
            a.gpu = false;
        } else if (k == "--no-normalize") {
            a.normalize = false;
        } else if (k == "--dump-dir") {
            if (!next(a.dump_dir)) return false;
        } else if (k == "--info") {
            a.info = true;
        } else if (k == "-v" || k == "--verbose") {
            a.verbose = true;
        } else {
            fprintf(stderr, "unknown argument: %s\n", k.c_str());
            return false;
        }
    }
    if (a.model.empty() || (!a.info && (a.file.empty() || a.out.empty()))) {
        return false;
    }
    // --window/--context must land on a whole number of 20 ms frames (320
    // samples at 16 kHz): a fraction would emit a silently time-shifted
    // frame per window, and a huge value overflows the sample math. The
    // check runs on the rounded sample count — fp parse noise stays far
    // below one sample — never on the double itself. --context 0 is legal.
    auto arg_frames = [](const char * flag, double sec, double max_s,
                         bool zero_ok, int64_t & n) -> bool {
        if (!std::isfinite(sec) || sec < 0 || (!zero_ok && sec <= 0) || sec > max_s) {
            fprintf(stderr, "ox-align: %s must be a %smultiple of 0.02 s no larger than %g s\n",
                    flag, zero_ok ? "non-negative " : "positive ", max_s);
            return false;
        }
        const double s = sec * SR;
        n = (int64_t) llround(s);
        if (fabs(s - (double) n) > 0.5 || n % (SR / 50) != 0 || (!zero_ok && n == 0)) {
            fprintf(stderr, "ox-align: %s %.9gs does not give a whole number of 20 ms frames\n",
                    flag, sec);
            return false;
        }
        return true;
    };
    if (!arg_frames("--window", a.window, 600.0, false, a.win_samples) ||
        !arg_frames("--context", a.context, 10.0, true, a.ctx_samples)) {
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// WAV reader — identical to engine/stt/ox-stt.cpp (same reader logic on purpose)

uint32_t rd32(const unsigned char * p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t) p[3] << 24; }
uint16_t rd16(const unsigned char * p) { return (uint16_t) (p[0] | p[1] << 8); }

// 16 kHz mono PCM16 or float32 WAV -> float samples
bool read_wav(const std::string & path, std::vector<float> & out, std::string & err) {
    FILE * f = fopen(path.c_str(), "rb");
    if (!f) {
        err = "cannot open " + path;
        return false;
    }
    std::vector<unsigned char> buf;
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
    if (buf.size() < 12 || memcmp(buf.data(), "RIFF", 4) != 0 || memcmp(buf.data() + 8, "WAVE", 4) != 0) {
        err = "not a RIFF/WAVE file";
        return false;
    }
    int fmt = 0, ch = 0, bits = 0;
    uint32_t rate = 0;
    for (size_t off = 12; off + 8 <= buf.size();) {
        const uint32_t len = rd32(&buf[off + 4]);
        const size_t body = off + 8;
        if (body + len > buf.size() && memcmp(&buf[off], "data", 4) != 0) {
            break;
        }
        if (memcmp(&buf[off], "fmt ", 4) == 0 && len >= 16) {
            fmt  = rd16(&buf[body]);
            ch   = rd16(&buf[body + 2]);
            rate = rd32(&buf[body + 4]);
            bits = rd16(&buf[body + 14]);
            if (fmt == 0xFFFE && len >= 26) {  // WAVE_FORMAT_EXTENSIBLE: sub-format code
                fmt = rd16(&buf[body + 24]);
            }
        } else if (memcmp(&buf[off], "data", 4) == 0) {
            if (rate != SR || ch != 1 || !((fmt == 1 && bits == 16) || (fmt == 3 && bits == 32))) {
                err = "need 16 kHz mono PCM16 or float32 (got rate " + std::to_string(rate) + ", channels " +
                      std::to_string(ch) + ", format " + std::to_string(fmt) + "/" + std::to_string(bits) + " bit)";
                return false;
            }
            // a streaming writer leaves the length 0 or 0xFFFFFFFF: take the rest of the file
            const size_t avail = (len == 0 || len == 0xFFFFFFFFu) ? buf.size() - body : std::min<size_t>(len, buf.size() - body);
            // keep only the data chunk while decoding: for long files holding
            // the whole WAV next to the float samples nearly doubles peak RSS
            if (body > 0) {
                memmove(buf.data(), buf.data() + body, avail);
            }
            buf.resize(avail);
            buf.shrink_to_fit();
            if (fmt == 1) {
                out.resize(avail / 2);
                for (size_t i = 0; i < out.size(); ++i) {
                    out[i] = (int16_t) rd16(&buf[2 * i]) / 32768.0f;
                }
            } else {
                out.resize(avail / 4);
                memcpy(out.data(), buf.data(), out.size() * 4);
                for (float v : out) {
                    if (!std::isfinite(v)) {
                        err = "float WAV has non-finite samples";
                        return false;
                    }
                }
            }
            if (out.empty()) {
                err = "no audio samples";
                return false;
            }
            return true;
        }
        off = body + len + (len & 1);
    }
    err = "no data chunk";
    return false;
}

// ---------------------------------------------------------------------------
// model

struct hparams {
    int  n_layer = 0, d = 0, n_head = 0, n_inter = 0, vocab = 0;
    int  pos_k = 0, pos_groups = 1;
    int  n_conv = 0;
    int  conv_k[8] = {}, conv_s[8] = {}, conv_d[8] = {};
    float ln_eps = 1e-5f;
    bool feat_ln_layer = false;  // feat_extract_norm == "layer"
    bool stable_ln     = false;  // do_stable_layer_norm: pre-LN encoder
    bool do_normalize  = true;
    bool conv_bias     = false;
};

struct model {
    gguf_context   * gguf  = nullptr;
    ggml_context   * wctx  = nullptr;   // weight tensors, as stored
    ggml_backend_buffer_t wbuf = nullptr;
    // CPU backend only: f16 matmul weights are stored in the file but upcast to
    // f32 at load — ggml's CPU vec_dot for f16 x f32 rounds the activation to
    // f16 first, which injects ~1e-1 of log-prob noise. On the Metal side the
    // picture depends on the GPU: on the target AMD dGPU, patch 0002 routes
    // eligible 2D mul_mats to MPS in float32 after widening the f16 weights,
    // and the ops it does not take (attention, lm_head) go through mul_mv,
    // whose activations stay f32 — so f16 weights are kept as stored. On
    // Apple Silicon, kernel_mul_mm_* tiles the activations into `half`,
    // which is exactly the rounding the CPU upcast avoids. Twins live in
    // wctx2 (the gguf context has no room for extra tensors).
    ggml_context   * wctx2 = nullptr;
    ggml_backend_buffer_t wbuf2 = nullptr;
    std::unordered_map<std::string, ggml_tensor *> upcast;
    hparams h;
    std::string vocab_json;
};

bool kv_u32(const gguf_context * g, const char * key, int & v) {
    const int64_t id = gguf_find_key(g, key);
    if (id < 0) {
        return false;
    }
    switch (gguf_get_kv_type(g, id)) {
        case GGUF_TYPE_UINT8:  v = gguf_get_val_u8(g, id);  return true;
        case GGUF_TYPE_INT8:   v = gguf_get_val_i8(g, id);  return true;
        case GGUF_TYPE_UINT16: v = gguf_get_val_u16(g, id); return true;
        case GGUF_TYPE_INT16:  v = gguf_get_val_i16(g, id); return true;
        case GGUF_TYPE_UINT32: v = (int) gguf_get_val_u32(g, id); return true;
        case GGUF_TYPE_INT32:  v = gguf_get_val_i32(g, id); return true;
        case GGUF_TYPE_UINT64: v = (int) gguf_get_val_u64(g, id); return true;
        case GGUF_TYPE_INT64:  v = (int) gguf_get_val_i64(g, id); return true;
        default: return false;
    }
}

bool kv_bool(const gguf_context * g, const char * key, bool & v) {
    const int64_t id = gguf_find_key(g, key);
    if (id < 0 || gguf_get_kv_type(g, id) != GGUF_TYPE_BOOL) {
        return false;
    }
    v = gguf_get_val_bool(g, id);
    return true;
}

bool kv_f32(const gguf_context * g, const char * key, float & v) {
    const int64_t id = gguf_find_key(g, key);
    if (id < 0) {
        return false;
    }
    switch (gguf_get_kv_type(g, id)) {
        case GGUF_TYPE_FLOAT32: v = gguf_get_val_f32(g, id); return true;
        case GGUF_TYPE_FLOAT64: v = (float) gguf_get_val_f64(g, id); return true;
        default: return false;
    }
}

bool kv_str(const gguf_context * g, const char * key, std::string & v) {
    const int64_t id = gguf_find_key(g, key);
    if (id < 0 || gguf_get_kv_type(g, id) != GGUF_TYPE_STRING) {
        return false;
    }
    v = gguf_get_val_str(g, id);
    return true;
}

// int array (any int element type): returns the element count, -1 on failure
int kv_ints(const gguf_context * g, const char * key, int * out, int cap) {
    const int64_t id = gguf_find_key(g, key);
    if (id < 0 || gguf_get_kv_type(g, id) != GGUF_TYPE_ARRAY) {
        return -1;
    }
    const enum gguf_type t = gguf_get_arr_type(g, id);
    const size_t         m = gguf_get_arr_n(g, id);
    const void *         p = gguf_get_arr_data(g, id);
    if ((int) m > cap) {
        return -1;
    }
    const int n = (int) m;
    for (int i = 0; i < n; ++i) {
        switch (t) {
            case GGUF_TYPE_UINT8:  out[i] = ((const uint8_t  *) p)[i]; break;
            case GGUF_TYPE_INT8:   out[i] = ((const int8_t   *) p)[i]; break;
            case GGUF_TYPE_UINT16: out[i] = ((const uint16_t *) p)[i]; break;
            case GGUF_TYPE_INT16:  out[i] = ((const int16_t  *) p)[i]; break;
            case GGUF_TYPE_UINT32: out[i] = (int) ((const uint32_t *) p)[i]; break;
            case GGUF_TYPE_INT32:  out[i] = ((const int32_t  *) p)[i]; break;
            case GGUF_TYPE_UINT64: out[i] = (int) ((const uint64_t *) p)[i]; break;
            case GGUF_TYPE_INT64:  out[i] = (int) ((const int64_t  *) p)[i]; break;
            default: return -1;
        }
    }
    return n;
}

ggml_tensor * need(const model & m, const std::string & name) {
    const auto it = m.upcast.find(name);
    ggml_tensor * t = it != m.upcast.end() ? it->second
                                         : ggml_get_tensor(m.wctx, name.c_str());
    if (!t) {
        fprintf(stderr, "ox-align: model is missing tensor %s\n", name.c_str());
        exit(1);
    }
    return t;
}

ggml_tensor * maybe(const model & m, const std::string & name) {
    const auto it = m.upcast.find(name);
    if (it != m.upcast.end()) {
        return it->second;
    }
    return ggml_get_tensor(m.wctx, name.c_str());
}

bool load_model(const std::string & path, model & m, ggml_backend_t backend,
                bool upcast_f16, bool meta_only, std::string & err) {
    struct gguf_init_params params = { /*no_alloc =*/ true, /*ctx =*/ &m.wctx };
    m.gguf = gguf_init_from_file(path.c_str(), params);
    if (!m.gguf || !m.wctx) {
        err = "cannot read " + path;
        return false;
    }
    hparams & h = m.h;
    std::string norm;
    if (!kv_str(m.gguf, "wav2vec2.feat_extract_norm", norm) ||
        (norm != "layer" && norm != "group") ||
        !kv_u32(m.gguf, "wav2vec2.hidden_size", h.d) ||
        !kv_u32(m.gguf, "wav2vec2.num_hidden_layers", h.n_layer) ||
        !kv_u32(m.gguf, "wav2vec2.num_attention_heads", h.n_head) ||
        !kv_u32(m.gguf, "wav2vec2.intermediate_size", h.n_inter) ||
        !kv_u32(m.gguf, "wav2vec2.vocab_size", h.vocab) ||
        !kv_u32(m.gguf, "wav2vec2.num_conv_pos_embeddings", h.pos_k) ||
        !kv_u32(m.gguf, "wav2vec2.num_conv_pos_embedding_groups", h.pos_groups) ||
        !kv_bool(m.gguf, "wav2vec2.do_stable_layer_norm", h.stable_ln) ||
        !kv_bool(m.gguf, "wav2vec2.do_normalize", h.do_normalize) ||
        !kv_bool(m.gguf, "wav2vec2.conv_bias", h.conv_bias) ||
        !kv_f32(m.gguf, "wav2vec2.layer_norm_eps", h.ln_eps)) {
        err = path + " is not a wav2vec2 GGUF from convert_wav2vec2.py";
        return false;
    }
    h.feat_ln_layer = norm == "layer";
    // every hyperparameter is validated before it divides, modulos or indexes
    // anything — a zero here is SIGFPE on x86 and silent garbage on ARM
    {
        const struct { const char * key; int v; } pos[] = {
            {"hidden_size", h.d}, {"num_hidden_layers", h.n_layer},
            {"num_attention_heads", h.n_head}, {"intermediate_size", h.n_inter},
            {"vocab_size", h.vocab}, {"num_conv_pos_embeddings", h.pos_k},
            {"num_conv_pos_embedding_groups", h.pos_groups},
        };
        for (const auto & e : pos) {
            if (e.v <= 0) {
                err = std::string("wav2vec2.") + e.key + " must be > 0 in " + path;
                return false;
            }
        }
        if (h.d % h.n_head != 0) {
            err = "wav2vec2.hidden_size is not divisible by wav2vec2.num_attention_heads";
            return false;
        }
        if (h.d % h.pos_groups != 0) {
            err = "wav2vec2.hidden_size is not divisible by wav2vec2.num_conv_pos_embedding_groups";
            return false;
        }
    }
    h.n_conv = kv_ints(m.gguf, "wav2vec2.conv_kernel", h.conv_k, 8);
    if (h.n_conv <= 0) {
        err = "wav2vec2.conv_kernel is missing or empty in " + path;
        return false;
    }
    if (kv_ints(m.gguf, "wav2vec2.conv_stride", h.conv_s, 8) != h.n_conv ||
        kv_ints(m.gguf, "wav2vec2.conv_dim", h.conv_d, 8) != h.n_conv) {
        err = "wav2vec2.conv_stride/conv_dim length != conv_kernel in " + path;
        return false;
    }
    for (int i = 0; i < h.n_conv; ++i) {
        char bad[96];
        if (h.conv_k[i] <= 0) {
            snprintf(bad, sizeof(bad), "wav2vec2.conv_kernel[%d] must be > 0", i);
            err = std::string(bad) + " in " + path;
            return false;
        }
        if (h.conv_s[i] <= 0) {
            snprintf(bad, sizeof(bad), "wav2vec2.conv_stride[%d] must be > 0", i);
            err = std::string(bad) + " in " + path;
            return false;
        }
        if (h.conv_d[i] <= 0) {
            snprintf(bad, sizeof(bad), "wav2vec2.conv_dim[%d] must be > 0", i);
            err = std::string(bad) + " in " + path;
            return false;
        }
    }
    // one pass over every tensor the forward pass touches: a wrong shape is a
    // clean error naming the tensor and both shapes, never a ggml assert.
    // (conv.bias existence vs wav2vec2.conv_bias is enforced in build_forward,
    //  where the bias is consumed.)
    {
        auto shape = [&](const std::string & name,
                         std::initializer_list<int64_t> want) -> bool {
            ggml_tensor * t = ggml_get_tensor(m.wctx, name.c_str());
            if (!t) {
                err = "model is missing tensor " + name;
                return false;
            }
            bool bad = ggml_n_dims(t) != (int) want.size();
            size_t i = 0;
            for (int64_t w : want) {
                bad = bad || t->ne[i++] != w;
            }
            if (bad) {
                char got[80] = {0}, exp[80] = {0};
                for (int j = 0; j < ggml_n_dims(t); ++j) {
                    snprintf(got + strlen(got), sizeof(got) - strlen(got),
                             "%s%lld", j ? "," : "", (long long) t->ne[j]);
                }
                for (int64_t w : want) {
                    snprintf(exp + strlen(exp), sizeof(exp) - strlen(exp),
                             "%s%lld", exp[0] ? "," : "", (long long) w);
                }
                err = name + " has shape [" + got + "], expected [" + exp + "]";
                return false;
            }
            return true;
        };
        const int64_t d = h.d;
        for (int i = 0; i < h.n_conv; ++i) {
            char name[128];
            snprintf(name, sizeof(name), "feature_extractor.conv_layers.%d.conv.weight", i);
            // conv weight arrives as ggml [K, IC, OC] (HF [OC, IC, K] reinterpreted)
            if (!shape(name, {h.conv_k[i], i > 0 ? h.conv_d[i - 1] : 1, h.conv_d[i]})) {
                return false;
            }
            snprintf(name, sizeof(name), "feature_extractor.conv_layers.%d.conv.bias", i);
            if (ggml_get_tensor(m.wctx, name) && !shape(name, {h.conv_d[i]})) {
                return false;
            }
            if (h.feat_ln_layer || i == 0) {
                snprintf(name, sizeof(name), "feature_extractor.conv_layers.%d.layer_norm.weight", i);
                if (!shape(name, {h.conv_d[i]})) {
                    return false;
                }
                snprintf(name, sizeof(name), "feature_extractor.conv_layers.%d.layer_norm.bias", i);
                if (!shape(name, {h.conv_d[i]})) {
                    return false;
                }
            }
        }
        if (!shape("feature_projection.layer_norm.weight", {h.conv_d[h.n_conv - 1]}) ||
            !shape("feature_projection.layer_norm.bias", {h.conv_d[h.n_conv - 1]}) ||
            !shape("feature_projection.projection.weight", {h.conv_d[h.n_conv - 1], d}) ||
            !shape("feature_projection.projection.bias", {d}) ||
            !shape("encoder.pos_conv_embed.conv.weight", {h.pos_k, d / h.pos_groups, d}) ||
            !shape("encoder.pos_conv_embed.conv.bias", {d}) ||
            !shape("encoder.layer_norm.weight", {d}) ||
            !shape("encoder.layer_norm.bias", {d}) ||
            !shape("lm_head.weight", {d, (int64_t) h.vocab}) ||
            !shape("lm_head.bias", {(int64_t) h.vocab})) {
            return false;
        }
        for (int i = 0; i < h.n_layer; ++i) {
            char base[128];
            snprintf(base, sizeof(base), "encoder.layers.%d.", i);
            const std::string b = base;
            const int64_t ni = h.n_inter;
            if (!shape(b + "attention.q_proj.weight", {d, d}) ||
                !shape(b + "attention.q_proj.bias", {d}) ||
                !shape(b + "attention.k_proj.weight", {d, d}) ||
                !shape(b + "attention.k_proj.bias", {d}) ||
                !shape(b + "attention.v_proj.weight", {d, d}) ||
                !shape(b + "attention.v_proj.bias", {d}) ||
                !shape(b + "attention.out_proj.weight", {d, d}) ||
                !shape(b + "attention.out_proj.bias", {d}) ||
                !shape(b + "layer_norm.weight", {d}) ||
                !shape(b + "layer_norm.bias", {d}) ||
                !shape(b + "final_layer_norm.weight", {d}) ||
                !shape(b + "final_layer_norm.bias", {d}) ||
                !shape(b + "feed_forward.intermediate_dense.weight", {d, ni}) ||
                !shape(b + "feed_forward.intermediate_dense.bias", {ni}) ||
                !shape(b + "feed_forward.output_dense.weight", {ni, d}) ||
                !shape(b + "feed_forward.output_dense.bias", {d})) {
                return false;
            }
        }
    }
    kv_str(m.gguf, "wav2vec2.vocab_json", m.vocab_json);

    if (meta_only) {
        return true;   // --info: no backend buffers, no tensor data
    }

    if (upcast_f16) {
        // unnamed f32 twins shadow the stored f16 tensors (see struct model)
        int64_t n_up = 0;
        for (int64_t i = 0; i < gguf_get_n_tensors(m.gguf); ++i) {
            ggml_tensor * t = ggml_get_tensor(m.wctx, gguf_get_tensor_name(m.gguf, i));
            if (t && t->type == GGML_TYPE_F16) {
                ++n_up;
            }
        }
        if (n_up > 0) {
            const struct ggml_init_params ip = {
                /*mem_size   =*/ (size_t) n_up * ggml_tensor_overhead(),
                /*mem_buffer =*/ nullptr,
                /*no_alloc   =*/ true,
            };
            m.wctx2 = ggml_init(ip);
            if (!m.wctx2) {
                err = "out of memory";
                return false;
            }
            for (int64_t i = 0; i < gguf_get_n_tensors(m.gguf); ++i) {
                const char *  name = gguf_get_tensor_name(m.gguf, i);
                ggml_tensor * t    = ggml_get_tensor(m.wctx, name);
                if (t && t->type == GGML_TYPE_F16) {
                    m.upcast.emplace(name, ggml_new_tensor(m.wctx2, GGML_TYPE_F32,
                                                         ggml_n_dims(t), t->ne));
                }
            }
        }
    }

    if (m.upcast.empty()) {
        m.wbuf = ggml_backend_alloc_ctx_tensors(m.wctx, backend);
    } else {
        // the f16 originals are shadowed by their f32 twins and are never
        // touched again — backing them too would park ~half a copy of the
        // model in RAM (or VRAM) for nothing
        ggml_backend_buffer_type_t buft = ggml_backend_get_default_buffer_type(backend);
        const size_t align = ggml_backend_buft_get_alignment(buft);
        size_t size = 0;
        for (int64_t i = 0; i < gguf_get_n_tensors(m.gguf); ++i) {
            const char *  name = gguf_get_tensor_name(m.gguf, i);
            ggml_tensor * t    = ggml_get_tensor(m.wctx, name);
            if (t && !m.upcast.count(name)) {
                size += (ggml_backend_buft_get_alloc_size(buft, t) + align - 1) / align * align;
            }
        }
        m.wbuf = size ? ggml_backend_buft_alloc_buffer(buft, size) : nullptr;
        if (m.wbuf) {
            ggml_tallocr talloc = ggml_tallocr_new(m.wbuf);
            for (int64_t i = 0; i < gguf_get_n_tensors(m.gguf); ++i) {
                const char *  name = gguf_get_tensor_name(m.gguf, i);
                ggml_tensor * t    = ggml_get_tensor(m.wctx, name);
                if (t && !m.upcast.count(name) &&
                    ggml_tallocr_alloc(&talloc, t) != GGML_STATUS_SUCCESS) {
                    ggml_backend_buffer_free(m.wbuf);
                    m.wbuf = nullptr;
                    err = std::string("failed to allocate tensor ") + name;
                    return false;
                }
            }
        }
    }
    if (!m.wbuf || (m.wctx2 && !(m.wbuf2 = ggml_backend_alloc_ctx_tensors(m.wctx2, backend)))) {
        err = "failed to allocate model tensors";
        return false;
    }
    FILE * f = fopen(path.c_str(), "rb");
    if (!f) {
        err = "cannot reopen " + path;
        return false;
    }
    const size_t base = gguf_get_data_offset(m.gguf);
    std::vector<unsigned char> buf(1 << 22);
    std::vector<float> f32buf;
    const int64_t n_t = gguf_get_n_tensors(m.gguf);
    for (int64_t i = 0; i < n_t; ++i) {
        const char *  name = gguf_get_tensor_name(m.gguf, i);
        const size_t  size = gguf_get_tensor_size(m.gguf, i);
        const auto    it   = m.upcast.find(name);
        ggml_tensor * t    = it != m.upcast.end() ? it->second
                                                : ggml_get_tensor(m.wctx, name);
        const bool up = it != m.upcast.end();
        if (!t || ggml_nbytes(t) != (up ? size * 2 : size)) {
            fclose(f);
            err = std::string("tensor size mismatch: ") + name;
            return false;
        }
        if (fseek(f, (long) (base + gguf_get_tensor_offset(m.gguf, i)), SEEK_SET) != 0) {
            fclose(f);
            err = std::string("cannot seek to tensor ") + name;
            return false;
        }
        if (up) {
            // f16 -> f32 twin: convert in one pass (tensors are <= ~50 MB)
            f32buf.resize(size / 2);
            std::vector<ggml_fp16_t> raw(size / 2);
            if (fread(raw.data(), 1, size, f) != size) {
                fclose(f);
                err = std::string("short read on tensor ") + name;
                return false;
            }
            ggml_fp16_to_fp32_row(raw.data(), f32buf.data(), (int64_t) (size / 2));
            ggml_backend_tensor_set(t, f32buf.data(), 0, size * 2);
            continue;
        }
        size_t off = 0;
        while (off < size) {
            const size_t want = std::min(buf.size(), size - off);
            if (fread(buf.data(), 1, want, f) != want) {
                fclose(f);
                err = std::string("short read on tensor ") + name;
                return false;
            }
            ggml_backend_tensor_set(t, buf.data(), off, want);
            off += want;
        }
    }
    fclose(f);
    return true;
}

// ---------------------------------------------------------------------------
// graph — hidden states are [d, T] (ne0 = channel); conv activations are
// [L, C] (ne0 = time, the conv spatial axis).

struct layer_w {
    ggml_tensor *q_w, *q_b, *k_w, *k_b, *v_w, *v_b, *o_w, *o_b;
    ggml_tensor *ln_w, *ln_b;                      // layer_norm
    ggml_tensor *fln_w, *fln_b;                    // final_layer_norm
    ggml_tensor *i_w, *i_b, *o2_w, *o2_b;          // feed_forward dense pair
};

// y = LN(x) * w + b; x [d, T] is normalized over d = ne0
ggml_tensor * layer_norm(ggml_context * g, ggml_tensor * x, ggml_tensor * w,
                         ggml_tensor * b, float eps) {
    x = ggml_norm(g, x, eps);
    x = ggml_mul(g, x, ggml_reshape_2d(g, w, w->ne[0], 1));
    x = ggml_add(g, x, ggml_reshape_2d(g, b, b->ne[0], 1));
    return x;
}

// y = W x + b; an HF Linear weight [out, in] is ggml [in, out] for mul_mat
ggml_tensor * linear(ggml_context * g, ggml_tensor * x, ggml_tensor * w,
                     ggml_tensor * b) {
    x = ggml_mul_mat(g, w, x);
    if (b) {
        x = ggml_add(g, x, ggml_reshape_2d(g, b, b->ne[0], 1));
    }
    return x;
}

// conv1d(x [L, C], w [K, IC, OC], stride) -> [L', OC]
// The pinned ggml has no Metal kernel for ggml_conv_1d, and plain
// ggml_conv_2d decomposes into im2col + mul_mat with an F16 patch buffer
// (hardcoded dtype: BF16 kernel -> F32, otherwise F16), which loses ~2 bits of
// mantissa that the 2e-3 log-prob oracle cannot afford. ggml_conv_2d_direct is
// the real CONV_2D op — a native conv on Metal and an F32 im2col + F32 GEMM on
// the CPU backend — so 1D convs run through it with a unit H axis.
ggml_tensor * conv1d(ggml_context * g, ggml_tensor * x, ggml_tensor * w,
                     ggml_tensor * b, int stride, int pad) {
    const int64_t l = x->ne[0];
    ggml_tensor * x4 = ggml_reshape_4d(g, x, l, 1, ggml_nelements(x) / l, 1);
    ggml_tensor * w4 = ggml_reshape_4d(g, w, w->ne[0], 1, w->ne[1], w->ne[2]);
    // unit-H axes still need legal stride/dilation: s=0 divides by zero in
    // ggml_calc_conv_output_size (silent on ARM, SIGFPE on x86)
    ggml_tensor * y  = ggml_conv_2d_direct(g, w4, x4, stride, 1, pad, 0, 1, 1);
    y = ggml_reshape_2d(g, y, y->ne[0], y->ne[2]);
    if (b) {
        y = ggml_add(g, y, ggml_reshape_2d(g, b, 1, b->ne[0]));
    }
    return y;
}

// multi-head self-attention on x [d, T]
ggml_tensor * mha(ggml_context * g, const hparams & h, const layer_w & l,
                  ggml_tensor * x, int64_t T) {
    const int64_t hd = h.d / h.n_head;
    ggml_tensor * q = linear(g, x, l.q_w, l.q_b);
    ggml_tensor * k = linear(g, x, l.k_w, l.k_b);
    ggml_tensor * v = linear(g, x, l.v_w, l.v_b);

    // Q/K -> [hd, T, n_head] views; V -> a contiguous [T, hd, n_head] tensor:
    // same shapes whisper.cpp uses for its non-flash attention path, and
    // mul_mat requires its first operand to be non-transposed, which the
    // permuted V view would violate (nb[0] > nb[1])
    ggml_tensor * Q = ggml_permute(g, ggml_reshape_3d(g, q, hd, h.n_head, T), 0, 2, 1, 3);
    ggml_tensor * K = ggml_permute(g, ggml_reshape_3d(g, k, hd, h.n_head, T), 0, 2, 1, 3);
    ggml_tensor * V = ggml_cont(g, ggml_permute(g, ggml_reshape_3d(g, v, hd, h.n_head, T), 1, 2, 0, 3));

    // scores [T, T, n_head], softmax over the key axis = ne0
    ggml_tensor * s = ggml_mul_mat(g, K, Q);
    s = ggml_soft_max_ext(g, s, nullptr, 1.0f / sqrtf((float) hd), 0.0f);

    ggml_tensor * av = ggml_mul_mat(g, V, s);                       // [hd, T, n_head]
    ggml_tensor * merged = ggml_cont_2d(g, ggml_permute(g, av, 0, 2, 1, 3), h.d, T);

    return linear(g, merged, l.o_w, l.o_b);
}

ggml_tensor * ffn(ggml_context * g, const layer_w & l, ggml_tensor * x) {
    x = linear(g, x, l.i_w, l.i_b);
    x = ggml_gelu_erf(g, x);   // HF hidden_act == "gelu" (erf, not the tanh approximation)
    x = linear(g, x, l.o2_w, l.o2_b);
    return x;
}

// debug: --dump-dir DIR writes the named stage outputs as .npy files.
// An env var would silently write ~250 MB per call when inherited; an
// explicit flag cannot be set by accident.
std::vector<std::pair<std::string, ggml_tensor *>> g_dump;
std::string g_dump_dir;

void dump_tag(const char * name, ggml_tensor * t) {
    if (!g_dump_dir.empty()) {
        g_dump.emplace_back(name, t);
        ggml_set_output(t);   // pin the buffer: without this the allocator reuses it
    }
}

// full forward: input [slice] raw samples -> log-softmax emissions [vocab, keep]
ggml_tensor * build_forward(ggml_context * g, const model & m, ggml_tensor * input,
                            int64_t T, int64_t crop, int64_t keep) {
    const hparams & h = m.h;

    // --- feature extractor: conv1d stack on [L, C] ---
    ggml_tensor * x = input;
    for (int i = 0; i < h.n_conv; ++i) {
        char name[128];
        snprintf(name, sizeof(name), "feature_extractor.conv_layers.%d.conv.weight", i);
        ggml_tensor * w = need(m, name);
        snprintf(name, sizeof(name), "feature_extractor.conv_layers.%d.conv.bias", i);
        // conv_bias is honoured here, at the point of use: required when the
        // flag says the checkpoint has biases, an error when it says it must
        // not — a stray bias would otherwise silently shift the logits
        ggml_tensor * cb = h.conv_bias ? need(m, name) : maybe(m, name);
        if (!h.conv_bias && cb) {
            fprintf(stderr, "ox-align: %s present but wav2vec2.conv_bias is false\n", name);
            exit(1);
        }
        x = conv1d(g, x, w, cb, h.conv_s[i], 0);
        if (i == 0) {
            dump_tag("conv0_pre", x);
        }
        if (h.feat_ln_layer) {
            // LayerNorm over channels: norm needs the channel axis as ne0.
            // HF builds this as nn.LayerNorm(out_conv_dim) with no eps — the
            // 1e-5 default, not config.layer_norm_eps (transformers
            // Wav2Vec2LayerNormConvLayer, modeling_wav2vec2.py:291).
            snprintf(name, sizeof(name), "feature_extractor.conv_layers.%d.layer_norm.weight", i);
            ggml_tensor * lw = need(m, name);
            snprintf(name, sizeof(name), "feature_extractor.conv_layers.%d.layer_norm.bias", i);
            ggml_tensor * lb = need(m, name);
            x = ggml_cont(g, ggml_permute(g, x, 1, 0, 2, 3));   // [C, L']
            x = layer_norm(g, x, lw, lb, 1e-5f);
            x = ggml_cont(g, ggml_permute(g, x, 1, 0, 2, 3));   // back to [L', C]
        } else if (i == 0) {
            // feat_extract_norm == "group": GroupNorm(C, C) on conv 0 only, i.e.
            // each channel normalized over time = ggml_norm over ne0 per column
            ggml_tensor * lw = need(m, "feature_extractor.conv_layers.0.layer_norm.weight");
            ggml_tensor * lb = need(m, "feature_extractor.conv_layers.0.layer_norm.bias");
            x = ggml_norm(g, x, 1e-5f);   // torch.nn.GroupNorm default eps
            x = ggml_mul(g, x, ggml_reshape_2d(g, lw, 1, lw->ne[0]));
            x = ggml_add(g, x, ggml_reshape_2d(g, lb, 1, lb->ne[0]));
        }
        x = ggml_gelu_erf(g, x);
        if (i == 0 || i == 3) {
            dump_tag(i == 0 ? "conv0" : "conv3", x);
        }
    }
    dump_tag("feat", x);   // [L', C] (ne0 = time)

    // --- feature projection: LN over channels, then Linear -> [d, T] ---
    {
        ggml_tensor * lw = need(m, "feature_projection.layer_norm.weight");
        ggml_tensor * lb = need(m, "feature_projection.layer_norm.bias");
        x = ggml_cont(g, ggml_permute(g, x, 1, 0, 2, 3));       // [C, T]
        x = layer_norm(g, x, lw, lb, h.ln_eps);
        x = linear(g, x, need(m, "feature_projection.projection.weight"),
                   need(m, "feature_projection.projection.bias"));
    }
    dump_tag("proj", x);   // [d, T] (ne0 = channel)

    // --- positional conv embedding ---
    // grouped conv1d, k = pos_k, pos_groups groups, padding k/2, drop the last
    // frame (HF SamePadLayer), GELU, add to the hidden states.
    // ggml has no grouped conv1d — and conv_2d (the conv variant Metal
    // supports) has no groups either — so the G groups run as G narrow convs
    // on channel slices joined by concat. Chosen over im2col + a batched
    // mul_mat because a plain conv_2d lets each backend pick its own conv
    // kernel path and the cost is trivial: pos_groups convs of
    // [T, d/groups] x [k, d/groups, d/groups] once per window.
    {
        const int cg = h.d / h.pos_groups;   // in/out channels per group
        ggml_tensor * pw = need(m, "encoder.pos_conv_embed.conv.weight");  // [K, cg, d]
        ggml_tensor * pb = need(m, "encoder.pos_conv_embed.conv.bias");
        ggml_tensor * xc = ggml_cont(g, ggml_permute(g, x, 1, 0, 2, 3));
        xc = ggml_reshape_4d(g, xc, T, 1, h.d, 1);              // [T, 1, d, 1]
        ggml_tensor * acc = nullptr;
        for (int gi = 0; gi < h.pos_groups; ++gi) {
            ggml_tensor * xv = ggml_view_4d(g, xc, T, 1, cg, 1,
                                            xc->nb[1], xc->nb[2], xc->nb[3],
                                            (size_t) gi * cg * T * ggml_element_size(xc));
            xv = ggml_cont(g, xv);
            // kernel group slice [K, 1, cg, cg]: slicing the outermost OC axis
            // keeps the view contiguous (OC stride == K*cg*element already)
            ggml_tensor * wg = ggml_view_4d(g, pw, pw->ne[0], 1, cg, cg,
                                            pw->nb[1], pw->nb[1], pw->nb[2],
                                            (size_t) gi * cg * pw->nb[2]);
            ggml_tensor * y = ggml_conv_2d_direct(g, wg, xv, 1, 1, h.pos_k / 2, 0, 1, 1);  // [T+1, 1, cg, 1]
            acc = acc ? ggml_concat(g, acc, y, 2) : y;
        }
        acc = ggml_view_4d(g, acc, T, 1, h.d, 1, acc->nb[1], acc->nb[2], acc->nb[3], 0);  // drop last frame
        acc = ggml_cont(g, ggml_permute(g, acc, 2, 0, 1, 3));   // [d, T]
        acc = ggml_reshape_2d(g, acc, h.d, T);
        acc = ggml_add(g, acc, ggml_reshape_2d(g, pb, pb->ne[0], 1));
        acc = ggml_gelu_erf(g, acc);
        x = ggml_add(g, x, acc);
    }
    dump_tag("posemb", x);   // [d, T] hidden states + pos embedding

    if (!h.stable_ln) {
        // post-LN encoder: encoder.layer_norm right after the pos embedding
        x = layer_norm(g, x, need(m, "encoder.layer_norm.weight"),
                       need(m, "encoder.layer_norm.bias"), h.ln_eps);
    }

    for (int i = 0; i < h.n_layer; ++i) {
        char base[128];
        snprintf(base, sizeof(base), "encoder.layers.%d.", i);
        layer_w l;
        auto t = [&](const char * sub) { return need(m, std::string(base) + sub); };
        l.q_w = t("attention.q_proj.weight");      l.q_b = t("attention.q_proj.bias");
        l.k_w = t("attention.k_proj.weight");      l.k_b = t("attention.k_proj.bias");
        l.v_w = t("attention.v_proj.weight");      l.v_b = t("attention.v_proj.bias");
        l.o_w = t("attention.out_proj.weight");    l.o_b = t("attention.out_proj.bias");
        l.ln_w = t("layer_norm.weight");           l.ln_b = t("layer_norm.bias");
        l.fln_w = t("final_layer_norm.weight");    l.fln_b = t("final_layer_norm.bias");
        l.i_w = t("feed_forward.intermediate_dense.weight");
        l.i_b = t("feed_forward.intermediate_dense.bias");
        l.o2_w = t("feed_forward.output_dense.weight");
        l.o2_b = t("feed_forward.output_dense.bias");

        if (h.stable_ln) {
            // pre-LN: h += attn(LN(h)); h += ffn(final_LN(h))
            x = ggml_add(g, x, mha(g, h, l, layer_norm(g, x, l.ln_w, l.ln_b, h.ln_eps), T));
            x = ggml_add(g, x, ffn(g, l, layer_norm(g, x, l.fln_w, l.fln_b, h.ln_eps)));
        } else {
            // post-LN: h = LN(h + attn(h)); h = final_LN(h + ffn(h))
            x = layer_norm(g, ggml_add(g, x, mha(g, h, l, x, T)), l.ln_w, l.ln_b, h.ln_eps);
            x = layer_norm(g, ggml_add(g, x, ffn(g, l, x)), l.fln_w, l.fln_b, h.ln_eps);
        }
        if (i == 0 || i == 5 || i == 11) {
            char tn[32];
            snprintf(tn, sizeof(tn), "enc_l%d", i);
            dump_tag(tn, x);
        }
    }

    if (h.stable_ln) {
        // pre-LN encoder: encoder.layer_norm after the last layer
        x = layer_norm(g, x, need(m, "encoder.layer_norm.weight"),
                       need(m, "encoder.layer_norm.bias"), h.ln_eps);
    }
    dump_tag("enc", x);   // [d, T] encoder output

    // lm_head -> [vocab, T]; crop the context frames; log-softmax over vocab.
    // The crop view of dim1 of a contiguous [vocab, T] tensor is itself
    // contiguous (row stride stays vocab), so softmax/log see dense rows.
    x = linear(g, x, need(m, "lm_head.weight"), need(m, "lm_head.bias"));
    x = ggml_view_2d(g, x, h.vocab, keep, x->nb[1],
                     (size_t) crop * x->nb[1]);
    x = ggml_log(g, ggml_soft_max(g, x));
    return x;
}

// ---------------------------------------------------------------------------
// .npy v1.0 writer (float32, C order)

// Write-or-nothing: content goes to <path>.tmp and is renamed over <path> only
// on success, so a crash or a full disk never leaves a truncated emissions
// file under the final name. fclose runs exactly once and is checked; any
// failure removes the .tmp file and reports a non-zero exit.
bool commit_file(FILE * f, bool ok, const std::string & tmp, const std::string & path,
                 std::string & err) {
    if (fclose(f) != 0) {
        ok = false;
    }
    if (ok && rename(tmp.c_str(), path.c_str()) != 0) {
        ok = false;
    }
    if (!ok) {
        remove(tmp.c_str());
        err = "write failed on " + path;
    }
    return ok;
}

bool write_npy(const std::string & path, const float * data, int64_t rows, int64_t cols,
               std::string & err) {
    char dict[128];
    const int n = snprintf(dict, sizeof(dict),
                           "{'descr': '<f4', 'fortran_order': False, 'shape': (%lld, %lld), }",
                           (long long) rows, (long long) cols);
    // header: magic(6) + ver(2) + hlen(2) + dict, the whole header padded to 64
    const int pad = (int) (64 - ((10 + n + 1) % 64));
    const uint16_t hlen = (uint16_t) (n + pad + 1);
    const std::string tmp = path + ".tmp";
    FILE * f = fopen(tmp.c_str(), "wb");
    if (!f) {
        err = "cannot write " + tmp;
        return false;
    }
    bool ok = fwrite("\x93NUMPY\x01\x00", 1, 8, f) == 8 &&
              fwrite(&hlen, 2, 1, f) == 1 &&
              fwrite(dict, 1, (size_t) n, f) == (size_t) n;
    for (int i = 0; ok && i < pad; ++i) {
        ok = fwrite(" ", 1, 1, f) == 1;
    }
    ok = ok && fwrite("\n", 1, 1, f) == 1;
    ok = ok && fwrite(data, 4, (size_t) rows * cols, f) == (size_t) rows * cols;
    return commit_file(f, ok, tmp, path, err);
}

// ---------------------------------------------------------------------------
// vocab.json (flat {"token": id}) -> {"id": "token"}

bool parse_json_string(const std::string & s, size_t & i, std::string & out) {
    if (i >= s.size() || s[i] != '"') {
        return false;
    }
    ++i;
    while (i < s.size()) {
        const unsigned char c = (unsigned char) s[i];
        if (c == '"') {
            ++i;
            return true;
        }
        if (c == '\\') {
            if (++i >= s.size()) {
                return false;
            }
            switch (s[i]) {
                case '"': case '\\': case '/': out += s[i]; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    auto hex4 = [&]() -> int {
                        // -1 on failure; leaves i on the last hex digit
                        if (i + 4 >= s.size()) {
                            return -1;
                        }
                        int cp = 0;
                        for (int j = 0; j < 4; ++j) {
                            const char ch = s[++i];
                            const int v = (ch >= '0' && ch <= '9') ? ch - '0' :
                                          (ch >= 'a' && ch <= 'f') ? ch - 'a' + 10 :
                                          (ch >= 'A' && ch <= 'F') ? ch - 'A' + 10 : -1;
                            if (v < 0) {
                                return -1;
                            }
                            cp = cp << 4 | v;
                        }
                        return cp;
                    };
                    const int hi = hex4();
                    if (hi < 0) {
                        return false;
                    }
                    unsigned cp;
                    if (hi >= 0xD800 && hi <= 0xDBFF) {
                        // a high surrogate must be followed by a low one
                        if (i + 2 >= s.size() || s[i + 1] != '\\' || s[i + 2] != 'u') {
                            return false;
                        }
                        i += 2;
                        const int lo = hex4();
                        if (lo < 0xDC00 || lo > 0xDFFF) {
                            return false;
                        }
                        cp = 0x10000 + ((unsigned) (hi - 0xD800) << 10) + (unsigned) (lo - 0xDC00);
                    } else if (hi >= 0xDC00 && hi <= 0xDFFF) {
                        return false;   // lone low surrogate
                    } else {
                        cp = (unsigned) hi;
                    }
                    if (cp < 0x80) {
                        out += (char) cp;
                    } else if (cp < 0x800) {
                        out += (char) (0xC0 | cp >> 6);
                        out += (char) (0x80 | (cp & 0x3F));
                    } else if (cp < 0x10000) {
                        out += (char) (0xE0 | cp >> 12);
                        out += (char) (0x80 | (cp >> 6 & 0x3F));
                        out += (char) (0x80 | (cp & 0x3F));
                    } else {
                        out += (char) (0xF0 | cp >> 18);
                        out += (char) (0x80 | (cp >> 12 & 0x3F));
                        out += (char) (0x80 | (cp >> 6 & 0x3F));
                        out += (char) (0x80 | (cp & 0x3F));
                    }
                    break;
                }
                default: return false;
            }
            ++i;
            continue;
        }
        out += (char) c;
        ++i;
    }
    return false;
}

bool write_vocab(const std::string & path, const std::string & vocab_json,
                 std::string & err) {
    std::vector<std::string> id2tok;
    std::vector<bool>        seen;   // an id with no token is an error
    size_t i = vocab_json.find('{');
    if (i == std::string::npos) {
        err = "vocab_json is not an object";
        return false;
    }
    ++i;
    for (;;) {
        while (i < vocab_json.size() && isspace((unsigned char) vocab_json[i])) {
            ++i;
        }
        if (i >= vocab_json.size()) {
            err = "truncated vocab_json";
            return false;
        }
        if (vocab_json[i] == '}') {
            break;
        }
        std::string tok;
        if (!parse_json_string(vocab_json, i, tok)) {
            err = "vocab_json: bad key";
            return false;
        }
        while (i < vocab_json.size() && (isspace((unsigned char) vocab_json[i]) || vocab_json[i] == ':')) {
            ++i;
        }
        char * e = nullptr;
        const long id = strtol(vocab_json.c_str() + i, &e, 10);
        if (e == vocab_json.c_str() + i || id < 0) {
            err = "vocab_json: bad id";
            return false;
        }
        i = (size_t) (e - vocab_json.c_str());
        if ((size_t) id >= id2tok.size()) {
            id2tok.resize((size_t) id + 1);
            seen.resize(id2tok.size());
        }
        id2tok[id] = tok;
        seen[id]   = true;
        while (i < vocab_json.size() && (isspace((unsigned char) vocab_json[i]) || vocab_json[i] == ',')) {
            ++i;
        }
    }
    for (size_t k = 0; k < id2tok.size(); ++k) {
        if (!seen[k]) {
            err = "vocab_json: no token for id " + std::to_string(k);
            return false;
        }
    }
    std::string o = "{";
    for (size_t k = 0; k < id2tok.size(); ++k) {
        if (k) {
            o += ",";
        }
        o += '"' + std::to_string(k) + "\":\"";
        for (unsigned char c : id2tok[k]) {
            switch (c) {
                case '"':  o += "\\\""; break;
                case '\\': o += "\\\\"; break;
                default:
                    if (c < 0x20) {
                        char u[8];
                        snprintf(u, sizeof(u), "\\u%04x", c);
                        o += u;
                    } else {
                        o += (char) c;
                    }
            }
        }
        o += '"';
    }
    o += "}\n";
    const std::string tmp = path + ".tmp";
    FILE * f = fopen(tmp.c_str(), "wb");
    if (!f) {
        err = "cannot write " + tmp;
        return false;
    }
    const bool ok = fwrite(o.data(), 1, o.size(), f) == o.size();
    return commit_file(f, ok, tmp, path, err);
}

void no_log(ggml_log_level, const char *, void *) {}

std::string json_str(const std::string & s) {
    std::string o = "\"";
    for (unsigned char c : s) {
        switch (c) {
            case '"':  o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            default:
                if (c < 0x20) {
                    char u[8];
                    snprintf(u, sizeof(u), "\\u%04x", c);
                    o += u;
                } else {
                    o += (char) c;
                }
        }
    }
    return o + '"';
}

// --info: model hyperparameters + provenance as one JSON object on stdout
void print_info(const model & m) {
    const hparams & h = m.h;
    std::string name, sha;
    kv_str(m.gguf, "general.name", name);
    kv_str(m.gguf, "ox_align.source_sha256", sha);
    int ftype = 0;
    kv_u32(m.gguf, "general.file_type", ftype);
    auto arr = [](const int * v, int n) {
        std::string o = "[";
        for (int i = 0; i < n; ++i) {
            if (i) {
                o += ",";
            }
            o += std::to_string(v[i]);
        }
        return o + "]";
    };
    printf("{"
           "\"name\":%s,\"file_type\":\"%s\","
           "\"hidden_size\":%d,\"num_hidden_layers\":%d,\"num_attention_heads\":%d,"
           "\"intermediate_size\":%d,\"vocab_size\":%d,"
           "\"num_conv_pos_embeddings\":%d,\"num_conv_pos_embedding_groups\":%d,"
           "\"conv_kernel\":%s,\"conv_stride\":%s,\"conv_dim\":%s,"
           "\"feat_extract_norm\":\"%s\",\"do_stable_layer_norm\":%s,"
           "\"do_normalize\":%s,\"conv_bias\":%s,\"layer_norm_eps\":%.6g,"
           "\"source_sha256\":%s}\n",
           json_str(name).c_str(), ftype == 1 ? "f16" : "f32",
           h.d, h.n_layer, h.n_head, h.n_inter, h.vocab, h.pos_k, h.pos_groups,
           arr(h.conv_k, h.n_conv).c_str(), arr(h.conv_s, h.n_conv).c_str(),
           arr(h.conv_d, h.n_conv).c_str(), h.feat_ln_layer ? "layer" : "group",
           h.stable_ln ? "true" : "false", h.do_normalize ? "true" : "false",
           h.conv_bias ? "true" : "false", (double) h.ln_eps,
           sha.empty() ? "null" : json_str(sha).c_str());
}

}  // namespace

int main(int argc, char ** argv) {
    args a;
    if (!parse(argc, argv, a)) {
        usage(argv[0]);
        return 2;
    }
    if (!a.verbose) {
        ggml_log_set(no_log, nullptr);
    }
    std::string err;

    // --info needs only the GGUF header: no audio, no backend, no tensor data
    if (a.info) {
        model m;
        if (!load_model(a.model, m, nullptr, false, true, err)) {
            fprintf(stderr, "ox-align: %s\n", err.c_str());
            return 1;
        }
        print_info(m);
        return 0;
    }
    const auto t0 = std::chrono::steady_clock::now();

    // backends: first GPU (unless -ng), then CPU
    ggml_backend_load_all();
    std::vector<ggml_backend_t> backends;
    if (a.gpu) {
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
            ggml_backend_dev_t dev = ggml_backend_dev_get(i);
            const auto t = ggml_backend_dev_type(dev);
            if (t == GGML_BACKEND_DEVICE_TYPE_GPU || t == GGML_BACKEND_DEVICE_TYPE_IGPU) {
                ggml_backend_t b = ggml_backend_dev_init(dev, nullptr);
                if (b) {
                    backends.push_back(b);
                    break;
                }
            }
        }
    }
    ggml_backend_t cpu = ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_CPU, nullptr);
    if (!cpu) {
        fprintf(stderr, "ox-align: no CPU backend\n");
        return 1;
    }
    ggml_backend_cpu_set_n_threads(cpu, a.threads);
    backends.push_back(cpu);
    ggml_backend_t wbackend = backends.front();

    model m;
    if (!load_model(a.model, m, wbackend, wbackend == cpu, false, err)) {
        fprintf(stderr, "ox-align: %s\n", err.c_str());
        return 1;
    }

    std::vector<float> x;
    if (!read_wav(a.file, x, err)) {
        fprintf(stderr, "ox-align: %s\n", err.c_str());
        return 1;
    }

    g_dump_dir = a.dump_dir;
    if (!g_dump_dir.empty()) {
        fprintf(stderr, "ox-align: dumping activations to %s\n", g_dump_dir.c_str());
    }

    // windowing mirrors the reference: xp padded to whole windows of `win`
    // samples with `ctx` on each side; per call the model sees win+2*ctx
    // samples and the ctx frames at both ends are dropped.
    const int64_t win = a.win_samples;
    const int64_t ctx = a.ctx_samples;
    const int64_t n_in = (int64_t) x.size();
    const int64_t ext = ((-n_in) % win + win) % win;
    std::vector<float> xp((size_t) (ctx + n_in + ctx + ext), 0.0f);
    memcpy(xp.data() + ctx, x.data(), x.size() * sizeof(float));
    std::vector<float>().swap(x);   // xp is the working copy from here
    const int64_t n_win = ((int64_t) xp.size() - 2 * ctx) / win;
    const int64_t slice = win + 2 * ctx;

    // frames per inference = the conv stack's output length
    int64_t T = slice;
    for (int i = 0; i < m.h.n_conv; ++i) {
        T = (T - m.h.conv_k[i]) / m.h.conv_s[i] + 1;
    }
    const int64_t crop = (int64_t) llround(a.context * 50);   // 50 frames/s
    const int64_t keep = (int64_t) llround(a.window * 50);
    if (crop + keep > T) {   // reference crops [crop : crop + keep] only
        fprintf(stderr, "ox-align: window %.3gs + context %.3gs gives %lld frames, need %lld\n",
                a.window, a.context, (long long) T, (long long) (crop + keep));
        return 1;
    }
    const int64_t out_want = (n_in + 319) / 320;   // ceil(len/320)

    // ---- the input length is fixed, so build the graph once ----
    const size_t max_nodes = 8192;
    struct ggml_init_params ip = { ggml_tensor_overhead() * max_nodes +
                                   ggml_graph_overhead_custom(max_nodes, false),
                                   nullptr, true };
    ggml_context * gctx = ggml_init(ip);
    if (!gctx) {
        fprintf(stderr, "ox-align: out of memory\n");
        return 1;
    }
    ggml_tensor * input = ggml_new_tensor_1d(gctx, GGML_TYPE_F32, slice);
    ggml_set_name(input, "audio_in");
    ggml_set_input(input);
    ggml_tensor * out = build_forward(gctx, m, input, T, crop, keep);
    ggml_set_output(out);

    ggml_cgraph * gf = ggml_new_graph_custom(gctx, max_nodes, false);
    ggml_build_forward_expand(gf, out);

    ggml_backend_sched_t sched =
        ggml_backend_sched_new(backends.data(), nullptr, (int) backends.size(), max_nodes, false, true);
    if (!sched || !ggml_backend_sched_alloc_graph(sched, gf)) {
        fprintf(stderr, "ox-align: failed to allocate the compute graph\n");
        return 1;
    }

    // ---- per window: normalize (HF do_normalize, per window), run, crop ----
    std::vector<float> emissions;
    emissions.reserve((size_t) n_win * keep * m.h.vocab);
    std::vector<float> out_row((size_t) keep * m.h.vocab);
    std::vector<float> buf((size_t) slice);
    for (int64_t w = 0; w < n_win; ++w) {
        const float * seg = xp.data() + w * win;
        if (a.normalize && m.h.do_normalize) {
            double mu = 0, var = 0;
            for (int64_t i = 0; i < slice; ++i) {
                mu += seg[i];
            }
            mu /= slice;
            for (int64_t i = 0; i < slice; ++i) {
                const double d = seg[i] - mu;
                var += d * d;
            }
            var /= slice;
            const double inv = 1.0 / sqrt(var + 1e-7);
            for (int64_t i = 0; i < slice; ++i) {
                buf[i] = (float) ((seg[i] - mu) * inv);
            }
            seg = buf.data();
        }
        ggml_backend_tensor_set(input, seg, 0, (size_t) slice * sizeof(float));
        if (ggml_backend_sched_graph_compute(sched, gf) != GGML_STATUS_SUCCESS) {
            fprintf(stderr, "ox-align: compute failed on window %lld\n", (long long) w);
            return 1;
        }
        ggml_backend_tensor_get(out, out_row.data(), 0, out_row.size() * sizeof(float));
        emissions.insert(emissions.end(), out_row.begin(), out_row.end());
        if (w == 0 && !g_dump_dir.empty()) {
            for (auto & [name, t] : g_dump) {
                std::vector<float> d(ggml_nelements(t));
                ggml_backend_tensor_get(t, d.data(), 0, d.size() * sizeof(float));
                std::string p = g_dump_dir + "/" + name + ".npy";
                if (!write_npy(p, d.data(), t->ne[1] * t->ne[2] * t->ne[3], t->ne[0], err)) {
                    fprintf(stderr, "ox-align: dump %s: %s\n", name.c_str(), err.c_str());
                }
            }
        }
    }

    const int64_t n_frames = std::min(out_want, n_win * keep);
    const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    if (a.verbose) {
        fprintf(stderr, "ox-align: %lld frames in %.3fs\n", (long long) n_frames, elapsed);
    }

    if (!write_npy(a.out, emissions.data(), n_frames, m.h.vocab, err)) {
        fprintf(stderr, "ox-align: %s\n", err.c_str());
        return 1;
    }
    if (!a.vocab.empty()) {
        if (m.vocab_json.empty()) {
            fprintf(stderr, "ox-align: model carries no vocab_json\n");
            return 1;
        }
        if (!write_vocab(a.vocab, m.vocab_json, err)) {
            fprintf(stderr, "ox-align: %s\n", err.c_str());
            return 1;
        }
    }
    return 0;
}
