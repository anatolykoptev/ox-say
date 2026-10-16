package daemon

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// The job-level clone_mode on produce create pins the whole run: "reference"
// renders every chunk in reference mode (styles still steer); "ultimate"
// refuses any style at create and at delivery; "" or "auto" is the adapter's
// own rule, byte-identical to before the field existed.

// K1: a voice with ref_text — the case auto sends to ultimate — created with
// clone_mode reference renders EVERY chunk in reference mode, and a delivery
// style re-renders only that chunk without a 409.
// Mutation: produce_take.go chunkClone, drop "clone_mode" from the
// voxCloneMode body -> the job renders ultimate -> RED.
func TestCloneModeReferencePinsEveryChunk(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.\n\nЧетвёртое.","voice":"nar","clone_mode":"reference","out_path":"`+out+`"}`)
	if len(f.renders) != 3 {
		t.Fatalf("renders %d, want 3", len(f.renders))
	}
	for i, r := range f.renders {
		if r.Mode != cloneReference {
			t.Fatalf("render %d mode %q, want %q", i, r.Mode, cloneReference)
		}
	}
	if s := manifestOf(t, f, id).Settings; s.CloneModePin != cloneReference || s.CloneMode != cloneReference {
		t.Fatalf("manifest clone_pin %q clone_mode %q, want %q", s.CloneModePin, s.CloneMode, cloneReference)
	}

	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/1", `{"action":"delivery","style":"excited, lively"}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("delivery on a reference job: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if got := len(f.renders) - 3; got != 1 {
		t.Fatalf("the style op rendered %d takes, want exactly 1", got)
	}
	if got := manifestOf(t, f, id).Chunks[1].Style; got != "excited, lively" {
		t.Fatalf("chunk style %q", got)
	}
}

// K2: clone_mode ultimate + a style at create — a job style or a [style:]
// directive — is a 400 in plain words and writes no project; ultimate on a
// voice without ref_text is a 400 too.
// Mutation: produce_ops.go newManifest, drop the jobCloneMode check -> the
// create writes a project -> RED.
func TestCloneModeUltimateRefusesStylesAtCreate(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	for name, body := range map[string]string{
		"job style":   `{"script":"Привет.","voice":"nar","style":"calm","clone_mode":"ultimate","out_path":"` + out + `"}`,
		"chunk style": `{"script":"[style: excited] Привет.\n\nДва.","voice":"nar","clone_mode":"ultimate","out_path":"` + out + `"}`,
	} {
		if rec := do(mux, http.MethodPost, "/v1/produce", body); rec.Code != http.StatusBadRequest ||
			!strings.Contains(rec.Body.String(), "clone_mode ultimate") {
			t.Errorf("%s: %d %s", name, rec.Code, rec.Body)
		}
	}
	f.voice.RefText = ""
	rec := do(mux, http.MethodPost, "/v1/produce", `{"script":"Привет.","voice":"nar","clone_mode":"ultimate","out_path":"`+out+`"}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "clone_mode ultimate") {
		t.Fatalf("no ref_text: %d %s", rec.Code, rec.Body)
	}
	if entries, _ := os.ReadDir(filepath.Join(f.home, produceDir)); len(entries) != 0 || len(f.renders) != 0 {
		t.Fatalf("refused creates wrote %d projects and rendered %d takes", len(entries), len(f.renders))
	}
}

// K3: a delivery style on a clone_mode ultimate project is a 409 that names
// ultimate (on both the single-chunk and the batch route); a pause still
// applies.
// Mutation: produce_ops.go deliveryModeGate, drop the cloneUltimate branch ->
// the op is not refused with this 409 -> RED.
func TestCloneModeUltimateRefusesDeliveryStyle(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.\n\nЧетвёртое.","voice":"nar","clone_mode":"ultimate","out_path":"`+out+`"}`)
	for i, r := range f.renders {
		if r.Mode != cloneUltimate {
			t.Fatalf("render %d mode %q, want %q", i, r.Mode, cloneUltimate)
		}
	}
	before := manifestBytes(t, f, id)
	for name, req := range map[string][2]string{
		"single": {"/v1/produce/" + id + "/chunks/1", `{"action":"delivery","style":"excited"}`},
		"batch":  {"/v1/produce/" + id + "/delivery", `{"chunks":[{"n":0,"style":"x"}]}`},
	} {
		rec := do(mux, http.MethodPost, req[0], req[1])
		if rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), "ultimate") {
			t.Errorf("%s: %d %s", name, rec.Code, rec.Body)
		}
	}
	if len(f.renders) != 3 {
		t.Fatalf("the refused ops rendered: %d takes", len(f.renders))
	}
	if string(manifestBytes(t, f, id)) != string(before) {
		t.Fatal("the refused ops changed the manifest")
	}
	// A pause still applies on the ultimate job: it never touches the mode.
	if rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/1", `{"action":"delivery","pause_after":1.0}`); rec.Code != http.StatusAccepted {
		t.Fatalf("pause on an ultimate job: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if len(f.renders) != 3 {
		t.Fatalf("a pause rendered: %d takes", len(f.renders))
	}
}

// K4: auto mode is origin/main byte-for-byte. The keys were computed by
// running origin/main (c1c9ebc) against the same fakePorts, script, voice
// and seed — never this branch's code.
func TestAutoModeTakeKeysMatchMain(t *testing.T) {
	cases := []struct {
		name  string
		style string
		want  []string
		mode  string
	}{
		{"plain script: auto picks ultimate", "", []string{"17c191b4a4d20b3bebefa2b9", "86dc283870d81b1978f4e68a"}, cloneUltimate},
		{"job style: auto picks reference", "calm", []string{"c711af8e72ee13bd38324907", "99b0b191e66ce6ceaccf2237"}, cloneReference},
	}
	for _, c := range cases {
		f := newFakePorts(t)
		_, mux := produceMux(t, f)
		out := filepath.Join(t.TempDir(), "v.wav")
		body := `{"script":"Первое предложение. Второе.\n\nТретье.","voice":"nar","seed":5,"out_path":"` + out + `"`
		if c.style != "" {
			body += `,"style":"` + c.style + `"`
		}
		id := createDone(t, mux, body+"}")
		m := manifestOf(t, f, id)
		if m.Settings.CloneModePin != "" {
			t.Errorf("%s: an auto create stored clone_pin %q", c.name, m.Settings.CloneModePin)
		}
		if m.Settings.CloneMode != c.mode {
			t.Errorf("%s: refresh recorded clone_mode %q, want the resolved %q", c.name, m.Settings.CloneMode, c.mode)
		}
		var keys []string
		for _, ch := range m.Chunks {
			for _, tk := range ch.Takes {
				keys = append(keys, tk.Key)
			}
		}
		if strings.Join(keys, ",") != strings.Join(c.want, ",") {
			t.Errorf("%s: take keys %v, want %v", c.name, keys, c.want)
		}
		for i, r := range f.renders {
			if r.Mode != c.mode {
				t.Errorf("%s: render %d mode %q, want %q", c.name, i, r.Mode, c.mode)
			}
		}
	}
}

// asOldManifest rewrites a finished project's manifest the way origin/main
// wrote it: the RESOLVED clone mode in settings.clone_mode and no clone_pin
// key — the pin field did not exist. The edit happens on the JSON text, so
// the fixture is exactly what an old daemon left on disk.
func asOldManifest(t *testing.T, f *fakePorts, id, resolved string) {
	t.Helper()
	path := filepath.Join(f.home, produceDir, id, vproject.ManifestFile)
	var doc map[string]any
	raw := manifestBytes(t, f, id)
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	settings, ok := doc["settings"].(map[string]any)
	if !ok {
		t.Fatalf("manifest has no settings object:\n%s", raw)
	}
	settings["clone_mode"] = resolved
	delete(settings, "clone_pin")
	out, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, out, vproject.FileMode); err != nil {
		t.Fatal(err)
	}
	if m := manifestOf(t, f, id); m.Settings.CloneMode != resolved {
		t.Fatalf("fixture clone_mode %q, want %q", m.Settings.CloneMode, resolved)
	}
}

// F1(a): a manifest origin/main wrote — clone_mode holds the RESOLVED mode,
// no pin exists — is an auto project, not a pinned one. An English edit on
// such an auto->ultimate project re-renders in reference, exactly as on
// main; a resolved value mistaken for a pin would skip SameScript.
// Mutation: produce_ops.go refresh, read the pin from Settings.CloneMode ->
// the edit renders ultimate -> RED.
func TestOldUltimateManifestEditsAsAuto(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.\n\nЧетвёртое.","voice":"nar","out_path":"`+out+`"}`)
	asOldManifest(t, f, id, cloneUltimate)
	renders := len(f.renders)

	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/0", `{"action":"edit","text":"Welcome home, friend."}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("edit: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if m := manifestOf(t, f, id); m.Status != vproject.StatusDone {
		t.Fatalf("status %q error %q", m.Status, m.Error)
	}
	if got := len(f.renders) - renders; got != 3 {
		t.Fatalf("the edit re-rendered %d takes, want all 3 under reference", got)
	}
	for i, r := range f.renders[renders:] {
		if r.Mode != cloneReference {
			t.Fatalf("render %d mode %q, want %q", renders+i, r.Mode, cloneReference)
		}
	}
}

// F1(b): the same manifest after its voice gains a style resumes and
// renders — a mistaken pin fires create's refusal ("ultimate ignores a
// style") mid-run and fails the job instead.
// Mutation: as (a) -> resume leaves the job failed -> RED.
func TestOldUltimateManifestResumesAfterVoiceStyle(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.\n\nЧетвёртое.","voice":"nar","out_path":"`+out+`"}`)
	asOldManifest(t, f, id, cloneUltimate)
	f.voice.Style = "solemn" // the voice gained a style since the project ran

	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/resume", `{}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("resume: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
	if m := manifestOf(t, f, id); m.Status != vproject.StatusDone {
		t.Fatalf("status %q error %q", m.Status, m.Error)
	}
	for i, r := range f.renders[3:] {
		if r.Mode != cloneReference || r.Style != "solemn" {
			t.Fatalf("render %d mode %q style %q, want reference/solemn", 3+i, r.Mode, r.Style)
		}
	}
}

// F1(c): a delivery style on the same manifest gets the auto project's
// answer — a 409 naming the way to opt out — never the false claim that the
// project "was created with clone_mode ultimate".
// Mutation: produce_ops.go deliveryModeGate, read the pin from
// Settings.CloneMode -> the 409 misattributes the pin -> RED.
func TestOldUltimateManifestDeliveryReadsAsAuto(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Первое. Второе.\n\nТретье.\n\nЧетвёртое.","voice":"nar","out_path":"`+out+`"}`)
	asOldManifest(t, f, id, cloneUltimate)
	before := manifestBytes(t, f, id)

	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/chunks/1", `{"action":"delivery","style":"excited"}`)
	body := rec.Body.String()
	if rec.Code != http.StatusConflict || !strings.Contains(body, "--clone-mode reference") || strings.Contains(body, "ultimate") {
		t.Fatalf("want the auto-mode 409, got %d %s", rec.Code, body)
	}
	if len(f.renders) != 3 {
		t.Fatalf("the refused op rendered: %d takes", len(f.renders))
	}
	if string(manifestBytes(t, f, id)) != string(before) {
		t.Fatal("the refused op changed the manifest")
	}
}

// F1(d): an auto->reference manifest — a chunk style resolved it to
// reference on main — clearing that style gets the auto project's answer
// (409), not the unconditional pass a mistaken pin gives.
// Mutation: as (c) -> the op is accepted -> RED.
func TestOldReferenceManifestClearingStyleReadsAsAuto(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"[style: calm] Первое. Второе.\n\nТретье. Четвёртое.","voice":"nar","out_path":"`+out+`"}`)
	asOldManifest(t, f, id, cloneReference)
	before := manifestBytes(t, f, id)

	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/delivery", `{"chunks":[{"n":0,"style":""}]}`)
	body := rec.Body.String()
	if rec.Code != http.StatusConflict || !strings.Contains(body, "--clone-mode reference") || strings.Contains(body, "ultimate") {
		t.Fatalf("want the auto-mode 409, got %d %s", rec.Code, body)
	}
	if string(manifestBytes(t, f, id)) != string(before) {
		t.Fatal("the refused op changed the manifest")
	}
}

// K5: an invalid clone_mode is a 400 on HTTP and an error on MCP before a
// project exists, in the same words say's validator uses.
// Mutation: produce_ops.go newManifest, drop the jobCloneMode check -> the
// create is accepted -> RED.
func TestCloneModeInvalidIsRefused(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	rec := do(mux, http.MethodPost, "/v1/produce", `{"script":"Привет.","voice":"nar","clone_mode":"bogus"}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "auto|reference|ultimate") {
		t.Fatalf("http: %d %s", rec.Code, rec.Body)
	}
	cs := produceMCPSession(t, newFakePorts(t))
	if _, errText := toolText(t, cs, "produce", map[string]any{"script": "Привет.", "voice": "nar", "clone_mode": "bogus"}); !strings.Contains(errText, "auto|reference|ultimate") {
		t.Fatalf("mcp: %s", errText)
	}
	// "auto" is the explicit spelling of the default and is accepted.
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"Привет.","voice":"nar","clone_mode":"auto","out_path":"`+out+`"}`)
	if got := manifestOf(t, f, id).Settings.CloneModePin; got != cloneAuto {
		t.Fatalf("explicit auto stored %q", got)
	}
}
