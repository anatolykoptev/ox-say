package daemon

import (
	"encoding/json"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// The delivery op changes a chunk's style and/or pause after render. A style
// change re-renders only that chunk; a pause change only re-assembles; a
// batch of changes launches once.

func createDone(t *testing.T, mux *http.ServeMux, body string) string {
	t.Helper()
	rec := do(mux, http.MethodPost, "/v1/produce", body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	var s vproject.Summary
	if err := json.Unmarshal(rec.Body.Bytes(), &s); err != nil || s.ID == "" {
		t.Fatalf("create answer: %v %s", err, rec.Body)
	}
	waitDoneHTTP(t, mux, s.ID)
	return s.ID
}

func waitDoneHTTP(t *testing.T, mux *http.ServeMux, id string) {
	t.Helper()
	for i := 0; i < 500; i++ {
		rec := do(mux, http.MethodGet, "/v1/produce/"+id, "")
		body := rec.Body.String()
		if strings.Contains(body, `"status":"done"`) || strings.Contains(body, `"status":"review"`) ||
			strings.Contains(body, `"status":"failed"`) {
			time.Sleep(50 * time.Millisecond) // the job releases the producer just after it saves its end state
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the job never left running")
}

func manifestOf(t *testing.T, f *fakePorts, id string) *vproject.Manifest {
	t.Helper()
	m, err := vproject.Load(filepath.Join(f.home, produceDir, id))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func manifestBytes(t *testing.T, f *fakePorts, id string) []byte {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(f.home, produceDir, id, vproject.ManifestFile))
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func countEvent(f *fakePorts, name string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, e := range f.events {
		if e == name {
			n++
		}
	}
	return n
}

func takeKeys(c vproject.Chunk) map[string]bool {
	out := map[string]bool{}
	for _, tk := range c.Takes {
		out[tk.Key] = true
	}
	return out
}

// D1 (C1 gate): on a clone job already in reference mode (here via a job
// style, the only route to reference today), styling one chunk re-renders
// ONLY that chunk; the others keep their picks and take keys.
// Mutation: produce_ops.go applyDelivery, treat the job's mode as auto
// (`oldMode := cloneUltimate`) -> the op is refused -> RED.
func TestDeliveryStyleRendersOnlyThatChunk(t *testing.T) {
	f := newFakePorts(t)
	d, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.\n\nЧетвёртое.","voice":"nar","style":"calm","out_path":"`+out+`"}`)
	m := manifestOf(t, f, id)
	if m.Settings.CloneModePin != "" || len(m.Chunks) != 3 || len(f.renders) != 3 {
		t.Fatalf("setup: requested mode %q chunks %d renders %d", m.Settings.CloneModePin, len(m.Chunks), len(f.renders))
	}
	for i, r := range f.renders {
		if r.Mode != cloneReference {
			t.Fatalf("render %d mode %q, want %q", i, r.Mode, cloneReference)
		}
	}
	keys := make([]map[string]bool, len(m.Chunks))
	picks := make([]string, len(m.Chunks))
	for i, c := range m.Chunks {
		keys[i], picks[i] = takeKeys(c), c.Pick
	}

	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/1", `{"action":"delivery","style":"excited, lively"}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("delivery: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if got := len(f.renders) - 3; got != 1 {
		t.Fatalf("the style op rendered %d takes, want exactly 1", got)
	}
	m = manifestOf(t, f, id)
	for _, i := range []int{0, 2} {
		if m.Chunks[i].Pick != picks[i] || len(m.Chunks[i].Takes) != len(keys[i]) {
			t.Fatalf("chunk %d changed: pick %q takes %+v", i, m.Chunks[i].Pick, m.Chunks[i].Takes)
		}
		for k := range keys[i] {
			if !takeKeys(m.Chunks[i])[k] {
				t.Fatalf("chunk %d lost take %s", i, k)
			}
		}
	}
	if m.Chunks[1].Style != "excited, lively" || m.Chunks[1].Pick == picks[1] || !takeKeys(m.Chunks[1])[m.Chunks[1].Pick] {
		t.Fatalf("chunk 1 after the op: %+v", m.Chunks[1])
	}
	// chunkDetail reflects the new style and the pause it kept.
	det, err := d.prod.chunkDetail(id, 1)
	if err != nil || det.Style != "excited, lively" || det.PauseAfter != m.Chunks[1].PauseAfter {
		t.Fatalf("chunkDetail: %+v %v", det.Chunk, err)
	}
}

// D2 (C1 refuse): on a clone job in auto mode (every chunk ultimate), a
// style would flip the whole job to reference and re-render every chunk:
// the op is refused with 409 and nothing changes, nothing renders.
// Mutation: produce_ops.go applyDelivery, drop the refusal -> RED.
func TestDeliveryStyleOnAutoCloneIsRefused(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.\n\nЧетвёртое.","voice":"nar","out_path":"`+out+`"}`)
	m := manifestOf(t, f, id)
	if m.Settings.CloneModePin != "" {
		t.Fatalf("setup: requested mode %q, want auto", m.Settings.CloneModePin)
	}
	for i, r := range f.renders {
		if r.Mode != cloneUltimate {
			t.Fatalf("render %d mode %q, want %q", i, r.Mode, cloneUltimate)
		}
	}
	before := manifestBytes(t, f, id)
	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/1", `{"action":"delivery","style":"excited"}`)
	if rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), "clone_mode reference") {
		t.Fatalf("want 409 with the reference hint: %d %s", rec.Code, rec.Body)
	}
	if len(f.renders) != 3 {
		t.Fatalf("the refused op rendered: %d takes", len(f.renders))
	}
	if string(manifestBytes(t, f, id)) != string(before) {
		t.Fatal("the refused op changed the manifest")
	}
	// A pause still works on the auto-mode job: it never touches the mode.
	rec = do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/1", `{"action":"delivery","pause_after":1.0}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("pause on an auto clone: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if len(f.renders) != 3 {
		t.Fatalf("a pause rendered: %d takes", len(f.renders))
	}
}

// D3 (C4): a pause-only change re-assembles the file without a single
// render and never enters the battery/dictation checkpoint; the WAV's
// length moves by the pause delta within a frame.
// Mutation: produce.go run, ignore the assemble-only flag -> "quiet" events -> RED.
func TestDeliveryPauseReassemblesOnly(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.\n\nЧетвёртое.","voice":"nar","out_path":"`+out+`"}`)
	m := manifestOf(t, f, id)
	pause0 := m.Chunks[1].PauseAfter
	_, dur0 := wavInfoFile(out)
	renders, quiet, hears, norms := len(f.renders), countEvent(f, "quiet"), f.hears, f.normCalls

	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/delivery", `{"chunks":[{"n":1,"pause_after":1.2}]}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("delivery: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if got := len(f.renders) - renders; got != 0 {
		t.Fatalf("a pause rendered %d takes", got)
	}
	if got := countEvent(f, "quiet") - quiet; got != 0 {
		t.Fatalf("a pause entered %d checkpoints", got)
	}
	if got := f.hears - hears; got != 0 {
		t.Fatalf("a pause transcribed %d times", got)
	}
	if got := f.normCalls - norms; got != 1 {
		t.Fatalf("assemblies ran %d times, want 1", got)
	}
	_, dur1 := wavInfoFile(out)
	if got, want := dur1-dur0, 1.2-pause0; math.Abs(got-want) > 2.0/48000 {
		t.Fatalf("duration moved %.4f s, want %.4f s", got, want)
	}
	if m = manifestOf(t, f, id); m.Chunks[1].PauseAfter != 1.2 {
		t.Fatalf("pause_after %v", m.Chunks[1].PauseAfter)
	}
}

// F2: a stored pause_after of 0 clears the chunk's pause — unlike the
// [pause Ns] directive, the delivery field takes 0 as "no pause" — and the
// assembled file shrinks by the old pause without a single render.
// Mutation: produce_ops.go validateDelivery, restore the plain range check
// -> the 0 is a 400 -> RED.
func TestDeliveryPauseZeroClearsIt(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.\n\nЧетвёртое.","voice":"nar","out_path":"`+out+`"}`)
	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/1", `{"action":"delivery","pause_after":1.2}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("set: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	_, dur := wavInfoFile(out)
	renders := len(f.renders)

	rec = do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/1", `{"action":"delivery","pause_after":0}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("clear: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if got := len(f.renders) - renders; got != 0 {
		t.Fatalf("clearing a pause rendered %d takes", got)
	}
	_, cleared := wavInfoFile(out)
	if got := dur - cleared; math.Abs(got-1.2) > 2.0/48000 {
		t.Fatalf("the assembled file shrank %.4f s, want the 1.2 s pause", got)
	}
	if m := manifestOf(t, f, id); m.Chunks[1].PauseAfter != 0 {
		t.Fatalf("pause_after %v, want 0", m.Chunks[1].PauseAfter)
	}
}

// The stored-field bound directly: 0 is "clear", a real pause is the
// directive's range, and NaN/±Inf are refused even though no transport can
// carry them today.
// Mutation: produce_ops.go deliveryPauseOK, restore the plain range check
// -> 0, NaN and ±Inf are judged by it -> RED.
func TestValidateDeliveryPauseBounds(t *testing.T) {
	m := &vproject.Manifest{Chunks: []vproject.Chunk{{Index: 0}}}
	n, zero := 0, 0.0
	if _, err := validateDelivery(m, []deliveryEntry{{N: &n, PauseAfter: &zero}}); err != nil {
		t.Fatalf("pause 0 refused: %v", err)
	}
	nan, inf := math.NaN(), math.Inf(1)
	for name, p := range map[string]float64{"NaN": nan, "+Inf": inf, "-Inf": -inf, "below min": 0.01, "over max": 11} {
		if _, err := validateDelivery(m, []deliveryEntry{{N: &n, PauseAfter: &p}}); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}

// A style set to what the chunk already resolves to — here the job's style
// through the fallback chain — renders nothing and supersedes nothing, but it
// is STORED: the pin must survive a later change of the job's or voice's style
// (#183.a).
// Mutation: produce_ops.go deliver, compare with c.Style instead of the
// effective style -> the op supersedes and rewrites -> RED.
// Mutation: produce_ops.go deliver, drop `c.Style = styles[i]` -> the pin is lost -> RED.
func TestDeliveryStyleMatchingTheEffectiveIsANoOp(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.\n\nЧетвёртое.","voice":"nar","style":"calm","out_path":"`+out+`"}`)
	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/1", `{"action":"delivery","style":"calm"}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("delivery: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if got := len(f.renders) - 3; got != 0 {
		t.Fatalf("a no-op style rendered %d takes", got)
	}
	m := manifestOf(t, f, id)
	if m.Chunks[1].Style != "calm" || len(m.Chunks[1].Superseded) != 0 {
		t.Fatalf("an explicit pin equal to the inherited style: stored %q (want calm), superseded %v", m.Chunks[1].Style, m.Chunks[1].Superseded)
	}
}

// Clearing a style on a chunk that has none of its own changes nothing it
// stores and nothing it renders: no supersede, no render, and the run is the
// assemble-only one that never enters the battery/dictation checkpoint
// (#183.b).
// Mutation: produce_ops.go deliver, supersede on `styles[i] != eff[*e.N]` (the
// stored request against the effective style) -> a wasted render -> RED.
func TestDeliveryClearingAnInheritedStyleIsANoOpRun(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.\n\nЧетвёртое.","voice":"nar","style":"calm","out_path":"`+out+`"}`)
	renders, quiet := len(f.renders), countEvent(f, "quiet")
	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/1", `{"action":"delivery","style":""}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("delivery: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if got := len(f.renders) - renders; got != 0 {
		t.Fatalf("clearing an inherited style rendered %d takes", got)
	}
	if got := countEvent(f, "quiet") - quiet; got != 0 {
		t.Fatalf("a no-op entered %d checkpoints", got)
	}
	if m := manifestOf(t, f, id); len(m.Chunks[1].Superseded) != 0 || m.Chunks[1].Style != "" {
		t.Fatalf("a no-op changed chunk 1: style %q superseded %v", m.Chunks[1].Style, m.Chunks[1].Superseded)
	}
}

// D4 (C3): style A -> B -> A: the revert renders nothing and the pick is
// A's original take, because the superseded take was kept on disk.
// Mutation: produce.go pruneTakes, drop Superseded from keep -> the revert
// renders again -> RED.
func TestDeliveryStyleRevertHitsTheTakeCache(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.\n\nЧетвёртое.","voice":"nar","style":"calm","out_path":"`+out+`"}`)
	pickA := manifestOf(t, f, id).Chunks[0].Pick

	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/0", `{"action":"delivery","style":"excited"}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("style B: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if got := len(f.renders); got != 4 {
		t.Fatalf("style B rendered %d takes total, want 4", got)
	}
	m := manifestOf(t, f, id)
	if m.Chunks[0].Pick == pickA || len(m.Chunks[0].Superseded) == 0 || m.Chunks[0].Superseded[0] != pickA {
		t.Fatalf("after B: pick %q superseded %v", m.Chunks[0].Pick, m.Chunks[0].Superseded)
	}

	rec = do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/0", `{"action":"delivery","style":""}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("style revert: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if got := len(f.renders); got != 4 {
		t.Fatalf("the revert rendered, total %d takes", got)
	}
	if m = manifestOf(t, f, id); m.Chunks[0].Pick != pickA {
		t.Fatalf("reverted pick %q, want the original %q", m.Chunks[0].Pick, pickA)
	}
}

// D5: one batch changes N chunks under ONE launch; every entry is
// validated before anything is applied, so an invalid entry fails the
// whole request and leaves the manifest untouched.
// Mutation: produce_ops.go applyDelivery, skip the validation pass -> the
// invalid batch applies -> RED.
func TestDeliveryBatchIsAtomic(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.\n\nЧетвёртое.","voice":"nar","style":"calm","out_path":"`+out+`"}`)
	renders, norms := len(f.renders), f.normCalls

	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/delivery",
		`{"chunks":[{"n":0,"style":"excited"},{"n":1,"style":"warm","pause_after":0.9},{"n":2,"pause_after":0.6}]}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("batch: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if got := len(f.renders) - renders; got != 2 {
		t.Fatalf("the batch rendered %d takes, want 2", got)
	}
	if got := f.normCalls - norms; got != 1 {
		t.Fatalf("the batch assembled %d times, want 1", got)
	}
	m := manifestOf(t, f, id)
	if m.Chunks[0].Style != "excited" || m.Chunks[1].Style != "warm" || m.Chunks[1].PauseAfter != 0.9 || m.Chunks[2].PauseAfter != 0.6 {
		t.Fatalf("batch result: %+v", m.Chunks)
	}

	before := manifestBytes(t, f, id)
	for name, body := range map[string]string{
		"bad index":      `{"chunks":[{"n":9,"style":"x"}]}`,
		"pause range":    `{"chunks":[{"n":0,"pause_after":99}]}`,
		"unknown entry":  `{"chunks":[{"n":0,"style":"x","tempo":1.1}]}`,
		"unknown top":    `{"chunks":[],"foo":1}`,
		"empty entry":    `{"chunks":[{"n":0}]}`,
		"empty list":     `{"chunks":[]}`,
		"dup chunk":      `{"chunks":[{"n":0,"style":"a"},{"n":0,"pause_after":0.5}]}`,
		"valid+invalid":  `{"chunks":[{"n":0,"style":"atomic"},{"n":1,"pause_after":99}]}`,
		"negative pause": `{"chunks":[{"n":0,"pause_after":-1}]}`,
	} {
		rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/delivery", body)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: %d %s", name, rec.Code, rec.Body)
		}
		if string(manifestBytes(t, f, id)) != string(before) {
			t.Fatalf("%s changed the manifest", name)
		}
	}
	// The same strictness holds on the single-chunk route.
	before = manifestBytes(t, f, id)
	for name, body := range map[string]string{
		"no field":       `{"action":"delivery"}`,
		"unknown":        `{"action":"delivery","style":"x","bogus":1}`,
		"pause range":    `{"action":"delivery","pause_after":0.01}`,
		"pause too long": `{"action":"delivery","pause_after":300}`,
	} {
		rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/0", body)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("single %s: %d %s", name, rec.Code, rec.Body)
		}
		if string(manifestBytes(t, f, id)) != string(before) {
			t.Fatalf("single %s changed the manifest", name)
		}
	}
}

// D7: the same single-chunk style change through MCP produce_edit, plus a
// batch call (the tool takes both forms).
func TestProduceEditDeliveryOverMCP(t *testing.T) {
	f := newFakePorts(t)
	cs := produceMCPSession(t, f)
	id := mcpProduceDone(t, cs, map[string]any{"script": "Первое. Второе.\n\nТретье.", "voice": "nar", "style": "calm"})
	renders := len(f.renders)

	ed, errText := toolText(t, cs, "produce_edit", map[string]any{"id": id, "chunk": 1, "action": "delivery", "style": "excited"})
	if errText != "" || ed["project"] == nil {
		t.Fatalf("delivery: %v %s", ed, errText)
	}
	for i := 0; i < 500; i++ {
		got, _ := toolText(t, cs, "produce_status", map[string]any{"id": id})
		if p, _ := got["project"].(map[string]any); p != nil && p["status"] == "done" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond)
	if got := len(f.renders) - renders; got != 1 {
		t.Fatalf("MCP delivery rendered %d takes, want 1", got)
	}
	m := manifestOf(t, f, id)
	if m.Chunks[1].Style != "excited" {
		t.Fatalf("chunk style %q", m.Chunks[1].Style)
	}

	// Batch form: one call, one launch, pause-only so zero renders.
	if _, errText := toolText(t, cs, "produce_edit", map[string]any{"id": id, "action": "delivery",
		"chunks": []any{map[string]any{"n": 0, "pause_after": 0.9}, map[string]any{"n": 1, "pause_after": 1.1}}}); errText != "" {
		t.Fatalf("batch delivery: %s", errText)
	}
	for i := 0; i < 500; i++ {
		got, _ := toolText(t, cs, "produce_status", map[string]any{"id": id})
		if p, _ := got["project"].(map[string]any); p != nil && p["status"] == "done" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond)
	if got := len(f.renders) - renders; got != 1 {
		t.Fatalf("the pause batch rendered %d takes, want 0", got)
	}
	m = manifestOf(t, f, id)
	if m.Chunks[0].PauseAfter != 0.9 || m.Chunks[1].PauseAfter != 1.1 {
		t.Fatalf("batch pauses: %+v", m.Chunks)
	}
}
