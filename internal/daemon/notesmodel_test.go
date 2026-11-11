package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// notesDaemon is a daemon whose notes engine is a fake binary and whose
// models dir holds the catalog files named in with (file names only).
func notesDaemon(t *testing.T, files ...string) *Daemon {
	t.Helper()
	var modelsDir string
	d, _ := meetingFixture(t, func(c *config.Config) {
		bin := filepath.Join(filepath.Dir(c.Home), "ox-llm")
		_ = os.MkdirAll(filepath.Dir(bin), 0o755)
		_ = os.WriteFile(bin, []byte("x"), 0o755)
		c.NotesBin = bin
		modelsDir = c.ModelsDir()
	})
	if len(files) > 0 {
		_ = os.MkdirAll(modelsDir, 0o755)
		for _, f := range files {
			if err := os.WriteFile(filepath.Join(modelsDir, f), []byte("x"), 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}
	return d
}

// The upgrade journey, end to end: a Mac with only the 4B file, no saved
// choice and no env resolves to it and notes stay available — the 9B is the
// reported default, not a forced download. F1's falsification deletes the
// installed branch of the automatic pick and this goes RED.
func TestAnUpdatedUserWithOnlyThe4BKeepsNotes(t *testing.T) {
	d := notesDaemon(t, config.NotesModelFile)
	res := d.notesResolve()
	if res.ID != "qwen3.5-4b" || res.Source != config.NotesSourceAutomatic || !res.Installed {
		t.Fatalf("resolved = %+v, want the installed 4B on the automatic source", res)
	}
	n := d.Status().Notes
	if !n.Available || n.Model != "qwen3.5-4b" {
		t.Fatalf("notes = %+v, want available on qwen3.5-4b", n)
	}
}

// A saved choice wins over automatic but loses to OX_SAY_NOTES_MODEL (F2's
// surface at the daemon: the choice file the PUT wrote is read back, and the
// env pin outranks it).
func TestNotesResolveReadsTheSavedChoiceAndEnvWins(t *testing.T) {
	d := notesDaemon(t, config.NotesModelFile, "Qwen3.5-9B-Q4_K_M.gguf")
	if err := writeNotesChoice(d.Cfg.Home, config.NotesChoice{ID: "qwen3.5-9b"}); err != nil {
		t.Fatal(err)
	}
	if res := d.notesResolve(); res.ID != "qwen3.5-9b" || res.Source != config.NotesSourceSaved {
		t.Fatalf("saved choice: %+v", res)
	}
	d.Cfg.NotesModel = filepath.Join(d.Cfg.ModelsDir(), config.NotesModelFile)
	d.Cfg.NotesModelEnv = true
	if res := d.notesResolve(); res.ID != "qwen3.5-4b" || res.Source != config.NotesSourceEnv {
		t.Fatalf("env pin over the saved choice: %+v", res)
	}
}

// The choice file: 0600, written atomically (temp + rename, no half file),
// and a malformed file reads as "no choice" so a hand-edited one cannot take
// notes down.
func TestTheNotesChoiceFileIsPrivateAndAtomic(t *testing.T) {
	d := notesDaemon(t)
	path := filepath.Join(d.Cfg.Home, notesChoiceFile)
	if err := os.MkdirAll(d.Cfg.Home, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := writeNotesChoice(d.Cfg.Home, config.NotesChoice{ID: "qwen3.5-9b"}); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("choice file mode = %v, %v; want 0600", st, err)
	}
	if ch := readNotesChoice(d.Cfg.Home); ch == nil || ch.ID != "qwen3.5-9b" {
		t.Fatalf("read back %+v, want the saved 9B id", ch)
	}
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Fatal("the temp file was left behind")
	}
	for _, bad := range []string{
		"not json",
		`{"id":"no-such-model"}`,
		`{"path":"relative/model.gguf"}`,
		`{}`,
	} {
		if err := os.WriteFile(path, []byte(bad), 0o600); err != nil {
			t.Fatal(err)
		}
		if ch := readNotesChoice(d.Cfg.Home); ch != nil {
			t.Fatalf("%s read as %+v, want no choice", bad, ch)
		}
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if ch := readNotesChoice(d.Cfg.Home); ch != nil {
		t.Fatal("a missing file is a choice")
	}
}

// GET /v1/meetings/notes-model answers the resolved model, its source and
// every catalog row; PUT saves the pick, stops the child and answers the new
// state. Refusals come first: unknown id, relative path, empty body fields.
func TestNotesModelGetAndPut(t *testing.T) {
	d, mux := meetingFixture(t, func(c *config.Config) {
		bin := filepath.Join(filepath.Dir(c.Home), "ox-llm")
		_ = os.MkdirAll(filepath.Dir(bin), 0o755)
		_ = os.WriteFile(bin, []byte("x"), 0o755)
		c.NotesBin = bin
	})
	_ = os.MkdirAll(d.Cfg.ModelsDir(), 0o755)
	if err := os.WriteFile(filepath.Join(d.Cfg.ModelsDir(), config.NotesModelFile), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	rec := call(t, mux, http.MethodGet, "/v1/meetings/notes-model", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET: %d %s", rec.Code, bodyText(rec))
	}
	var get struct {
		Model, Source string
		Choices       []struct{ ID, Kind string }
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &get); err != nil {
		t.Fatal(err)
	}
	if get.Model != "qwen3.5-4b" || get.Source != "automatic" {
		t.Fatalf("GET = %+v, want the automatic 4B", get)
	}
	if len(get.Choices) != len(config.NotesCatalog) {
		t.Fatalf("choices = %+v, want one per catalog row", get.Choices)
	}
	for _, body := range []string{`{"id":"no-such-model"}`, `{"path":"rel/x.gguf"}`, `{"id":""}`, `{}`} {
		if rec := call(t, mux, http.MethodPut, "/v1/meetings/notes-model", body); rec.Code != http.StatusBadRequest {
			t.Fatalf("PUT %s: %d, want 400", body, rec.Code)
		}
	}
	rec = call(t, mux, http.MethodPut, "/v1/meetings/notes-model", `{"id":"qwen3.5-9b"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT: %d %s", rec.Code, bodyText(rec))
	}
	if res := d.notesResolve(); res.ID != "qwen3.5-9b" || res.Source != config.NotesSourceSaved {
		t.Fatalf("after PUT: %+v", res)
	}
}

// A catalog model this Mac cannot run is refused before the choice is saved,
// with NotesBlock's own verdict — the same unsupported sentence /status
// gives — and the same refusal stands in front of an install that names it.
// On the injected 16 GB Mac the 27B (floor 32 GB) is refused while the 9B
// (floor 16 GB) still switches. Mutations:
// internal/daemon/notesmodel.go handleNotesModelPut, delete the
// NotesReasonUnsupported arm -> RED (the 27B saves);
// internal/daemon/meetings.go InstallNotesModel, delete the NotesBlock check
// -> RED (the 27B download starts).
func TestNotesModelPutRefusesAModelTheMacCannotRun(t *testing.T) {
	d, mux := meetingFixture(t, func(c *config.Config) {
		bin := filepath.Join(filepath.Dir(c.Home), "ox-llm")
		_ = os.MkdirAll(filepath.Dir(bin), 0o755)
		_ = os.WriteFile(bin, []byte("x"), 0o755)
		c.NotesBin = bin
		c.HostMemoryBytes = 16 * gib // the injected 16 GB Mac
	})
	_ = os.MkdirAll(d.Cfg.ModelsDir(), 0o755)
	if err := os.WriteFile(filepath.Join(d.Cfg.ModelsDir(), config.NotesModelFile), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	rec := call(t, mux, http.MethodPut, "/v1/meetings/notes-model", `{"id":"qwen3.8-27b-uncensored"}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("PUT the 27B on 16 GB: %d %s, want 400", rec.Code, bodyText(rec))
	}
	if got := bodyText(rec); !strings.Contains(got, "needs at least 32 GB of memory; this Mac has 16 GB.") {
		t.Fatalf("PUT answer = %s, want NotesBlock's unsupported sentence", got)
	}
	if ch := readNotesChoice(d.Cfg.Home); ch != nil {
		t.Fatalf("a refused PUT saved a choice: %+v", ch)
	}
	// The install of the same model refuses with the same words — before any
	// download starts.
	if err := d.InstallNotesModel("qwen3.8-27b-uncensored"); err == nil ||
		!strings.Contains(err.Error(), "needs at least 32 GB of memory; this Mac has 16 GB.") {
		t.Fatalf("install of the 27B on 16 GB: err = %v, want the unsupported refusal", err)
	}
	if d.notesInstalling() != 0 {
		t.Fatal("a download started for a model this Mac cannot run")
	}
	// And the model whose floor the Mac meets still switches: the gate is the
	// entry's own MinMemoryGB, not a blanket refusal.
	rec = call(t, mux, http.MethodPut, "/v1/meetings/notes-model", `{"id":"qwen3.5-9b"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT the 9B on 16 GB: %d %s, want 200", rec.Code, bodyText(rec))
	}
	if res := d.notesResolve(); res.ID != "qwen3.5-9b" {
		t.Fatalf("after PUT: %+v, want the saved 9B", res)
	}
}

// The PUT's own-model gate: only a canonical absolute .gguf that really is a
// GGUF file is saved — every other path is a reasoned 400 and leaves no
// choice behind. Mutation: internal/daemon/notesmodel.go
// notesModelPathError, `return ""` unconditionally -> every row RED.
func TestNotesModelPutValidatesTheOwnModelPath(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_LLM", "1")
	t.Setenv("OXSAY_FAKE_DIR", dir)
	d, mux := meetingFixture(t, func(c *config.Config) {
		c.NotesBin = os.Args[0]
		c.HostMemoryBytes = 32 << 30 // the test Mac reports its memory
	})
	gguf := filepath.Join(dir, "mine.gguf")
	if err := os.WriteFile(gguf, writeTestGGUF(t, 3, nil), 0o600); err != nil {
		t.Fatal(err)
	}
	notGGUF := filepath.Join(dir, "mine.bin")
	if err := os.WriteFile(notGGUF, append([]byte("GGUF"), make([]byte, 64)...), 0o600); err != nil {
		t.Fatal(err)
	}
	badMagic := filepath.Join(dir, "bad.gguf")
	if err := os.WriteFile(badMagic, []byte("not a model, just bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	empty := filepath.Join(dir, "empty.gguf")
	if err := os.WriteFile(empty, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link.GGUF") // a link to a real file is followed, and the suffix is case-insensitive
	if err := os.Symlink(gguf, link); err != nil {
		t.Fatal(err)
	}
	cases := []struct{ name, path, want string }{
		{"a folder", dir, "not a model file"},
		{"a missing file", filepath.Join(dir, "gone.gguf"), "no file"},
		{"not a .gguf", notGGUF, ".gguf"},
		{"the wrong magic", badMagic, "not a GGUF"},
		{"empty", empty, "empty"},
		{"relative", "rel/x.gguf", "absolute"},
		{"a .. segment", filepath.Dir(dir) + "/../" + filepath.Base(dir) + "/x.gguf", ".."},
	}
	for _, tc := range cases {
		rec := call(t, mux, http.MethodPut, "/v1/meetings/notes-model", `{"path":`+strconv.Quote(tc.path)+`}`)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: %d %s, want 400", tc.name, rec.Code, bodyText(rec))
		}
		if got := bodyText(rec); !strings.Contains(got, tc.want) {
			t.Fatalf("%s: answer = %s, want a reason naming %q", tc.name, got, tc.want)
		}
		if ch := readNotesChoice(d.Cfg.Home); ch != nil {
			t.Fatalf("%s: a refused path was saved: %+v", tc.name, ch)
		}
	}
	for _, path := range []string{gguf, link} {
		rec := call(t, mux, http.MethodPut, "/v1/meetings/notes-model", `{"path":`+strconv.Quote(path)+`}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("PUT %s: %d %s, want 200", path, rec.Code, bodyText(rec))
		}
		if res := d.notesResolve(); res.ID != config.NotesCustomID || res.Path != path {
			t.Fatalf("after PUT %s: %+v, want the custom model at that path", path, res)
		}
	}
}

// A job admitted while the model switch is inside its critical section waits
// the section out, then lands on the new model: the busy check, the engine
// stop and the saved choice are one step under the queue's admission lock —
// never a changed file under an old child, never a job slipped between.
// The probe holds the section open deterministically; the finished meeting's
// Enqueue must park until it lets go. Mutation:
// internal/daemon/notesmodel.go notesModelSwitch, return body(0) instead of
// d.Meet.WithAdmissionLock(body) -> RED (the lock probe sees the section
// unheld and the Finish lands before the choice is saved).
func TestNotesModelPutIsOneStepAgainstJobAdmission(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	inSwitch := make(chan struct{})
	release := make(chan struct{})
	held := make(chan bool, 1)
	notesModelSwitchProbe = func() {
		close(inSwitch)
		held <- d.Meet.AdmissionLocked()
		<-release
	}
	t.Cleanup(func() { notesModelSwitchProbe = nil })

	put := make(chan *httptest.ResponseRecorder, 1)
	go func() { put <- call(t, mux, http.MethodPut, "/v1/meetings/notes-model", `{"id":"qwen3.5-9b"}`) }()
	<-inSwitch
	if !<-held {
		t.Fatal("the switch ran outside the admission lock")
	}
	// A real finish of a real recording: its Enqueue must park behind the
	// lock for as long as the switch's section is open.
	m, _, err := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	fin := make(chan error, 1)
	go func() {
		_, err := d.Meet.Finish(m.ID, time.Now())
		fin <- err
	}()
	testutil.WaitFor(t, 5*time.Second, func() bool {
		got, _ := d.Meet.Store.Load(m.ID)
		return got != nil && got.Status == meeting.StatusQueued
	}, "the finish to stamp the manifest")
	select {
	case err := <-fin:
		t.Fatalf("a job was admitted while the switch held the lock (%v)", err)
	default:
	}
	close(release)
	if err := <-fin; err != nil {
		t.Fatal(err)
	}
	rec := <-put
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT = %d %s", rec.Code, bodyText(rec))
	}
	if ch := readNotesChoice(d.Cfg.Home); ch == nil || ch.ID != "qwen3.5-9b" {
		t.Fatalf("the PUT's choice = %+v, want the saved 9B", ch)
	}
	// The admitted meeting resolves the new model: it is queued against the
	// choice the switch saved, not the one the switch replaced.
	if res := d.notesResolve(); res.ID != "qwen3.5-9b" {
		t.Fatalf("resolve = %+v: the admitted job's model is not the new one", res)
	}
	if d.Meet.Active() != 1 {
		t.Fatal("the finished meeting was not admitted")
	}
}

// Exactly one notes row is selected — the effective model's own row: its
// catalog row for a resolved catalog model, notes:custom for the user's own
// file — and the legacy "notes" row mirrors the pick. The automatic,
// saved-choice and env-pin resolutions each put the mark on a different row.
// Mutation: internal/daemon/models.go notesCatalogEntry, `Selected: res.Entry
// != nil && res.Entry.ID == entry.ID` -> `Selected: res.Entry != nil` -> RED
// (every catalog row marks itself).
func TestModelsListMarksTheSelectedNotesModel(t *testing.T) {
	d, mux := meetingFixture(t, func(c *config.Config) {
		bin := filepath.Join(filepath.Dir(c.Home), "ox-llm")
		_ = os.MkdirAll(filepath.Dir(bin), 0o755)
		_ = os.WriteFile(bin, []byte("x"), 0o755)
		c.NotesBin = bin
	})
	_ = os.MkdirAll(d.Cfg.ModelsDir(), 0o755)
	// Only the 4B on disk: the automatic pick resolves to it over the 9B.
	if err := os.WriteFile(filepath.Join(d.Cfg.ModelsDir(), config.NotesModelFile), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	selected := func() map[string]bool {
		rec := call(t, mux, http.MethodGet, "/v1/models", "")
		if rec.Code != http.StatusOK {
			t.Fatalf("GET /v1/models: %d", rec.Code)
		}
		var list struct {
			Models []struct {
				ID       string
				Selected bool `json:"selected"`
			}
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
			t.Fatal(err)
		}
		out := map[string]bool{}
		for _, m := range list.Models {
			if m.Selected {
				out[m.ID] = true
			}
		}
		return out
	}
	want := map[string]bool{"notes": true, "notes:qwen3.5-4b": true} // the installed 4B wins the automatic pick over the 9B
	if got := selected(); !mapsEqual(got, want) {
		t.Fatalf("automatic: selected = %+v, want %+v", got, want)
	}
	if err := writeNotesChoice(d.Cfg.Home, config.NotesChoice{ID: "qwen3.5-9b"}); err != nil {
		t.Fatal(err)
	}
	want = map[string]bool{"notes": true, "notes:qwen3.5-9b": true}
	if got := selected(); !mapsEqual(got, want) {
		t.Fatalf("saved 9B: selected = %+v, want %+v", got, want)
	}
	// The env pin on the user's own file: notes:custom is the pick and the
	// notes row mirrors it; no catalog row is marked.
	own := filepath.Join(t.TempDir(), "mine.gguf")
	if err := os.WriteFile(own, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	d.Cfg.NotesModel, d.Cfg.NotesModelEnv = own, true
	want = map[string]bool{"notes": true, "notes:custom": true}
	if got := selected(); !mapsEqual(got, want) {
		t.Fatalf("env pin on the user's file: selected = %+v, want %+v", got, want)
	}
	// An env pin that names a catalog file resolves to that catalog row.
	d.Cfg.NotesModel = filepath.Join(d.Cfg.ModelsDir(), "Qwen3.5-9B-Q4_K_M.gguf")
	want = map[string]bool{"notes": true, "notes:qwen3.5-9b": true}
	if got := selected(); !mapsEqual(got, want) {
		t.Fatalf("env pin on a catalog file: selected = %+v, want %+v", got, want)
	}
}

func mapsEqual(a, b map[string]bool) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range b {
		if !a[k] || !v {
			return false
		}
	}
	return true
}

// A switch while a meeting's notes are queued, running or recording is 409
// and changes nothing (F4). Mutation: drop the notesModelBusy check in
// handleNotesModelPut -> the PUT writes the file -> RED.
func TestNotesModelPutWhileBusyIsConflict(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	_ = os.MkdirAll(d.Cfg.ModelsDir(), 0o755)
	if err := os.WriteFile(filepath.Join(d.Cfg.ModelsDir(), config.NotesModelFile), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	m, _, _ := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	if _, err := d.Meet.Finish(m.ID, time.Now()); err != nil {
		t.Fatal(err)
	}
	if d.Meet.Active() == 0 {
		t.Fatal("setup: no busy meeting")
	}
	rec := call(t, mux, http.MethodPut, "/v1/meetings/notes-model", `{"id":"qwen3.5-9b"}`)
	if rec.Code != http.StatusConflict {
		t.Fatalf("PUT during a busy meeting: %d %s, want 409", rec.Code, bodyText(rec))
	}
	if ch := readNotesChoice(d.Cfg.Home); ch != nil {
		t.Fatalf("the refused PUT wrote a choice: %+v", ch)
	}
	if res := d.notesResolve(); res.ID != "qwen3.5-4b" {
		t.Fatalf("the busy meeting's model changed to %+v", res)
	}
}

// Not enough disk for the 9B: the install drops to the 4B and the download
// targets it, marked fallback "disk" — the journey F3 falsifies by removing
// the fallback branch in InstallNotesModel.
// Mutation: internal/daemon/meetings.go InstallNotesModel, delete the
// `fb := notesDiskFallback(target)` block (return err at once) -> RED.
func TestInstallFallsBackToThe4BWhenThe9BCannotFit(t *testing.T) {
	d := installFixture(t, "#!/bin/sh\necho model > \"$5/$2\"\n")
	var nineBytes int64
	for i := range config.NotesCatalog {
		if config.NotesCatalog[i].ID == "qwen3.5-9b" {
			nineBytes = config.NotesCatalog[i].Bytes
		}
	}
	// The 4B plus margin fits; the 9B does not.
	room := int64(config.NotesModelBytes) + notesDiskMargin
	if room >= nineBytes {
		t.Fatal("test arithmetic: the 4B need must be under the 9B size")
	}
	withFreeBytes(t, func(string) (int64, error) { return room, nil })
	if err := d.InstallNotesModel(""); err != nil {
		t.Fatal(err)
	}
	testutil.WaitFor(t, 5*time.Second, func() bool { return d.notesInstalling() == 0 }, "the download to end")
	file, want, fb := d.notes.target()
	if fb != "disk" || filepath.Base(file) != config.NotesModelFile || want != config.NotesModelBytes {
		t.Fatalf("target = %q %d %q, want the 4B on a disk fallback", file, want, fb)
	}
	if got := d.Status().Notes.Fallback; got != "disk" {
		t.Fatalf("/status notes.fallback = %q, want disk", got)
	}
}

// An install with an explicit id does NOT fall back: the refusal names the
// disk, and nothing is fetched.
func TestInstallWithAnIDReportsTheDiskInsteadOfFallingBack(t *testing.T) {
	d := installFixture(t, "#!/bin/sh\nexit 0\n")
	withFreeBytes(t, func(string) (int64, error) { return int64(config.NotesModelBytes) + notesDiskMargin, nil })
	err := d.InstallNotesModel("qwen3.5-9b")
	if err == nil || !strings.Contains(err.Error(), "free disk space") {
		t.Fatalf("err = %v, want the disk refusal, not a silent 4B", err)
	}
	if d.notesInstalling() != 0 {
		t.Fatal("a download started for a refused install")
	}
}

// /v1/models lists the resolved "notes" row plus one "notes:<id>" per catalog
// file; with the user's own file resolved a "notes:custom" row appears and
// nothing in the API can delete it or the file.
func TestModelsListCarriesTheCatalogRows(t *testing.T) {
	d, mux := meetingFixture(t, func(c *config.Config) {
		bin := filepath.Join(filepath.Dir(c.Home), "ox-llm")
		_ = os.MkdirAll(filepath.Dir(bin), 0o755)
		_ = os.WriteFile(bin, []byte("x"), 0o755)
		c.NotesBin = bin
	})
	_ = os.MkdirAll(d.Cfg.ModelsDir(), 0o755)
	if err := os.WriteFile(filepath.Join(d.Cfg.ModelsDir(), config.NotesModelFile), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	ids := map[string]bool{}
	rec := call(t, mux, http.MethodGet, "/v1/models", "")
	var list struct {
		Models []struct {
			ID, Kind  string
			Installed bool
		}
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatal(err)
	}
	for _, m := range list.Models {
		if m.Kind == "notes" {
			ids[m.ID] = m.Installed
		}
	}
	for _, want := range []string{"notes", "notes:qwen3.5-9b", "notes:qwen3.5-4b", "notes:qwen3.8-27b-uncensored"} {
		if _, ok := ids[want]; !ok {
			t.Fatalf("no %q row in %+v", want, ids)
		}
	}
	if !ids["notes"] || !ids["notes:qwen3.5-4b"] {
		t.Fatalf("the installed 4B rows are not installed: %+v", ids)
	}
	if ids["notes:custom"] {
		t.Fatal("a custom row shows while a catalog model is resolved")
	}
	// With the user's own file resolved, notes:custom appears and the "notes"
	// row is not removable.
	d.Cfg.NotesModel = filepath.Join(d.Cfg.Home, "models", "my-own.gguf")
	d.Cfg.NotesModelEnv = true
	rec = call(t, mux, http.MethodGet, "/v1/models", "")
	list.Models = nil
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatal(err)
	}
	var custom, notesRow bool
	for _, m := range list.Models {
		custom = custom || m.ID == "notes:custom"
		notesRow = notesRow || m.ID == "notes"
	}
	if !custom {
		t.Fatal("no notes:custom row for the user's own file")
	}
	if !notesRow {
		t.Fatal("no notes row at all")
	}
	if rec := call(t, mux, http.MethodDelete, "/v1/models/notes:custom", ""); rec.Code == http.StatusNoContent {
		t.Fatal("notes:custom was deleted")
	}
	// The "notes" row itself names the user's file now: it is not removable
	// either — ox-say never deletes a model it did not download.
	if rec := call(t, mux, http.MethodDelete, "/v1/models/notes", ""); rec.Code == http.StatusNoContent {
		t.Fatal("the user's own notes file was deleted through the notes row")
	}
}

// A model over config.NotesExclusiveBytes on a Mac under
// config.NotesExclusiveBelowGB takes turns with the voices; the 4B on the
// same Mac shares. The condition is live: switching the model flips the mode
// without a restart. F6's mutation at the service.go call site (drop
// `r.cond = d.notesExclusive`) makes the 4B exclusive too -> the shared half
// of this test goes RED.
// Mutation: internal/daemon/service.go newDaemon, delete `r.cond =
// d.notesExclusive` -> RED.
func TestALargeNotesModelIsExclusiveBelow48GB(t *testing.T) {
	build := func(file string) *Daemon {
		dir := t.TempDir()
		fakeEnv(t, dir)
		t.Setenv("OXSAY_FAKE_VOX", "1")
		t.Setenv("OXSAY_FAKE_STT", "1")
		model := filepath.Join(dir, config.VoxCPM2ModelFile)
		notes := filepath.Join(dir, "models", file)
		_ = os.MkdirAll(filepath.Dir(notes), 0o755)
		for _, p := range []string{model, notes} {
			if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		return newTestDaemonVox(t, dir, func(c *config.Config) {
			c.GPUMemory = config.GPUMemoryUnified
			c.VoxCPM2Bin = os.Args[0]
			c.VoxCPM2Model = model
			c.VoxCPM2Port = testutil.FreePort(t)
			c.NotesBin, c.NotesModel = os.Args[0], notes
			c.Lang = "en"
			c.HostMemoryBytes = 48 * gib
			c.AssumedMemoryBytes = 32 * gib
		}, nil, nil, nil)
	}
	large := build("Huihui-Qwen3.8-27B-abliterated-UD-Q5_K_XL.gguf")
	if large.mem == nil || !large.mem.managed(large.Sup) || !large.mem.managed(large.LLMSup) {
		t.Fatal("a 20 GB notes model on a 32 GB Mac did not make the large engines take turns")
	}
	if got := large.Status().MemoryMode; got != memoryModeOneLarge {
		t.Fatalf("memory_mode = %q, want %q", got, memoryModeOneLarge)
	}
	small := build(config.NotesModelFile)
	if small.mem != nil && small.mem.managed(small.Sup) {
		t.Fatal("the 4B notes model on the same Mac is exclusive")
	}
	if got := small.Status().MemoryMode; got != memoryModeShared {
		t.Fatalf("memory_mode = %q, want %q", got, memoryModeShared)
	}
}

// An install that names no id — what the app's Download button sends —
// fetches the model the resolver says is effective: a saved catalog choice's
// own entry, so the file that lands is the one /status keeps reporting, never
// the automatic default while the saved file is missing. The compact
// fallback is the automatic pick's alone: a saved choice that does not fit
// the disk gets the refusal, not a silent different model, and a saved
// custom path is refused — there is nothing to download over the user's own
// file.
// Mutations in internal/daemon/meetings.go InstallNotesModel:
//   - `target = res.Entry` -> `target = d.Cfg.NotesAutomaticDefault()` -> RED
//     (the saved-4B install fetches the 9B);
//   - the `res.Source != config.NotesSourceAutomatic` disk guard dropped ->
//     RED (the saved-9B install silently falls back to the 4B);
//   - the `target == nil` arm removed -> RED (the custom path fetches);
//   - the own-file refusal reworded to name res.Path -> RED (the response
//     body carries the temp dir's absolute path).
func TestAnEmptyInstallFetchesTheResolvedModel(t *testing.T) {
	// The saved 4B is missing: the empty install fetches the 4B.
	d := installFixture(t, "#!/bin/sh\necho model > \"$5/$2\"\n")
	if err := writeNotesChoice(d.Cfg.Home, config.NotesChoice{ID: "qwen3.5-4b"}); err != nil {
		t.Fatal(err)
	}
	if err := d.InstallNotesModel(""); err != nil {
		t.Fatalf("install the resolved model: %v", err)
	}
	testutil.WaitFor(t, 5*time.Second, func() bool { return d.notesInstalling() == 0 }, "the download to end")
	file, _, _ := d.notes.target()
	if filepath.Base(file) != config.NotesModelFile {
		t.Fatalf("the empty install fetched %q, want the saved 4B %q", file, config.NotesModelFile)
	}
	if res := d.notesResolve(); !res.Installed || res.ID != "qwen3.5-4b" {
		t.Fatalf("after the download: %+v, want the saved 4B installed", res)
	}

	// The saved 9B does not fit a disk the 4B would: the refusal, not a
	// silent compact model the resolution still does not point at.
	d2 := installFixture(t, "#!/bin/sh\nexit 0\n")
	if err := writeNotesChoice(d2.Cfg.Home, config.NotesChoice{ID: "qwen3.5-9b"}); err != nil {
		t.Fatal(err)
	}
	withFreeBytes(t, func(string) (int64, error) {
		return config.NotesModelBytes + notesDiskMargin, nil
	})
	err := d2.InstallNotesModel("")
	if err == nil || !strings.Contains(err.Error(), "free disk space") {
		t.Fatalf("err = %v, want the disk refusal on the saved 9B", err)
	}
	if d2.notesInstalling() != 0 {
		t.Fatal("a download started: the saved 9B silently fell back to the 4B")
	}

	// A saved custom path names the user's own file: nothing to download.
	d3 := installFixture(t, "#!/bin/sh\nexit 0\n")
	own := filepath.Join(t.TempDir(), "mine.gguf")
	if err := writeNotesChoice(d3.Cfg.Home, config.NotesChoice{Path: own}); err != nil {
		t.Fatal(err)
	}
	if err := d3.InstallNotesModel(""); err == nil {
		t.Fatal("an empty install on the user's own file must refuse: there is nothing to download")
	}
	// The refusal is the 409's body: the sentence is generic and carries no
	// path — the file's absolute path is the user's own, not the app's answer.
	rec := serve(servedFor(t, d3), appRequest("POST", "/v1/meetings/notes-model/install", ""))
	if rec.Code != http.StatusConflict {
		t.Fatalf("install over the user's own file = %d %s, want 409", rec.Code, rec.Body)
	}
	if strings.Contains(rec.Body.String(), filepath.Dir(own)) {
		t.Fatalf("the refusal names the user's own path: %s", rec.Body)
	}
}

// A resident notes child keeps the model it was spawned with; a model that
// lands afterwards flips the automatic resolution under it — nothing stops
// the child, so meetings would keep generating on the old file until it
// idled out. The child carries its spawn argv; a notes job that finds it
// stale stops it first and the fresh start loads what the resolver names.
// Mutation: internal/daemon/meetings.go llmChat.Complete, delete the
// stale-child check -> RED (the second call is served by the 4B child: same
// pid, no second spawn).
func TestANotesJobRecyclesAnEngineSpawnedOnAnOlderModel(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_DIR", dir)
	var model4b, model9b string
	d, _ := meetingFixture(t, func(c *config.Config) {
		model4b = filepath.Join(c.ModelsDir(), config.NotesModelFile)
		model9b = filepath.Join(c.ModelsDir(), "Qwen3.5-9B-Q4_K_M.gguf")
		if err := os.MkdirAll(c.ModelsDir(), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(model4b, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		c.NotesBin = os.Args[0]
	})
	if res := d.notesResolve(); res.ID != "qwen3.5-4b" || !res.Installed {
		t.Fatalf("setup resolution = %+v, want the installed 4B", res)
	}
	if err := notesCall(t, d); err != nil {
		t.Fatal(err)
	}
	first := d.LLMSup.Status().PID
	if first == 0 {
		t.Fatal("the notes child did not start")
	}
	// The 9B lands over the warm 4B child: the automatic pick flips.
	if err := os.WriteFile(model9b, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if res := d.notesResolve(); res.ID != "qwen3.5-9b" || !res.Installed {
		t.Fatalf("after the 9B lands: %+v, want the 9B selected", res)
	}
	if err := notesCall(t, d); err != nil {
		t.Fatal(err)
	}
	st := d.LLMSup.Status()
	if st.PID == first {
		t.Fatalf("the second call was served by the child spawned on the 4B (pid %d)", first)
	}
	waitProcessGone(t, first, "the 4B child")
	stamp := filepath.Join(dir, "llm-spawn-"+strconv.Itoa(st.PID))
	raw, err := os.ReadFile(stamp)
	if err != nil {
		t.Fatalf("no spawn stamp for the recycled child: %v", err)
	}
	if !strings.Contains(string(raw), model9b) {
		t.Fatalf("the recycled child's argv = %q, want it on the 9B %s", raw, model9b)
	}
}

// The explicit-id install gates on the target — its memory floor, the port,
// the engine — never on the selection: a saved choice this Mac cannot run
// must not block the download of a model it can. On a 24 GB Mac with the 27B
// saved, installing the 4B proceeds.
// Mutation: internal/daemon/meetings.go InstallNotesModel, gate the explicit
// id on NotesBlock(res) (the selected model) -> RED (the 24 GB Mac refuses
// the 4B for the 27B's 32 GB floor).
func TestAnExplicitInstallChecksTheTargetNotTheSelection(t *testing.T) {
	d := installFixture(t, "#!/bin/sh\nexit 0\n")
	d.Cfg.HostMemoryBytes = 24 * gib
	if err := writeNotesChoice(d.Cfg.Home, config.NotesChoice{ID: "qwen3.8-27b-uncensored"}); err != nil {
		t.Fatal(err)
	}
	res := d.notesResolve()
	if res.ID != "qwen3.8-27b-uncensored" || res.Source != config.NotesSourceSaved {
		t.Fatalf("setup resolution = %+v, want the saved 27B", res)
	}
	if code, _ := d.Cfg.NotesBlock(res); code != config.NotesReasonUnsupported {
		t.Fatal("setup: the saved 27B should be unsupported on a 24 GB Mac")
	}
	if err := d.InstallNotesModel("qwen3.5-4b"); err != nil {
		t.Fatalf("installing the 4B over a saved 27B: %v", err)
	}
	testutil.WaitFor(t, 5*time.Second, func() bool { return d.notesInstalling() == 0 }, "the download to end")
	file, _, _ := d.notes.target()
	if filepath.Base(file) != config.NotesModelFile {
		t.Fatalf("the download fetched %q, want the 4B %q", file, config.NotesModelFile)
	}
}

// Every write of the saved choice gets its own private temp file, and every
// switch — the busy check, the engine stop and the write — holds one lock,
// also with no meeting queue. A fixed notes-model.json.tmp let two PUTs
// share one inode: writes interleaved, and the loser's rename found the temp
// the winner had already moved.
// Mutations in internal/daemon/notesmodel.go:
//   - writeNotesChoice, restore the fixed path+".tmp" write -> RED (the
//     planted temp is eaten by the write);
//   - notesModelSwitch, drop the mutex around the switch -> RED (the probe
//     sees both switches inside the section at once).
func TestConcurrentNotesModelChoicesKeepAWholeFile(t *testing.T) {
	d := notesDaemon(t)

	// A write does not touch a file at the old fixed temp name.
	tmp := filepath.Join(d.Cfg.Home, notesChoiceFile+".tmp")
	if err := os.WriteFile(tmp, []byte("sentinel"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeNotesChoice(d.Cfg.Home, config.NotesChoice{ID: "qwen3.5-9b"}); err != nil {
		t.Fatal(err)
	}
	if raw, err := os.ReadFile(tmp); err != nil || string(raw) != "sentinel" {
		t.Fatalf("the write consumed the fixed temp name (%q, %v): writers share an inode", raw, err)
	}

	// Concurrent writers: every one succeeds and the file is always one whole
	// choice — never interleaved, never a lost rename.
	const writers = 16
	var wg sync.WaitGroup
	werrs := make(chan error, writers)
	for i := 0; i < writers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			id := "qwen3.5-9b"
			if i%2 == 0 {
				id = "qwen3.5-4b"
			}
			werrs <- writeNotesChoice(d.Cfg.Home, config.NotesChoice{ID: id})
		}(i)
	}
	wg.Wait()
	close(werrs)
	for err := range werrs {
		if err != nil {
			t.Fatalf("a concurrent choice write failed: %v", err)
		}
	}
	raw, err := os.ReadFile(filepath.Join(d.Cfg.Home, notesChoiceFile))
	if err != nil {
		t.Fatal(err)
	}
	var saved struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(raw, &saved); err != nil ||
		(saved.ID != "qwen3.5-4b" && saved.ID != "qwen3.5-9b") {
		t.Fatalf("the saved choice = %s, want one whole choice file", raw)
	}

	// The switch serializes with no meeting queue: a second PUT cannot sit
	// inside the critical section while the first still holds it.
	d.Meet = nil
	release := make(chan struct{})
	var in, overlap atomic.Int32
	notesModelSwitchProbe = func() {
		if in.Add(1) > 1 {
			overlap.Add(1)
		}
		<-release
		in.Add(-1)
	}
	t.Cleanup(func() { notesModelSwitchProbe = nil })
	errs := make(chan error, 2)
	go func() {
		errs <- d.notesModelSwitch(context.Background(), config.NotesChoice{Path: filepath.Join(t.TempDir(), "one.gguf")})
	}()
	go func() {
		errs <- d.notesModelSwitch(context.Background(), config.NotesChoice{Path: filepath.Join(t.TempDir(), "two.gguf")})
	}()
	testutil.WaitFor(t, 5*time.Second, func() bool { return in.Load() > 0 }, "the first switch to enter")
	close(release)
	for i := 0; i < 2; i++ {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	if overlap.Load() != 0 {
		t.Fatal("two switches held the critical section at once")
	}
}
