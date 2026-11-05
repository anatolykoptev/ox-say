package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// toolErrText calls a tool that must fail and returns the error text an agent reads.
func toolErrText(t *testing.T, cs *mcp.ClientSession, name string, args map[string]any) string {
	t.Helper()
	out, errText := toolText(t, cs, name, args)
	if errText == "" {
		t.Fatalf("%s: want a tool error, got %v", name, out)
	}
	return errText
}

func toolListed(t *testing.T, cs *mcp.ClientSession, name string) *mcp.Tool {
	t.Helper()
	list, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, tl := range list.Tools {
		if tl.Name == name {
			return tl
		}
	}
	return nil
}

// Mutation (F1): mcp.go RegisterTools, delete the `d.registerCleanTools(srv)` line -> RED (voice_clean not registered).
// Mutation (F3): clean_mcp.go cleanToolDescription, delete "NOT for meetings or dictation" -> RED.
func TestVoiceCleanToolIsRegisteredAndDescribesItsLimits(t *testing.T) {
	d, _, _ := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	tool := toolListed(t, mcpSession(t, d), "voice_clean")
	if tool == nil {
		t.Fatal("voice_clean not registered")
	}
	for _, want := range []string{"first audio stream", "NOT for meetings or dictation", "offline", "Intel",
		"about 170x real time on Apple Silicon", "about 7x with a discrete GPU", "ffmpeg"} {
		if !strings.Contains(tool.Description, want) {
			t.Errorf("description lacks %q", want)
		}
	}
}

// The input schema is the contract an agent plans from: both paths required, wet bounded to 0..1.
// Mutation: clean_mcp.go cleanToolSchema, delete the Maximum line -> RED.
func TestVoiceCleanInputSchema(t *testing.T) {
	d, _, log := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	tool := toolListed(t, mcpSession(t, d), "voice_clean")
	if tool == nil {
		t.Fatal("voice_clean not registered")
	}
	raw, _ := json.Marshal(tool.InputSchema)
	var s struct {
		Required   []string `json:"required"`
		Properties map[string]struct {
			Description string   `json:"description"`
			Minimum     *float64 `json:"minimum"`
			Maximum     *float64 `json:"maximum"`
		} `json:"properties"`
	}
	if err := json.Unmarshal(raw, &s); err != nil {
		t.Fatal(err)
	}
	if g, w := strings.Join(sorted(s.Required), ","), "in_path,out_path"; g != w {
		t.Errorf("required = %s, want %s", g, w)
	}
	if g, w := strings.Join(sortedKeys(s.Properties), ","), "in_path,out_path,overwrite,stereo,wet"; g != w {
		t.Errorf("properties = %s, want %s", g, w)
	}
	wet := s.Properties["wet"]
	if wet.Minimum == nil || *wet.Minimum != 0 || wet.Maximum == nil || *wet.Maximum != 1 {
		t.Errorf("wet bounds = %v..%v, want 0..1 (%s)", wet.Minimum, wet.Maximum, raw)
	}
	for name, p := range s.Properties {
		if p.Description == "" {
			t.Errorf("%s has no description", name)
		}
	}
	// And the server enforces it before anything runs.
	res, err := mcpSession(t, d).CallTool(context.Background(), &mcp.CallToolParams{Name: "voice_clean",
		Arguments: map[string]any{"in_path": "/a.wav", "out_path": "/b.wav", "wet": 1.5}})
	if err == nil && !res.IsError {
		t.Error("wet 1.5 was accepted")
	}
	if _, serr := os.Stat(log); serr == nil {
		t.Error("the engine ran for wet 1.5")
	}
}

// The tool answers what the route answers for the same request, lag_ms and dropped included, and a meetings path is a
// tool error carrying the route's own 403 sentence with the engine never run.
// Mutation (F2): clean_mcp.go toolVoiceClean, call voiceclean.Run directly with no Forbidden instead of d.Clean -> RED
// (the meetings case is cleaned).
func TestVoiceCleanToolRunsTheSameCodeAsTheRoute(t *testing.T) {
	d, h, log := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	cs := mcpSession(t, d)
	dir := t.TempDir()
	in := filepath.Join(dir, "in.wav")
	makeWav(t, in, 2)

	viaRoute := postClean(h, cleanBody(in, filepath.Join(dir, "route.wav")))
	if viaRoute.Code != 200 {
		t.Fatalf("route: %d %s", viaRoute.Code, viaRoute.Body)
	}
	var want map[string]any
	_ = json.Unmarshal(viaRoute.Body.Bytes(), &want)

	got, errText := toolText(t, cs, "voice_clean", map[string]any{"in_path": in, "out_path": filepath.Join(dir, "tool.wav")})
	if errText != "" {
		t.Fatalf("tool: %s", errText)
	}
	if _, ok := got["lag_ms"]; !ok {
		t.Errorf("lag_ms missing: %v", got)
	}
	if dr, ok := got["dropped"].([]any); !ok || len(dr) != 0 {
		t.Errorf("dropped must be an empty list: %v", got["dropped"])
	}
	for _, k := range []string{"video", "input_seconds", "wet", "stereo", "sample_rate", "channels", "lag_ms", "dropped"} {
		if gj, wj := mustJSON(got[k]), mustJSON(want[k]); gj != wj {
			t.Errorf("%s: tool %s, route %s", k, gj, wj)
		}
	}
	if got["out_path"] != filepath.Join(dir, "tool.wav") {
		t.Errorf("out_path %v", got["out_path"])
	}
	if st, err := os.Stat(filepath.Join(dir, "tool.wav")); err != nil || st.Size() == 0 {
		t.Fatalf("no output file: %v", err)
	}

	// a meeting file: the same sentence the route gives, nothing spawned for it
	m := filepath.Join(d.Cfg.Home, "meetings", "m1", "them.wav")
	makeWav(t, m, 1)
	before, _ := os.ReadFile(log)
	routeRec := postClean(h, cleanBody(m, filepath.Join(dir, "m.wav")))
	var env struct {
		Error struct{ Message, Code string }
	}
	_ = json.Unmarshal(routeRec.Body.Bytes(), &env)
	if routeRec.Code != 403 || env.Error.Message == "" {
		t.Fatalf("route on a meeting file: %d %s", routeRec.Code, routeRec.Body)
	}
	errText = toolErrText(t, cs, "voice_clean", map[string]any{"in_path": m, "out_path": filepath.Join(dir, "m2.wav")})
	if !strings.Contains(errText, env.Error.Message) || !strings.Contains(errText, env.Error.Code) {
		t.Errorf("tool error %s lacks the route's sentence %q or code %q", errText, env.Error.Message, env.Error.Code)
	}
	if _, err := os.Stat(filepath.Join(dir, "m2.wav")); err == nil {
		t.Error("a meeting file was cleaned through the tool")
	}
	if after, _ := os.ReadFile(log); !bytes.Equal(before, after) {
		t.Error("the engine ran for a meeting file")
	}
}

func mustJSON(v any) string { b, _ := json.Marshal(v); return string(b) }

// A relative path is refused with the sentence, and nothing is spawned.
func TestVoiceCleanRequiresAbsolutePaths(t *testing.T) {
	d, _, log := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	errText := toolErrText(t, mcpSession(t, d), "voice_clean", map[string]any{"in_path": "rel.wav", "out_path": "/tmp/out.wav"})
	if !strings.Contains(errText, "absolute") || !strings.Contains(errText, "invalid_request") {
		t.Errorf("tool error %s", errText)
	}
	if _, err := os.Stat(log); err == nil {
		t.Error("the engine ran for a relative path")
	}
}

// A tool's own output never reaches the agent: the engine's stderr stays in the log; the agent gets the sentence.
// Mutation: clean_mcp.go cleanToolError, append e.Reason or the engine tail (use err.Error() of the cause) -> RED.
func TestVoiceCleanToolErrorCarriesTheSentenceNeverToolOutput(t *testing.T) {
	d, _, _ := newCleanDaemon(t, `echo "SECRET-STDERR /Users/someone/private/path [reason=boom]" >&2; exit 1`)
	dir := t.TempDir()
	in := filepath.Join(dir, "in.wav")
	makeWav(t, in, 1)
	errText := toolErrText(t, mcpSession(t, d), "voice_clean", map[string]any{"in_path": in, "out_path": filepath.Join(dir, "o.wav")})
	for _, bad := range []string{"SECRET-STDERR", "/Users/someone", "reason=boom", "boom"} {
		if strings.Contains(errText, bad) {
			t.Errorf("tool output %q leaked into the tool error: %s", bad, errText)
		}
	}
	if !strings.Contains(errText, "The cleanup engine failed while processing the audio. Your file was not changed.") ||
		!strings.Contains(errText, "engine_failed") {
		t.Errorf("tool error lacks the sentence and code: %s", errText)
	}
}

// The three "come back later" answers reach the agent as tool errors with their sentence and code.
func TestVoiceCleanBusyAnswersAreToolErrors(t *testing.T) {
	t.Run("busy: another cleanup is running", func(t *testing.T) {
		d, h, _ := newCleanDaemon(t, `sleep 1; cp "$IN" "$OUT"`)
		dir := t.TempDir()
		in := filepath.Join(dir, "in.wav")
		makeWav(t, in, 1)
		done := make(chan struct{})
		go func() { postClean(h, cleanBody(in, filepath.Join(dir, "a.wav"))); close(done) }()
		waitFor(t, "the first cleanup to start", func() bool { return d.cleanRunning.Load() == 1 })
		errText := toolErrText(t, mcpSession(t, d), "voice_clean", map[string]any{"in_path": in, "out_path": filepath.Join(dir, "b.wav")})
		if !strings.Contains(errText, "Another file is being cleaned. Wait for it to finish.") || !strings.Contains(errText, "busy") {
			t.Errorf("%s", errText)
		}
		<-done
	})
	t.Run("gpu_busy: speech holds the card on Intel", func(t *testing.T) {
		d, _, _ := newCleanDaemonOn(t, `cp "$IN" "$OUT"`, false)
		shortQuiet(t, 200*time.Millisecond)
		if !d.gpu.TryAs("tts") {
			t.Fatal("lease")
		}
		defer d.gpu.Release()
		dir := t.TempDir()
		in := filepath.Join(dir, "in.wav")
		makeWav(t, in, 1)
		errText := toolErrText(t, mcpSession(t, d), "voice_clean", map[string]any{"in_path": in, "out_path": filepath.Join(dir, "o.wav")})
		if !strings.Contains(errText, "The graphics card is busy with speech; try again in a moment.") || !strings.Contains(errText, "gpu_busy") {
			t.Errorf("%s", errText)
		}
	})
	t.Run("models_downloading: first use fetches the model", func(t *testing.T) {
		d, _, _ := newCleanDaemon(t, `cp "$IN" "$OUT"`)
		_ = os.Remove(filepath.Join(d.Cfg.CleanModelsDir(), "mossformer2-se-48k", ".ox-say-revision"))
		installScript(t, d)
		release := filepath.Join(t.TempDir(), "release")
		old := cleanFetchStart
		cleanFetchStart = func(ctx context.Context, script, dest string, tail *bytes.Buffer) (*exec.Cmd, error) {
			cmd := exec.CommandContext(ctx, "/bin/sh", "-c", `while [ ! -e "$1" ]; do sleep 0.02; done`, "sh", release)
			return cmd, cmd.Start()
		}
		t.Cleanup(func() { cleanFetchStart = old })
		t.Cleanup(func() { _ = os.WriteFile(release, nil, 0o644); d.cleanInst.wg.Wait() })
		dir := t.TempDir()
		in := filepath.Join(dir, "in.wav")
		makeWav(t, in, 1)
		errText := toolErrText(t, mcpSession(t, d), "voice_clean", map[string]any{"in_path": in, "out_path": filepath.Join(dir, "o.wav")})
		if !strings.Contains(errText, "The voice cleanup model is being downloaded") || !strings.Contains(errText, "models_downloading") {
			t.Errorf("%s", errText)
		}
	})
}

// A cleanup runs for minutes: the MCP call needs the deadline of the whole request, not the default one.
// Mutation: guard.go ServerConfig, delete the "voice_clean" ToolTimeouts entry -> RED.
func TestVoiceCleanToolTimeoutCoversTheWholeJob(t *testing.T) {
	d, _, _ := newCleanDaemon(t, `exit 0`)
	got := d.ServerConfig("test").ToolTimeouts["voice_clean"]
	if want := cleanOuterCap + cleanQuietCap + time.Minute; got < want {
		t.Fatalf("voice_clean tool timeout = %s, want at least %s", got, want)
	}
}
