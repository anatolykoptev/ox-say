package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/testutil"
	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// mcpSession connects an in-memory MCP client to d's tools — the same
// tools/list and tools/call an agent sees.
func mcpSession(t *testing.T, d *Daemon) *mcp.ClientSession {
	t.Helper()
	srv := mcp.NewServer(&mcp.Implementation{Name: "t", Version: "0"}, nil)
	d.RegisterTools(srv)
	ct, st := mcp.NewInMemoryTransports()
	ctx := context.Background()
	if _, err := srv.Connect(ctx, st, nil); err != nil {
		t.Fatal(err)
	}
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "c", Version: "0"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cs.Close() })
	return cs
}

// callMCP calls a tool and returns its structured result.
func callMCP(t *testing.T, cs *mcp.ClientSession, name string, args map[string]any) map[string]any {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	if res.IsError {
		raw, _ := json.Marshal(res.Content)
		t.Fatalf("%s: tool error: %s", name, raw)
	}
	raw, _ := json.Marshal(res.StructuredContent)
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("%s: %v (%s)", name, err, raw)
	}
	return out
}

type schemaView struct {
	Properties map[string]struct {
		Description string `json:"description"`
	} `json:"properties"`
	Required []string `json:"required"`
}

// wantToolSchemas pins each tool's exact property set and required fields.
// cfg_value, inference_timesteps and clone_mode live on speak alone: the
// plan's knob ruling keeps every other tool free of them.
var wantToolSchemas = map[string]struct{ props, required []string }{
	"speak": {[]string{"text", "model", "voice", "language", "format", "out_path", "overwrite", "play", "instructions",
		"cfg_value", "inference_timesteps", "clone_mode", "seed", "loudness_lufs"}, []string{"text"}},
	"voices_list":       {nil, nil},
	"voice_add":         {[]string{"name", "audio_path", "ref_text", "engine", "style", "designed_from"}, []string{"name", "audio_path"}},
	"voice_update":      {[]string{"name", "engine", "style"}, []string{"name"}},
	"voice_remove":      {[]string{"name"}, []string{"name"}},
	"voice_design":      {[]string{"description", "text", "takes", "seed"}, []string{"description", "text"}},
	"voice_design_save": {[]string{"name", "take", "replace"}, []string{"name", "take"}},
	"engine_status":     {nil, nil},
	"transcribe":        {[]string{"audio_path", "engine", "language", "prompt", "words", "out_path"}, []string{"audio_path"}},
	// The produce tools carry no cfg_value/inference_timesteps/loudness_lufs:
	// presets and the adapter's defaults carry them (the knob ruling).
	"produce": {[]string{"script", "title", "voice", "style", "preset", "seed", "takes", "out_path", "overwrite", "allow_battery"},
		[]string{"script"}},
	"produce_status":  {[]string{"id", "chunk"}, nil},
	"produce_edit":    {[]string{"id", "chunk", "action", "takes", "take", "text", "style", "pause_after", "chunks"}, []string{"id", "action"}},
	"produce_control": {[]string{"id", "action", "allow_battery", "delete_outputs"}, []string{"id", "action"}},
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func sorted(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}

// The live tools/list is the contract: exactly these tools, exactly these
// properties, every property described for the agent that reads it.
// Mutation: internal/daemon/mcp.go speakToolIn, delete the CfgValue field -> RED
// (speak lacks cfg_value). Mutation: add `CfgValue *float64` to voiceAddIn ->
// RED (a knob on a knob-free tool).
func TestMCPToolSchemasPinned(t *testing.T) {
	d, _, _ := designFixture(t)
	tools, err := mcpSession(t, d).ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]*mcp.Tool{}
	for _, tl := range tools.Tools {
		got[tl.Name] = tl
	}
	if g, w := sortedKeys(got), sortedKeys(wantToolSchemas); strings.Join(g, ",") != strings.Join(w, ",") {
		t.Fatalf("tools = %v, want %v", g, w)
	}
	for name, want := range wantToolSchemas {
		raw, _ := json.Marshal(got[name].InputSchema)
		var s schemaView
		if err := json.Unmarshal(raw, &s); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		props := map[string]string{}
		for p, v := range s.Properties {
			props[p] = v.Description
			if v.Description == "" {
				t.Errorf("%s.%s has no description: an agent cannot know what to put there", name, p)
			}
		}
		if g, w := strings.Join(sortedKeys(props), ","), strings.Join(sorted(want.props), ","); g != w {
			t.Errorf("%s properties = %s, want %s", name, g, w)
		}
		if g, w := strings.Join(sorted(s.Required), ","), strings.Join(sorted(want.required), ","); g != w {
			t.Errorf("%s required = %s, want %s", name, g, w)
		}
		if len(strings.TrimSpace(got[name].Description)) < 40 {
			t.Errorf("%s description too thin: %q", name, got[name].Description)
		}
	}
}

// Each description names what an agent needs to act first time: the limits,
// the units, the next call.
// Mutation: internal/daemon/mcp.go speak description, delete the "1000" limit
// sentence -> RED.
func TestMCPDescriptionsAreSelfSufficient(t *testing.T) {
	d, _, _ := designFixture(t)
	tools, err := mcpSession(t, d).ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	desc := map[string]string{}
	for _, tl := range tools.Tools {
		desc[tl.Name] = tl.Description
	}
	need := map[string][]string{
		"speak": {"qwen3-tts", "voxcpm2", "instructions", "1000 characters", "cfg_value", "inference_timesteps", "clone_mode",
			"seed", "loudness_lufs", "-16", "voice_design", "warning", "out_path", "format"},
		"voice_design":      {"voice_design_save", "takes", "seed", "200", "speak"},
		"voice_design_save": {"voice_design", "name", "take"},
		"voice_add":         {"engine", "style", "designed_from", "ref_text"},
		"voice_update":      {"engine", "style", "voice_add"},
		"voices_list":       {"engine", "style", "designed_from"},
		"engine_status":     {"voxcpm2", "stt_server"},
		"produce":           {"produce_status", "AT ONCE", "[pause", "[style:", "youtube", "reels", "voice-under-music", "out_path", "allow_battery", strconv.Itoa(maxProduceChars), "targets", "32 characters"},
		"produce_status":    {"review", "chunk", "produce_edit", vproject.NoteNumbers},
		"produce_edit":      {"regenerate", "pick", "edit", "delivery", "take", "produce_status", "pick is kept", "new takes", "user_pick", "ok even if"},
		"produce_control":   {"resume", "cancel", "remove", "delete_outputs", "allow_battery", "for good", "not running"},
	}
	for tool, words := range need {
		for _, w := range words {
			if !strings.Contains(desc[tool], w) {
				t.Errorf("%s description lacks %q", tool, w)
			}
		}
	}
}

// The agent journey over MCP: speak with no model uses qwen3-tts (the
// dictation-safe default), a voice is added with its engine and style, listed
// with them, updated, and the style cleared.
// Mutation: internal/daemon/mcp.go toolVoiceAdd, pass voices.Meta{} instead of
// the engine, style and designed_from -> RED (they are dropped).
func TestMCPVoiceJourney(t *testing.T) {
	d, dir, _ := designFixture(t)
	cs := mcpSession(t, d)
	d.Cfg.CacheDir = filepath.Join(dir, "cache")

	spoke := callMCP(t, cs, "speak", map[string]any{"text": "Привет.", "voice": "default"})
	if spoke["model"] != config.TTSModelQwen {
		t.Fatalf("speak with no model used %v, want %s", spoke["model"], config.TTSModelQwen)
	}

	clip := testutil.WriteSilentWAV(t, dir, "ref.wav", 3)
	callMCP(t, cs, "voice_add", map[string]any{"name": "ru-doc", "audio_path": clip, "engine": "voxcpm2",
		"style": "calm, warm", "designed_from": "a calm narrator"})
	found := func() map[string]any {
		for _, v := range callMCP(t, cs, "voices_list", nil)["voices"].([]any) {
			if m := v.(map[string]any); m["name"] == "ru-doc" {
				return m
			}
		}
		t.Fatal("ru-doc not listed")
		return nil
	}
	v := found()
	if v["engine"] != "voxcpm2" || v["style"] != "calm, warm" || v["designed_from"] != "a calm narrator" {
		t.Fatalf("listed voice = %v", v)
	}

	callMCP(t, cs, "voice_update", map[string]any{"name": "ru-doc", "style": "excited"})
	if v = found(); v["style"] != "excited" || v["engine"] != "voxcpm2" {
		t.Fatalf("after style update: %v", v)
	}
	callMCP(t, cs, "voice_update", map[string]any{"name": "ru-doc", "style": "", "engine": "qwen3-tts"})
	if v = found(); v["style"] != nil || v["engine"] != "qwen3-tts" {
		t.Fatalf("after clear: %v", v)
	}
}

// Every quality option on the speak tool reaches the engine request: a field
// the tool accepts but drops would fail silently (a take in the wrong style,
// at the wrong level, from another seed).
// Mutation: internal/daemon/mcp.go toolSpeak, delete the `CfgValue: in.CfgValue`
// line -> RED (guidance_scale stays 2). The same for InferenceTimesteps, Model,
// Seed, Instructions; and LoudnessLUFS / CloneMode, which the out-of-range
// calls below catch.
func TestMCPSpeakForwardsQualityOptions(t *testing.T) {
	d, _, logPath := designFixture(t)
	cs := mcpSession(t, d)
	got := callMCP(t, cs, "speak", map[string]any{"text": "Привет.", "voice": "nar", "model": "voxcpm2",
		"instructions": "calm, slow", "seed": 7, "cfg_value": 2.5, "inference_timesteps": 12, "clone_mode": "reference"})
	if got["model"] != config.TTSModelVoxCPM2 || got["seed"] != float64(7) {
		t.Fatalf("result = %v", got)
	}
	reqs := voxLog(t, logPath)
	if len(reqs) != 1 {
		t.Fatalf("engine requests %d, want 1", len(reqs))
	}
	r := reqs[0]
	if r["input"] != "(calm, slow)Привет." || r["seed"] != float64(7) || r["guidance_scale"] != 2.5 || r["num_inference_steps"] != float64(12) {
		t.Errorf("engine request = %v", r)
	}
	for name, args := range map[string]map[string]any{
		"loudness_lufs": {"text": "x", "model": "voxcpm2", "loudness_lufs": -100},
		"clone_mode":    {"text": "x", "model": "voxcpm2", "clone_mode": "bogus"},
	} {
		res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "speak", Arguments: args})
		if err != nil || !res.IsError {
			t.Errorf("%s: the bad value was accepted (err %v): the option is not forwarded", name, err)
		}
	}
}

// The numeric ranges and the clone-mode conditions an agent reads match the
// code's constants and rules.
// Mutation: internal/daemon/voxcpm2.go maxCfgValue 5.0 -> 6.0 (or maxTimesteps
// 50 -> 60) -> RED (the texts still say 5 / 1-50).
func TestMCPTextsStateRangesFromConstants(t *testing.T) {
	d, _, _ := designFixture(t)
	tools, err := mcpSession(t, d).ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	var speak *mcp.Tool
	for _, tl := range tools.Tools {
		if tl.Name == "speak" {
			speak = tl
		}
	}
	schema, _ := json.Marshal(speak.InputSchema)
	cfgRange := fmt.Sprintf("at most %.0f", maxCfgValue)
	stepRange := fmt.Sprintf("1-%d", maxTimesteps)
	for _, w := range []string{cfgRange, stepRange} {
		if !strings.Contains(string(schema), w) || !strings.Contains(speak.Description, w) {
			t.Errorf("speak schema or description lacks %q", w)
		}
	}
	for _, w := range []string{"neither instructions nor the voice's saved style", "same script", `voice_update (style "")`, "saved style"} {
		if !strings.Contains(speak.Description, w) {
			t.Errorf("speak description lacks %q", w)
		}
	}
}
