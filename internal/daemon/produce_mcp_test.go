package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
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
