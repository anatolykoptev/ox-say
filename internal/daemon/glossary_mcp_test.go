package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/anatolykoptev/ox-say/internal/glossary"
)

// glossary_add files over MCP what POST /v1/glossary files over HTTP: a first
// call creates a candidate the glossary list shows, a second call with a new
// sentence counts a sighting on it, a conflict and an invalid pair come back
// as readable results an agent can act on — never as protocol errors.
// Mutation: glossary_mcp.go toolGlossaryAdd, replace d.glossaryAdd with
// d.Glossary.AddChecked(in.Heard, in.Meant, in.Context, false) — "call the
// store directly" -> RED (the vetted new spelling stays a candidate and the
// corrector never sees it).
// Mutation: drop the errors.Is(err, glossary.ErrInvalid) branch -> RED (the
// invalid filings come back as tool errors and callMCP fails before the
// result is read).
func TestMCPGlossaryAddJourney(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	cs := mcpSession(t, d)

	// «окс» is a three-letter heard form: its own threshold is three distinct
	// sentences, so two filings leave it a candidate.
	out := callMCP(t, cs, "glossary_add", map[string]any{
		"heard": "окс", "meant": "OxSay", "context": "запусти окс через ZQXJKNWV утром"})
	if out["result"] != "filed" || out["status"] != "candidate" || out["seen"] != float64(1) {
		t.Fatalf("first filing = %v, want a new candidate seen once", out)
	}

	rec := call(t, mux, http.MethodGet, "/v1/glossary", "")
	var list struct {
		Pairs []glossary.Pair `json:"pairs"`
	}
	if rec.Code != http.StatusOK || json.Unmarshal(rec.Body.Bytes(), &list) != nil || len(list.Pairs) != 1 {
		t.Fatalf("GET /v1/glossary after the filing: %d %s", rec.Code, rec.Body)
	}
	if p := list.Pairs[0]; p.Heard != "окс" || p.Meant != "OxSay" || p.Status != glossary.Candidate {
		t.Fatalf("listed pair = %+v", p)
	}

	out = callMCP(t, cs, "glossary_add", map[string]any{
		"heard": "окс", "meant": "OxSay", "context": "открой окс позже"})
	if out["result"] != "sighting" || out["status"] != "candidate" || out["seen"] != float64(2) {
		t.Fatalf("second filing = %v, want a sighting on the candidate seen twice", out)
	}

	// The tool shares the daemon's dictionary verdict: an established meant
	// (дэвин → Devin is filed and activates over HTTP) lends its evidence to a
	// new vetted spelling filed over MCP, so «девин» is active on its first
	// sentence, and the daemon's own write drops the pair cache — the
	// corrector sees it at once.
	for _, ctx := range []string{"спроси дэвин сегодня", "открой дэвин завтра"} {
		rec = call(t, mux, http.MethodPost, "/v1/glossary",
			`{"heard":"дэвин","meant":"Devin","context":"`+ctx+`"}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("HTTP add %q: %d %s", ctx, rec.Code, rec.Body)
		}
	}
	d.glossaryPairs() // prime the pair cache, as a dictation does
	out = callMCP(t, cs, "glossary_add", map[string]any{
		"heard": "девин", "meant": "Devin", "context": "закрой девин вечером"})
	if out["result"] != "filed" || out["status"] != "active" || out["seen"] != float64(1) {
		t.Fatalf("a vetted new spelling of an established meant = %v, want filed and active", out)
	}
	if got := d.corrector()("открой девин"); got != "открой Devin" {
		t.Fatalf("corrector after the MCP filing = %q, want the pair applied", got)
	}

	// Conflict: «окс» already maps to OxSay; the answer names the other term.
	out = callMCP(t, cs, "glossary_add", map[string]any{
		"heard": "окс", "meant": "OxPulse", "context": "закрой окс"})
	if out["result"] != "conflict" || !strings.Contains(out["reason"].(string), "OxSay") {
		t.Fatalf("conflict = %v, want the existing mapping named", out)
	}

	// Invalid: the sentence does not carry the heard form; a bad heard form
	// is refused too. Both are results, not tool errors — callMCP fails the
	// test on res.IsError, so reaching the result proves it.
	for _, args := range []map[string]any{
		{"heard": "окс", "meant": "OxSay", "context": "совсем другая фраза"},
		{"heard": "node.js", "meant": "Node.js", "context": "open node.js"},
		{"heard": "", "meant": "OxSay", "context": "запусти окс"},
	} {
		if out = callMCP(t, cs, "glossary_add", args); out["result"] != "invalid" || out["reason"] == "" {
			t.Errorf("glossary_add(%v) = %v, want invalid with a reason", args, out)
		}
	}
}

// The file holds only a hash of the context sentence: the sentence itself —
// here carrying a sentinel word — never lands in glossary.json.
// Mutation: store.go AddChecked, append context to p.Sightings instead of
// hash8(key(context)) -> RED (the sentinel is on disk).
func TestMCPGlossaryAddStoresNoSentence(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	cs := mcpSession(t, d)

	const sentinel = "ZQXJKNWV"
	callMCP(t, cs, "glossary_add", map[string]any{
		"heard": "окс", "meant": "OxSay", "context": "запусти окс через " + sentinel + " утром"})

	raw, err := os.ReadFile(filepath.Join(d.Cfg.Home, glossary.FileName))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), sentinel) || strings.Contains(string(raw), "запусти окс через") {
		t.Fatalf("glossary.json holds the dictated sentence: %s", raw)
	}
	pairs, err := d.Glossary.List()
	if err != nil || len(pairs) != 1 || len(pairs[0].Sightings) != 1 {
		t.Fatalf("pairs = %+v err %v, want one sighting hash", pairs, err)
	}
}

// The served server's initialize answer carries the instructions that point
// an agent at glossary_add for dictated messages — mcpSession builds a bare
// server, so this session goes through d.NewMCPServer the way cmdServe does.
// Mutation: mcp.go NewMCPServer, pass nil ServerOptions -> RED.
func TestMCPServerInstructionsPointAtGlossaryAdd(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	srv := d.NewMCPServer(&mcp.Implementation{Name: "t", Version: "0"})
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

	got := cs.InitializeResult().Instructions
	if !strings.Contains(got, "glossary_add") || !strings.Contains(got, "dictated") {
		t.Fatalf("instructions = %q, want a pointer to glossary_add for dictated messages", got)
	}
	for _, w := range []string{"meeting_live", "after", "next", "preview", "meeting_get"} {
		if !strings.Contains(got, w) {
			t.Fatalf("instructions lack %q for following a call: %q", w, got)
		}
	}
}
