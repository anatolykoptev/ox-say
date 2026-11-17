package daemon

// The KV-cache size estimate and the context fit behind the endpoint's large
// context (issue #537, review round 1): llama.cpp's own geometry as the
// oracle, a model file replaced under a cached ceiling, the compact fallback's
// own ceiling, and a fit that cannot overflow.

import (
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/meeting"
)

func u32kv(key string, v uint32) ggufKV { return ggufKV{Key: key, Type: ggufTypeUint32, U32: v} }

func archKV(arch string) ggufKV {
	return ggufKV{Key: "general.architecture", Type: ggufTypeString, Str: arch}
}

// The numbers are llama.cpp's, not the code under test's: for a qwen35 file
// (src/models/qwen35.cpp) is_recr = (il+1) % full_attention_interval != 0 over
// the trunk (block_count minus nextn_predict_layers, src/llama-hparams.cpp
// n_layer()), and a KV layer stores head_count_kv x (key_length +
// value_length) elements per token, q8_0 at 34 bytes per 32. The geometry is
// the header of Huihui-Qwen3.8-27B-abliterated-UD-Q5_K_XL.gguf as read from
// the file: block_count 65, nextn_predict_layers 1, full_attention_interval 4,
// head_count_kv 4, key_length = value_length = 256 -> 16 attention layers:
// 16 x 4 x 512 x 34/32 = 34,816 bytes per token (4.25 GiB at 131072; f16
// would be 65,536 per token).
// Mutation: gguf.go kvPerToken, in the `case interval > 0:` branch set
// `attends = true` (every layer counted, the layer_count answer) -> RED
// (139,264 bytes per token for the hybrid).
func TestGGUFKVPerTokenKnownAnswers(t *testing.T) {
	cases := []struct {
		name string
		kvs  []ggufKV
		want int64
	}{
		{"hybrid qwen35 27B (interval form, nextn layer outside the trunk)", []ggufKV{
			archKV("qwen35"), u32kv("qwen35.block_count", 65), u32kv("qwen35.nextn_predict_layers", 1),
			u32kv("qwen35.full_attention_interval", 4), u32kv("qwen35.attention.head_count", 24),
			u32kv("qwen35.attention.head_count_kv", 4), u32kv("qwen35.attention.key_length", 256),
			u32kv("qwen35.attention.value_length", 256), u32kv("qwen35.embedding_length", 5120),
			u32kv("qwen35.context_length", 262144),
		}, 34816},
		{"qwen35 without the interval key defaults to 4 like llama.cpp", []ggufKV{
			archKV("qwen35"), u32kv("qwen35.block_count", 32), u32kv("qwen35.attention.head_count_kv", 4),
			u32kv("qwen35.attention.key_length", 256), u32kv("qwen35.attention.value_length", 256),
		}, 8 * 4 * 512 * 34 / 32},
		{"plain dense model, all 32 layers keep KV", []ggufKV{
			archKV("llama"), u32kv("llama.block_count", 32), u32kv("llama.attention.head_count", 32),
			u32kv("llama.attention.head_count_kv", 8), u32kv("llama.attention.key_length", 128),
			u32kv("llama.attention.value_length", 128),
		}, 32 * 8 * 256 * 34 / 32},
		{"dense without key_length: llama.cpp falls back to embedding_length / head_count", []ggufKV{
			archKV("llama"), u32kv("llama.block_count", 32), u32kv("llama.attention.head_count", 32),
			u32kv("llama.attention.head_count_kv", 8), u32kv("llama.embedding_length", 4096),
		}, 32 * 8 * 256 * 34 / 32},
		{"per-layer head_count_kv array: nonzero entries are the attention layers", []ggufKV{
			archKV("granite"), u32kv("granite.block_count", 8), u32kv("granite.attention.key_length", 128),
			u32kv("granite.attention.value_length", 128),
			{Key: "granite.attention.head_count_kv", Type: ggufTypeArray, U32s: []uint32{0, 0, 0, 4, 0, 0, 0, 4}},
		}, 2 * 4 * 256 * 34 / 32},
		{"an explicit recurrent_layers array wins over the interval (llama.cpp reads it first)", []ggufKV{
			archKV("qwen35"), u32kv("qwen35.block_count", 8), u32kv("qwen35.full_attention_interval", 2),
			u32kv("qwen35.attention.head_count_kv", 4), u32kv("qwen35.attention.key_length", 128),
			u32kv("qwen35.attention.value_length", 128),
			{Key: "qwen35.attention.recurrent_layers", Type: ggufTypeArray, U32s: []uint32{1, 1, 1, 0, 1, 1, 1, 0}},
		}, 2 * 4 * 256 * 34 / 32},
		{"no geometry at all is unknown, not guessed", []ggufKV{archKV("llama")}, 0},
		{"an absurd block_count is refused, not looped over", []ggufKV{
			archKV("llama"), u32kv("llama.block_count", 4_000_000_000), u32kv("llama.attention.head_count_kv", 8),
			u32kv("llama.attention.key_length", 128), u32kv("llama.attention.value_length", 128),
		}, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m, err := ggufReadMeta(ggufFile(t, writeTestGGUF(t, 3, tc.kvs)))
			if err != nil {
				t.Fatal(err)
			}
			if got := m.kvPerToken(); got != tc.want {
				t.Fatalf("kvPerToken = %d, want %d", got, tc.want)
			}
		})
	}
	// The headline figure, in GiB at the endpoint's default context.
	if got := int64(34816) * 131072; got != 4563402752 || float64(got)/(1<<30) != 4.25 {
		t.Fatalf("34816 B/token x 131072 = %d, want 4.25 GiB", got)
	}
}

// fitCtx is closed-form and cannot overflow, whatever the inputs.
func TestFitCtxBoundsAndOverflow(t *testing.T) {
	const floor = 17920
	gib := int64(1) << 30
	cases := []struct {
		name                       string
		want                       int
		kvToken, weights, room, ex int64
	}{
		{"everything fits: the ask stands", 131072, 34816, 16 * gib, 40 * gib, 131072},
		// room - weights - 1 GiB slack = 9 GiB = 9663676416 B; / 34816 = 277,560 tokens -> capped by the ask
		{"the ask is the cap", 65536, 34816, 16 * gib, 26 * gib, 65536},
		// 5 GiB left / 34816 = 154,202 tokens -> 151552 (37 x 4096)
		{"stepped down to a multiple of 4096", 262144, 34816, 16 * gib, 22 * gib, 151552},
		{"no room beside the weights: the floor", 131072, 34816, 16 * gib, 16 * gib, floor},
		{"negative room: the floor", 131072, 34816, 16 * gib, -5 * gib, floor},
		{"unknown KV size: the floor (callers skip the fit)", 131072, 0, 16 * gib, 40 * gib, floor},
		{"weights near MaxInt64 do not wrap", 131072, 34816, math.MaxInt64 - 1, math.MaxInt64, floor},
		{"negative weights are refused", 131072, 34816, -1, math.MaxInt64, floor},
		{"MinInt64 room does not wrap", 131072, 34816, 16 * gib, math.MinInt64, floor},
		{"an astronomical per-token size", 131072, math.MaxInt64, 16 * gib, 40 * gib, floor},
		{"a 1 Mi ask with MaxInt64 room", 1 << 20, 1, 0, math.MaxInt64, 1 << 20},
	}
	for _, tc := range cases {
		if got := fitCtx(tc.want, floor, tc.kvToken, tc.weights, tc.room); int64(got) != tc.ex {
			t.Errorf("%s: fitCtx = %d, want %d", tc.name, got, tc.ex)
		}
	}
	// O(1): a 1 Mi ask costs the same as a 4096 one — no per-step loop to time.
	start := time.Now()
	for i := 0; i < 1_000_000; i++ {
		_ = fitCtx(1<<20, floor, 34816, 16*gib, 22*gib)
	}
	if took := time.Since(start); took > 2*time.Second {
		t.Fatalf("1M fits took %v: not closed-form", took)
	}
}

// A ceiling cached for a path follows the file: replaced at the same path it is
// re-read, and a model missing at first read does not freeze at 0.
func TestNotesCtxMaxFollowsTheFile(t *testing.T) {
	d, _, _ := llmEndpointFixture(t, nil)
	path := filepath.Join(t.TempDir(), "m.gguf")
	write := func(ctx uint32) {
		t.Helper()
		body := writeTestGGUF(t, 3, []ggufKV{archKV("llama"), u32kv("llama.context_length", ctx)})
		if err := os.WriteFile(path, body, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if got := d.notesCtxMax(path); got != 0 {
		t.Fatalf("a missing model's ceiling = %d, want 0", got)
	}
	write(65536) // the model arrives later: the earlier 0 must not stick
	if got := d.notesCtxMax(path); got != 65536 {
		t.Fatalf("the installed model's ceiling = %d, want 65536 (a missing-file 0 was cached)", got)
	}
	write(262144) // a different file at the same path (a different size)
	if got := d.notesCtxMax(path); got != 262144 {
		t.Fatalf("the replaced model's ceiling = %d, want 262144 (stale cache)", got)
	}
	// Same size, new mtime: a same-length replacement is still a new file.
	body := writeTestGGUF(t, 3, []ggufKV{archKV("llama"), u32kv("llama.context_length", 131072)})
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	later := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(path, later, later); err != nil {
		t.Fatal(err)
	}
	if got := d.notesCtxMax(path); got != 131072 {
		t.Fatalf("a same-size replacement's ceiling = %d, want 131072", got)
	}
	d.fit.mu.Lock()
	n := len(d.fit.ctxMax)
	d.fit.mu.Unlock()
	if n != 1 {
		t.Fatalf("%d cache entries for one path: replaced versions are not dropped", n)
	}
}

// The compact fallback gets its OWN model's context ceiling, not the resolved
// model's it replaced: a resolved model with a short window must not cap the
// compact one that actually loads.
// Mutation: notesfit.go notesSpawnPlan, delete the `p.want =
// d.notesCtxWantFor(path)` line in the fallback branch -> RED (the compact
// model is spawned with the 9B's smaller ceiling).
func TestCompactFallbackGetsItsOwnContextCeiling(t *testing.T) {
	d, dir := bothModels(t)
	big := filepath.Join(d.Cfg.ModelsDir(), "Qwen3.5-9B-Q4_K_M.gguf")
	compact := filepath.Join(d.Cfg.ModelsDir(), config.NotesModelFile)
	writeCtx := func(path string, ctx uint32) {
		t.Helper()
		body := writeTestGGUF(t, 3, []ggufKV{archKV("qwen35"), u32kv("qwen35.context_length", ctx)})
		if err := os.WriteFile(path, body, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writeCtx(big, 65536)
	writeCtx(compact, 262144)
	if err := d.Meet.Store.UpdateSettings(func(cur meeting.Settings, _ error) (meeting.Settings, error) {
		cur.LLMEndpoint = "on"
		return cur, nil
	}); err != nil {
		t.Fatal(err)
	}
	fakeBudget(t, tightLimitMiB, othersMiB) // the 9B's weights do not fit: the 4B takes over
	if err := complete(t, d); err != nil {
		t.Fatal(err)
	}
	args := spawnArgvs(t, dir)
	if len(args) != 1 || !strings.Contains(modelOf(args[0]), "4B") {
		t.Fatalf("spawns = %v, want one spawn of the compact 4B", args)
	}
	if c := notesFlagValue(args[0], "-c"); c != "131072" {
		t.Fatalf("the compact fallback's -c = %s, want the 131072 ask (its own ceiling is 262144; the 9B's 65536 must not apply)", c)
	}
	if st := d.Status().LLMEndpoint; st.Context != 131072 {
		t.Fatalf("/status context = %d, want 131072", st.Context)
	}
}
