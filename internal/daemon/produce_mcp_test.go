package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

func produceMCPSession(t *testing.T, f *fakePorts) *mcp.ClientSession {
	t.Helper()
	d, _ := produceMux(t, f)
	return mcpSession(t, d)
}

// The ranges and the preset names an agent reads come from the code's own
// constants and registry, not from a hand-written copy.
// Mutation: internal/daemon/produce.go maxTakesPerChunk 3 -> 4 (the schema
// text still says 1-3) -> RED; add a preset to `presets` -> RED (not named).
func TestMCPProduceTextsStateRangesFromConstants(t *testing.T) {
	d, _, _ := designFixture(t)
	tools, err := mcpSession(t, d).ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, tl := range tools.Tools {
		if tl.Name != "produce" {
			continue
		}
		schema, _ := json.Marshal(tl.InputSchema)
		takes := fmt.Sprintf("1-%d", maxTakesPerChunk)
		chars := fmt.Sprintf("%d characters", maxProduceChars)
		for _, w := range []string{takes, chars} {
			if !strings.Contains(string(schema), w) || !strings.Contains(tl.Description, strings.TrimSuffix(w, " characters")) {
				t.Errorf("produce schema or description lacks %q", w)
			}
		}
		for name := range presets {
			if !strings.Contains(tl.Description, name) || !strings.Contains(string(schema), name) {
				t.Errorf("preset %q is not named to the agent", name)
			}
		}
		return
	}
	t.Fatal("no produce tool")
}

func toolText(t *testing.T, cs *mcp.ClientSession, name string, args map[string]any) (map[string]any, string) {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	raw, _ := json.Marshal(res.StructuredContent)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	if res.IsError {
		msg, _ := json.Marshal(res.Content)
		return nil, string(msg)
	}
	return out, ""
}

// An agent's journey using only the tool descriptions: produce answers at
// once with an id, produce_status reaches done, a chunk's detail lists its
// takes with files, produce_edit regenerates and the answer says the pick is
// kept, and a pick of a key the chunk lacks is refused in plain words.
// Mutation: internal/daemon/produce_mcp.go toolProduceEdit, drop Next from the
// answer -> RED.
func TestMCPProduceJourney(t *testing.T) {
	f := newFakePorts(t)
	cs := produceMCPSession(t, f)
	start := time.Now()
	out, errText := toolText(t, cs, "produce", map[string]any{"script": "Привет.", "preset": "reels"})
	if errText != "" || out["id"] == nil || out["status"] != "running" {
		t.Fatalf("produce: %v %s", out, errText)
	}
	if time.Since(start) > 5*time.Second {
		t.Fatal("produce did not return at once")
	}
	id := out["id"].(string)
	var proj map[string]any
	for i := 0; i < 500; i++ {
		got, _ := toolText(t, cs, "produce_status", map[string]any{"id": id})
		proj, _ = got["project"].(map[string]any)
		if proj != nil && proj["status"] == "done" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if proj == nil || proj["status"] != "done" {
		t.Fatalf("never done: %v", proj)
	}
	time.Sleep(50 * time.Millisecond) // the job releases the producer just after it saves "done"
	list, _ := toolText(t, cs, "produce_status", map[string]any{})
	if ps, _ := list["projects"].([]any); len(ps) != 1 {
		t.Fatalf("list: %v", list)
	}
	det, errText := toolText(t, cs, "produce_status", map[string]any{"id": id, "chunk": 0})
	chunk, _ := det["chunk"].(map[string]any)
	if errText != "" || chunk == nil || chunk["take_files"] == nil {
		t.Fatalf("chunk detail: %v %s", det, errText)
	}
	ed, errText := toolText(t, cs, "produce_edit", map[string]any{"id": id, "chunk": 0, "action": "regenerate", "takes": 1})
	if errText != "" || !strings.Contains(fmt.Sprint(ed["next"]), "pick is unchanged") {
		t.Fatalf("edit: %v %s", ed, errText)
	}
	if _, errText := toolText(t, cs, "produce_status", map[string]any{"chunk": 0}); !strings.Contains(errText, "chunk needs id") {
		t.Fatalf("chunk without id: %s", errText)
	}
}

// A busy producer is reported with the running project's id, and no tool
// error carries an internal path.
func TestMCPProduceBusyNamesRunningProject(t *testing.T) {
	f := newFakePorts(t)
	f.block, f.started = make(chan struct{}), make(chan struct{}, 8)
	cs := produceMCPSession(t, f)
	first, _ := toolText(t, cs, "produce", map[string]any{"script": "Привет."})
	<-f.started
	_, errText := toolText(t, cs, "produce", map[string]any{"script": "Ещё."})
	if !strings.Contains(errText, first["id"].(string)) || strings.Contains(errText, f.home) {
		t.Fatalf("busy error: %s", errText)
	}
	close(f.block)
}

// produce_control validates its action and reaches the producer.
func TestMCPProduceControl(t *testing.T) {
	f := newFakePorts(t)
	cs := produceMCPSession(t, f)
	if _, errText := toolText(t, cs, "produce_control", map[string]any{"id": "20261015-120000-a1b2c3", "action": "explode"}); !strings.Contains(errText, "want resume, cancel or remove") {
		t.Fatalf("bad action: %s", errText)
	}
	if _, errText := toolText(t, cs, "produce_control", map[string]any{"id": "20261015-120000-a1b2c3", "action": "remove"}); errText == "" {
		t.Fatal("removing a project that does not exist must be an error")
	}
}

// The produce tools return at once, so none has a long tool timeout.
// Mutation: internal/daemon/guard.go ServerConfig, add "produce": time.Hour to
// ToolTimeouts -> RED.
func TestProduceToolsHaveNoToolTimeout(t *testing.T) {
	d, _, _ := designFixture(t)
	cfg := d.ServerConfig("test")
	for _, name := range []string{"produce", "produce_status", "produce_edit", "produce_control"} {
		if to, ok := cfg.ToolTimeouts[name]; ok {
			t.Errorf("%s has a tool timeout of %v: it returns at once", name, to)
		}
	}
	if _, ok := cfg.ToolTimeouts["speak"]; !ok {
		t.Fatal("the test no longer reads the real ToolTimeouts map: speak is missing")
	}
}

// mcpProduceDone starts a project through the produce tool and waits for it.
func mcpProduceDone(t *testing.T, cs *mcp.ClientSession, args map[string]any) string {
	t.Helper()
	out, errText := toolText(t, cs, "produce", args)
	if errText != "" {
		t.Fatalf("produce: %s", errText)
	}
	id := out["id"].(string)
	for i := 0; i < 500; i++ {
		got, _ := toolText(t, cs, "produce_status", map[string]any{"id": id})
		if p, _ := got["project"].(map[string]any); p != nil && p["status"] == "done" {
			time.Sleep(50 * time.Millisecond) // the job releases the producer just after it saves "done"
			return id
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("never done")
	return ""
}

// Every produce field an agent sets reaches the producer.
// Mutation: internal/daemon/produce_mcp.go toolProduce, drop OutPath, Seed,
// Takes, Overwrite or AllowBattery from the produceInput -> RED.
func TestMCPProduceForwardsEveryField(t *testing.T) {
	f := newFakePorts(t)
	cs := produceMCPSession(t, f)
	outPath := filepath.Join(t.TempDir(), "v.wav")
	id := mcpProduceDone(t, cs, map[string]any{"script": "Привет. Пока.", "title": "My Title", "voice": "nar", "style": "calm",
		"preset": "reels", "seed": 77, "takes": 3, "out_path": outPath, "overwrite": true, "allow_battery": true})
	m, err := vproject.Load(filepath.Join(f.home, produceDir, id))
	if err != nil {
		t.Fatal(err)
	}
	st := m.Settings
	if m.Title != "My Title" || st.Voice != "nar" || st.Style != "calm" || st.Preset != "reels" || st.Seed != 77 || st.Takes != 3 ||
		st.OutPath != outPath || !st.Overwrite || !st.AllowBattery {
		t.Fatalf("title %q settings %+v", m.Title, st)
	}
}

// takes 0 is refused over MCP and HTTP, not read as "the preset's".
// Mutation: internal/daemon/produce_http.go explicitTakes, treat 0 as default -> RED.
func TestProduceTakesZeroRefused(t *testing.T) {
	f := newFakePorts(t)
	cs := produceMCPSession(t, f)
	if _, errText := toolText(t, cs, "produce", map[string]any{"script": "Привет.", "voice": "nar", "takes": 0}); !strings.Contains(errText, "takes must be 1..") {
		t.Fatalf("mcp: %q", errText)
	}
	_, mux := produceMux(t, newFakePorts(t))
	if rec := do(mux, http.MethodPost, "/v1/produce", `{"script":"Привет.","takes":0}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("http: %d %s", rec.Code, rec.Body)
	}
}

// remove with delete_outputs true deletes the finished voiceover files; false
// keeps them. The destructive flag must reach the producer.
// Mutation: internal/daemon/produce_mcp.go toolProduceControl, remove(in.ID, false) -> RED.
func TestMCPProduceControlRemoveDeleteOutputs(t *testing.T) {
	f := newFakePorts(t)
	cs := produceMCPSession(t, f)
	for _, del := range []bool{false, true} {
		out := filepath.Join(t.TempDir(), "v.wav")
		id := mcpProduceDone(t, cs, map[string]any{"script": "Привет.", "voice": "nar", "out_path": out})
		if _, err := os.Stat(out); err != nil {
			t.Fatalf("the project published nothing: %v", err)
		}
		args := map[string]any{"id": id, "action": "remove"}
		if del {
			args["delete_outputs"] = true
		}
		if _, errText := toolText(t, cs, "produce_control", args); errText != "" {
			t.Fatalf("remove: %s", errText)
		}
		_, err := os.Stat(out)
		if del && !os.IsNotExist(err) {
			t.Errorf("delete_outputs true left the WAV behind")
		}
		if !del && err != nil {
			t.Errorf("delete_outputs false deleted the WAV: %v", err)
		}
		if _, err := os.Stat(filepath.Join(f.home, produceDir, id)); !os.IsNotExist(err) {
			t.Errorf("the project directory is still there")
		}
	}
}

// A project that is not running cannot be "cancelled"; a chunk out of range
// says how many chunks there are; the list is capped and has no chunk arrays.
// Mutation: internal/daemon/produce_ops.go cancel, return nil for a stopped
// project -> RED; chunkDetail, return errNoProject for a bad index -> RED;
// list, drop the maxListedProjects bound -> RED.
func TestMCPProduceReadsAndGuards(t *testing.T) {
	f := newFakePorts(t)
	cs := produceMCPSession(t, f)
	id := mcpProduceDone(t, cs, map[string]any{"script": "Привет.", "voice": "nar"})
	if _, errText := toolText(t, cs, "produce_control", map[string]any{"id": id, "action": "cancel"}); !strings.Contains(errText, "not running") {
		t.Fatalf("cancel of a finished project: %q", errText)
	}
	if _, errText := toolText(t, cs, "produce_status", map[string]any{"id": id, "chunk": 9}); !strings.Contains(errText, "the project has 1 chunks") || strings.Contains(errText, "no such") {
		t.Fatalf("chunk out of range: %q", errText)
	}
	for i := 0; i < maxListedProjects+2; i++ {
		mcpProduceDone(t, cs, map[string]any{"script": "Привет.", "voice": "nar"})
	}
	list, _ := toolText(t, cs, "produce_status", map[string]any{})
	ps, _ := list["projects"].([]any)
	if len(ps) != maxListedProjects {
		t.Fatalf("list has %d projects, want %d", len(ps), maxListedProjects)
	}
	if note, _ := list["note"].(string); !strings.Contains(note, fmt.Sprintf("%d most recent", maxListedProjects)) {
		t.Fatalf("a capped list must say so: %q", note)
	}
	if ch, _ := ps[0].(map[string]any)["chunks"].([]any); len(ch) != 0 {
		t.Fatalf("the list must not carry chunk arrays: %v", ch)
	}
}

// HTTP: cancel of a stopped project is a 409, a bad chunk index a 400 in words.
func TestProduceHTTPCancelAndChunkRange(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	rec := do(mux, http.MethodPost, "/v1/produce", `{"script":"Привет.","voice":"nar"}`)
	var s vproject.Summary
	_ = json.Unmarshal(rec.Body.Bytes(), &s)
	for i := 0; i < 500; i++ {
		if r := do(mux, http.MethodGet, "/v1/produce/"+s.ID, ""); strings.Contains(r.Body.String(), `"status":"done"`) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond)
	if rec := do(mux, http.MethodPost, "/v1/produce/"+s.ID+"/cancel", ""); rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), "not running") {
		t.Fatalf("cancel: %d %s", rec.Code, rec.Body)
	}
	if rec := do(mux, http.MethodGet, "/v1/produce/"+s.ID+"/chunks/7", ""); rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "the project has 1 chunks") {
		t.Fatalf("chunk range: %d %s", rec.Code, rec.Body)
	}
}
