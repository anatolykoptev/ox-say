package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/meeting"
)

// modelsServer is metaServer with every model path inside <dir>/models under the name fetch-models.sh writes. The
// bare testCfg leaves them empty, which would make a "delete" aim at the working directory.
func modelsServer(t *testing.T) (d *Daemon, base, models string) {
	t.Helper()
	d, base, dir := metaServer(t)
	d.Cfg.Home = dir // the managed folder is <home>/models
	models = filepath.Join(dir, "models")
	if err := os.MkdirAll(models, 0o755); err != nil {
		t.Fatal(err)
	}
	d.Cfg.NotesModel = filepath.Join(models, config.NotesModelFile)
	d.Cfg.STTWhisperModel = filepath.Join(models, "ggml-large-v3-turbo.bin")
	d.Cfg.VoxCPM2Model = filepath.Join(models, config.VoxCPM2ModelFile)
	d.Cfg.STTModel = filepath.Join(models, "ggml-parakeet-tdt-0.6b-v3-q8_0.bin")
	return d, base, models
}

func put(t *testing.T, path string, n int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, make([]byte, n), 0o644); err != nil {
		t.Fatal(err)
	}
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func find(list []modelEntry, id string) *modelEntry {
	for i := range list {
		if list[i].ID == id {
			return &list[i]
		}
	}
	return nil
}

func listModels(t *testing.T, base string) []modelEntry {
	t.Helper()
	code, body := doJSON(t, http.MethodGet, base+"/v1/models", "")
	if code != http.StatusOK {
		t.Fatalf("GET /v1/models = %d %s", code, body)
	}
	var out struct {
		Models []modelEntry `json:"models"`
	}
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		t.Fatalf("decode %s: %v", body, err)
	}
	return out.Models
}

// rawRequest sends method to base+escaped exactly as written (no path cleaning, no redirect following), so an encoded
// slash reaches the daemon's mux the way a hostile client would send it.
func rawRequest(t *testing.T, method, base, escaped string) int {
	t.Helper()
	u, err := url.Parse(base + escaped)
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(method, u.String(), nil)
	if err != nil {
		t.Fatal(err)
	}
	c := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	return resp.StatusCode
}

func TestModelsListReportsInstalledAndSizes(t *testing.T) {
	d, base, _ := modelsServer(t)
	put(t, d.Cfg.NotesModel, 4096)
	list := listModels(t, base)
	notes := find(list, "notes")
	if notes == nil || !notes.Installed || notes.Bytes != 4096 || !notes.Optional {
		t.Fatalf("notes row: %+v", notes)
	}
	if q := find(list, "qwen3-tts"); q == nil || q.Optional || !q.Default {
		t.Fatalf("qwen row: %+v", q)
	}
	// Not installed: the expected size, so the window can say "about 1.6 GB" before the download.
	if w := find(list, "whisper"); w == nil || w.Installed || w.Bytes <= 0 || !w.Optional || w.Default {
		t.Fatalf("whisper row: %+v", w)
	}
	if p := find(list, "parakeet"); p == nil || p.Optional || p.Kind != "transcribe" || !p.Default {
		t.Fatalf("parakeet row: %+v", p)
	}
	if len(list) != 5 {
		t.Fatalf("want the five models, got %d: %+v", len(list), list)
	}
}

// The list is read when the Models section opens, so it must not cost more on a big model: one stat per file, no walk,
// no read. A 4 GiB sparse file stands for the real 3 GB ones.
func TestModelsListStatsFilesWithoutReadingThem(t *testing.T) {
	d, base, _ := modelsServer(t)
	put(t, d.Cfg.VoxCPM2Model, 0)
	if err := os.Truncate(d.Cfg.VoxCPM2Model, 4<<30); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	vox := find(listModels(t, base), "voxcpm2")
	if took := time.Since(start); took > 2*time.Second {
		t.Fatalf("listing took %v for a 4 GiB model", took)
	}
	if vox == nil || !vox.Installed || vox.Bytes != 4<<30 {
		t.Fatalf("vox row: %+v", vox)
	}
	// A folder at the model path is not a model, and its contents are not counted.
	if err := os.Remove(d.Cfg.VoxCPM2Model); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(d.Cfg.VoxCPM2Model, 0o755); err != nil {
		t.Fatal(err)
	}
	put(t, filepath.Join(d.Cfg.VoxCPM2Model, "inner.bin"), 10)
	if vox := find(listModels(t, base), "voxcpm2"); vox.Installed {
		t.Fatalf("a folder reads as installed: %+v", vox)
	}
}

func TestDeleteRemovesOnlyThePinnedOptionalModel(t *testing.T) {
	d, base, models := modelsServer(t)
	d.Cfg.Model = filepath.Join(models, "talker.gguf")
	d.Cfg.Codec = filepath.Join(models, "codec.gguf")
	pinned := d.Cfg.NotesModel
	put(t, pinned, 1)
	put(t, d.Cfg.STTModel, 1)
	put(t, d.Cfg.Model, 1)
	put(t, d.Cfg.Codec, 1)
	for _, id := range []string{"qwen3-tts", "parakeet"} {
		if code, _ := doJSON(t, http.MethodDelete, base+"/v1/models/"+id, ""); code != http.StatusBadRequest {
			t.Fatalf("a required model must not be removable (%s): %d", id, code)
		}
	}
	if !exists(d.Cfg.STTModel) || !exists(d.Cfg.Model) || !exists(d.Cfg.Codec) {
		t.Fatal("a required model file was removed")
	}
	if code, body := doJSON(t, http.MethodDelete, base+"/v1/models/notes", ""); code != http.StatusNoContent {
		t.Fatalf("DELETE notes = %d %s", code, body)
	}
	if exists(pinned) {
		t.Fatal("file still there")
	}
	if n := find(listModels(t, base), "notes"); n.Installed {
		t.Fatalf("the list still says installed: %+v", n)
	}
}

func TestDeleteNeverTouchesAUsersOwnFile(t *testing.T) {
	d, base, models := modelsServer(t)
	own := filepath.Join(models, "my-notes-model.gguf")
	put(t, own, 1)
	d.Cfg.NotesModel = own // OX_SAY_NOTES_MODEL names another file
	if code, _ := doJSON(t, http.MethodDelete, base+"/v1/models/notes", ""); code != http.StatusBadRequest {
		t.Fatalf("got %d, want 400", code)
	}
	if !exists(own) {
		t.Fatal("the user's file was removed")
	}
}

// An unset or relative configured path would resolve against the daemon's working directory.
func TestDeleteRefusesAnEmptyOrRelativeConfiguredPath(t *testing.T) {
	d, base, _ := modelsServer(t)
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	victim := filepath.Join(cwd, config.NotesModelFile)
	if exists(victim) {
		t.Skip("a file with the pinned name exists in the package directory")
	}
	put(t, victim, 1)
	t.Cleanup(func() { _ = os.Remove(victim) })
	for _, path := range []string{"", config.NotesModelFile, "./" + config.NotesModelFile} {
		d.Cfg.NotesModel = path
		if code, _ := doJSON(t, http.MethodDelete, base+"/v1/models/notes", ""); code != http.StatusBadRequest {
			t.Fatalf("path %q: got %d, want 400", path, code)
		}
		if !exists(victim) {
			t.Fatalf("path %q: a file in the working directory was removed", path)
		}
	}
}

// Nothing in the request path reaches the filesystem: the id picks a row of a fixed table.
func TestDeleteIdsNeverReachTheFilesystem(t *testing.T) {
	d, base, models := modelsServer(t)
	put(t, d.Cfg.NotesModel, 1)
	put(t, d.Cfg.STTWhisperModel, 1)
	put(t, d.Cfg.VoxCPM2Model, 1)
	put(t, d.Cfg.STTModel, 1)
	put(t, filepath.Join(models, "..", "outside.txt"), 1)
	put(t, filepath.Join(models, "diar", "nemotron-3-diarization", ".ox-say-revision"), 1)
	snapshot := func() string {
		var names []string
		_ = filepath.WalkDir(filepath.Dir(models), func(p string, e os.DirEntry, err error) error {
			if err == nil && !e.IsDir() && !strings.Contains(p, string(filepath.Separator)+"logs") {
				names = append(names, p)
			}
			return nil
		})
		return strings.Join(names, "\n")
	}
	before := snapshot()
	for _, id := range []string{
		"..%2Foutside.txt", "..%2fmodels%2f" + config.NotesModelFile, "%2e%2e%2foutside.txt", "notes%2F..%2F..%2Foutside.txt",
		"notes%2f", "%2Fetc%2Fpasswd", "a%2Fb", "unknown", "NOTES", "notes%00", "diar", "nemotron",
		"nemotron-3-diarization", "speaker-diarization", "%2e", "%2e%2e",
	} {
		code := rawRequest(t, http.MethodDelete, base, "/v1/models/"+id)
		if code != http.StatusNotFound && code != http.StatusBadRequest && code != http.StatusMovedPermanently &&
			code != http.StatusMethodNotAllowed && code != http.StatusPermanentRedirect {
			t.Errorf("DELETE /v1/models/%s = %d, want a refusal", id, code)
		}
		if after := snapshot(); after != before {
			t.Fatalf("DELETE /v1/models/%s changed the disk:\nbefore %s\nafter  %s", id, before, after)
		}
	}
	// the empty id: the route needs a segment
	for _, p := range []string{"/v1/models/", "/v1/models"} {
		if code := rawRequest(t, http.MethodDelete, base, p); code == http.StatusNoContent || code == http.StatusOK {
			t.Errorf("DELETE %s = %d", p, code)
		}
	}
	if snapshot() != before {
		t.Fatal("an empty-id delete changed the disk")
	}
	// unknown id is a 404 with the error shape, not a 400/500 that hints at a lookup
	if code, body := doJSON(t, http.MethodDelete, base+"/v1/models/unknown", ""); code != http.StatusNotFound || !strings.Contains(body, "no such model") {
		t.Fatalf("unknown id = %d %s, want 404 \"no such model\"", code, body)
	}
}

func TestDeleteOfAKnownButNotInstalledModelIs404(t *testing.T) {
	_, base, _ := modelsServer(t)
	for _, id := range []string{"voxcpm2", "whisper", "notes"} {
		if code, body := doJSON(t, http.MethodDelete, base+"/v1/models/"+id, ""); code != http.StatusNotFound || !strings.Contains(body, "not installed") {
			t.Fatalf("%s not installed = %d %s, want 404 \"not installed\"", id, code, body)
		}
	}
}

// A model kept on another disk is a link in the models folder. The delete does not follow it and does not remove it:
// the data would stay and the list would say the model is gone.
func TestDeleteDoesNotFollowOrRemoveALink(t *testing.T) {
	d, base, models := modelsServer(t)
	target := filepath.Join(filepath.Dir(models), "elsewhere", "real.gguf")
	put(t, target, 7)
	if err := os.Symlink(target, d.Cfg.NotesModel); err != nil {
		t.Fatal(err)
	}
	if n := find(listModels(t, base), "notes"); !n.Installed || n.Bytes != 7 {
		t.Fatalf("a linked model is installed and has the target's size: %+v", n)
	}
	if code, _ := doJSON(t, http.MethodDelete, base+"/v1/models/notes", ""); code != http.StatusBadRequest {
		t.Fatalf("link = %d, want 400", code)
	}
	if !exists(target) || !exists(d.Cfg.NotesModel) {
		t.Fatal("the link or its target was removed")
	}
}

// The models folder itself may be a link to another disk: the file inside is ours and is removed there.
func TestDeleteInsideALinkedModelsFolderRemovesTheFile(t *testing.T) {
	_, base, models := modelsServer(t)
	real := filepath.Join(filepath.Dir(models), "external")
	put(t, filepath.Join(real, config.NotesModelFile), 3)
	if err := os.Remove(models); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, models); err != nil {
		t.Fatal(err)
	}
	if code, body := doJSON(t, http.MethodDelete, base+"/v1/models/notes", ""); code != http.StatusNoContent {
		t.Fatalf("DELETE = %d %s", code, body)
	}
	if exists(filepath.Join(real, config.NotesModelFile)) {
		t.Fatal("the file behind the linked folder is still there")
	}
	if !exists(models) {
		t.Fatal("the folder link was removed")
	}
}

func TestDeleteIsRefusedWhileTheLaneIsBusy(t *testing.T) {
	d, base, _ := modelsServer(t)
	put(t, d.Cfg.STTWhisperModel, 1)
	d.transcribing.Add(1)
	if code, _ := doJSON(t, http.MethodDelete, base+"/v1/models/whisper", ""); code != http.StatusConflict {
		t.Fatalf("busy delete = %d, want 409", code)
	}
	if !exists(d.Cfg.STTWhisperModel) {
		t.Fatal("file removed while busy")
	}
	d.transcribing.Add(-1)
	if code, _ := doJSON(t, http.MethodDelete, base+"/v1/models/whisper", ""); code != http.StatusNoContent {
		t.Fatalf("idle delete = %d, want 204", code)
	}
}

// The studio voice is read by a speech request, a design and a produce job; each keeps the file.
func TestDeleteOfTheStudioVoiceWaitsForEveryLaneThatReadsIt(t *testing.T) {
	d, base, _ := modelsServer(t)
	put(t, d.Cfg.VoxCPM2Model, 1)
	lanes := map[string]func() func(){
		"speaking":  func() func() { d.speaking.Add(1); return func() { d.speaking.Add(-1) } },
		"designing": func() func() { d.designing.Add(1); return func() { d.designing.Add(-1) } },
		"produce": func() func() {
			d.prod.mu.Lock()
			d.prod.removing = "p"
			d.prod.mu.Unlock()
			return func() { d.prod.mu.Lock(); d.prod.removing = ""; d.prod.mu.Unlock() }
		},
	}
	for name, enter := range lanes {
		leave := enter()
		if code, _ := doJSON(t, http.MethodDelete, base+"/v1/models/voxcpm2", ""); code != http.StatusConflict {
			t.Fatalf("%s lane busy: delete = %d, want 409", name, code)
		}
		if !exists(d.Cfg.VoxCPM2Model) {
			t.Fatalf("%s lane busy: the model was removed", name)
		}
		leave()
	}
	if code, _ := doJSON(t, http.MethodDelete, base+"/v1/models/voxcpm2", ""); code != http.StatusNoContent {
		t.Fatalf("idle delete = %d, want 204", code)
	}
}

// The notes model is read by a meeting that is queued or running, by a meeting still being recorded (its notes are made
// when it ends), and written by a download.
func TestDeleteOfTheNotesModelWaitsForMeetingsAndDownloads(t *testing.T) {
	d, base, _ := modelsServer(t)
	put(t, d.Cfg.NotesModel, 1)
	refused := func(what string) {
		t.Helper()
		if code, _ := doJSON(t, http.MethodDelete, base+"/v1/models/notes", ""); code != http.StatusConflict {
			t.Fatalf("%s: delete = %d, want 409", what, code)
		}
		if !exists(d.Cfg.NotesModel) {
			t.Fatalf("%s: the model was removed", what)
		}
	}
	d.notes.mu.Lock()
	d.notes.running = true
	d.notes.mu.Unlock()
	refused("the model is downloading")
	d.notes.mu.Lock()
	d.notes.running = false
	d.notes.mu.Unlock()
	m, _, err := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	refused("a meeting is being recorded")
	if _, err := d.Meet.Finish(m.ID, time.Now()); err != nil {
		t.Fatal(err)
	}
	refused("a meeting is queued")
}

// A running engine has the model open. The delete stops it through the supervisor first, so the file is gone and so is
// the process that held it; it does not pull a model out from under a child.
func TestDeleteStopsTheResidentEngineThenRemovesTheFile(t *testing.T) {
	d, dir := startManagedNotesFake(t)
	mux := http.NewServeMux()
	d.Routes(mux)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	if _, err := d.LLMSup.EnsureReady(t.Context()); err != nil {
		t.Fatal(err)
	}
	pid := d.LLMSup.Status().PID
	if pid == 0 {
		t.Fatal("no notes engine pid")
	}
	if code, body := doJSON(t, http.MethodDelete, srv.URL+"/v1/models/notes", ""); code != http.StatusNoContent {
		t.Fatalf("DELETE = %d %s", code, body)
	}
	waitProcessGone(t, pid, "the notes engine")
	if st := d.LLMSup.Status(); st.State != engine.StateStopped {
		t.Fatalf("engine state = %s, want stopped", st.State)
	}
	if exists(filepath.Join(dir, "models", config.NotesModelFile)) {
		t.Fatal("the model file is still there")
	}
	// /status tells the truth at once: no restart, no poll.
	st := d.notesStatus()
	if st.Available || st.ReasonCode != config.NotesReasonModelMissing {
		t.Fatalf("notes status after the delete = %+v, want model_missing", st)
	}
	if n := find(listModels(t, srv.URL), "notes"); n.Installed || !n.Supported || n.Bytes != config.NotesModelBytes {
		t.Fatalf("list after the delete: %+v", n)
	}
}

// A request that holds the engine is not interrupted: the delete waits a bounded time, answers 409 and leaves both the
// engine and the file alone; once the request is done the same call succeeds.
func TestDeleteLeavesAnEngineThatIsServingARequest(t *testing.T) {
	old := modelStopWait
	modelStopWait = 300 * time.Millisecond
	t.Cleanup(func() { modelStopWait = old })
	d, dir := startManagedNotesFake(t)
	mux := http.NewServeMux()
	d.Routes(mux)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	if _, err := d.LLMSup.EnsureReady(t.Context()); err != nil {
		t.Fatal(err)
	}
	pid := d.LLMSup.Status().PID
	g := d.LLMSup.Acquire()
	code, _ := doJSON(t, http.MethodDelete, srv.URL+"/v1/models/notes", "")
	if code != http.StatusConflict {
		t.Fatalf("DELETE with a request in flight = %d, want 409", code)
	}
	model := filepath.Join(dir, "models", config.NotesModelFile)
	if !exists(model) {
		t.Fatal("the model was removed under a request")
	}
	if st := d.LLMSup.Status(); st.State != engine.StateReady || st.PID != pid {
		t.Fatalf("the engine was disturbed: %+v", st)
	}
	g.Release()
	if code, body := doJSON(t, http.MethodDelete, srv.URL+"/v1/models/notes", ""); code != http.StatusNoContent {
		t.Fatalf("DELETE after the request = %d %s", code, body)
	}
	if exists(model) {
		t.Fatal("the model is still there")
	}
}

// Diarization is not in the table: no id reaches it, and its readiness marker (written last by fetch-models.sh) is
// untouched, so DiarModelsReady keeps telling the truth.
func TestDeleteCannotReachTheDiarizationModels(t *testing.T) {
	d, base, _ := modelsServer(t)
	for _, engineName := range []string{config.DiarEnginePyannote, config.DiarEngineNemotron} {
		d.Cfg.DiarEngine = engineName
		dir, rev := "speaker-diarization", config.DiarModelsRevision
		marker := ".fluidaudio-revision"
		if engineName == config.DiarEngineNemotron {
			dir, rev, marker = "nemotron-3-diarization", config.NemotronModelsRevision, ".ox-say-revision"
		}
		path := filepath.Join(d.Cfg.DiarModelsDir(), dir, marker)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(rev+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if !d.Cfg.DiarModelsReady() {
			t.Fatalf("%s: the fixture is not ready", engineName)
		}
		for _, id := range []string{"diar", "diarization", "nemotron", "pyannote", dir, "models"} {
			if code, _ := doJSON(t, http.MethodDelete, base+"/v1/models/"+id, ""); code != http.StatusNotFound {
				t.Fatalf("DELETE %s = %d, want 404", id, code)
			}
		}
		if !d.Cfg.DiarModelsReady() || !exists(path) {
			t.Fatalf("%s: a delete reached the diarization models", engineName)
		}
	}
	for _, m := range listModels(t, base) {
		if strings.Contains(m.ID, "diar") || strings.Contains(m.ID, "nemotron") {
			t.Fatalf("the registry carries a diarization row: %+v", m)
		}
	}
}

// DELETE removes a file, so a web page must not be able to send it. Guard covers every method: Sec-Fetch-Site and
// Origin refuse a cross-site DELETE before the mux runs; the app (no such headers) passes. postBodyOK guards POST
// bodies only: DELETE has none, and POST /v1/models is not a route.
// Mutation: internal/daemon/guard.go Guard, `protected := http.NewCrossOriginProtection().Handler(next)` -> `protected := next` -> RED.
func TestModelsAreProtectedFromCrossSiteRequests(t *testing.T) {
	d, _, _ := modelsServer(t)
	put(t, d.Cfg.NotesModel, 1)
	h := servedFor(t, d)
	del := func(hdr map[string]string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodDelete, "http://127.0.0.1:8094/v1/models/notes", nil)
		for k, v := range hdr {
			req.Header.Set(k, v)
		}
		return serve(h, req)
	}
	for name, hdr := range map[string]map[string]string{
		"cross-site fetch":    {"Sec-Fetch-Site": "cross-site"},
		"same-site fetch":     {"Sec-Fetch-Site": "same-site"},
		"foreign origin":      {"Origin": "https://evil.example"},
		"foreign origin+port": {"Origin": "http://127.0.0.1:9999"},
	} {
		if rec := del(hdr); rec.Code != http.StatusForbidden {
			t.Errorf("%s: DELETE = %d, want 403", name, rec.Code)
		}
		if !exists(d.Cfg.NotesModel) {
			t.Fatalf("%s: the model was removed", name)
		}
	}
	// a rebinding host
	req := httptest.NewRequest(http.MethodDelete, "http://evil.example/v1/models/notes", nil)
	if rec := serve(h, req); rec.Code != http.StatusForbidden {
		t.Errorf("foreign Host: DELETE = %d, want 403", rec.Code)
	}
	// reads are guarded the same way
	for _, site := range []string{"cross-site", "same-site"} {
		req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8094/v1/models", nil)
		req.Header.Set("Sec-Fetch-Site", site)
		if rec := serve(h, req); rec.Code != http.StatusForbidden {
			t.Errorf("GET /v1/models with %s = %d, want 403", site, rec.Code)
		}
	}
	// no POST route, and a form POST is refused before routing
	req = httptest.NewRequest(http.MethodPost, "http://127.0.0.1:8094/v1/models/notes", strings.NewReader("x=1"))
	req.Header.Set("Content-Type", "text/plain")
	if rec := serve(h, req); rec.Code != http.StatusUnsupportedMediaType {
		t.Errorf("text/plain POST = %d, want 415", rec.Code)
	}
	// the app and a typed address pass
	for _, hdr := range []map[string]string{nil, {"Sec-Fetch-Site": "none"}, {"Sec-Fetch-Site": "same-origin"}} {
		if rec := del(hdr); rec.Code != http.StatusNoContent {
			t.Fatalf("DELETE with %v = %d", hdr, rec.Code)
		}
		put(t, d.Cfg.NotesModel, 1)
	}
}

// A request can arrive while the delete waits for the engine to drain. The lanes are read again after the stop, so that
// request keeps its model.
// Mutation: internal/daemon/models.go removeModel, delete the second `rm.busy(d)` check (after stopModelEngine) -> RED.
func TestDeleteReadsTheLanesAgainAfterTheEngineStops(t *testing.T) {
	old := modelStopWait
	modelStopWait = 5 * time.Second
	t.Cleanup(func() { modelStopWait = old })
	d, dir := startManagedNotesFake(t)
	mux := http.NewServeMux()
	d.Routes(mux)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	if _, err := d.LLMSup.EnsureReady(t.Context()); err != nil {
		t.Fatal(err)
	}
	g := d.LLMSup.Acquire()
	codes := make(chan int, 1)
	go func() {
		code, _ := doJSON(t, http.MethodDelete, srv.URL+"/v1/models/notes", "")
		codes <- code
	}()
	time.Sleep(300 * time.Millisecond) // the delete is now waiting on the guard
	d.notes.mu.Lock()
	d.notes.running = true // a download is requested meanwhile
	d.notes.mu.Unlock()
	g.Release()
	select {
	case code := <-codes:
		if code != http.StatusConflict {
			t.Fatalf("DELETE = %d, want 409 (a download began while the engine drained)", code)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("DELETE did not return")
	}
	d.notes.mu.Lock()
	d.notes.running = false
	d.notes.mu.Unlock()
	if !exists(filepath.Join(dir, "models", config.NotesModelFile)) {
		t.Fatal("the model was removed")
	}
}

// An engine that is starting is loading the file: the delete says so instead of pulling it away.
func TestDeleteWaitsForAnEngineThatIsStarting(t *testing.T) {
	d, dir := startManagedNotesFake(t)
	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "3000")
	mux := http.NewServeMux()
	d.Routes(mux)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	go func() { _, _ = d.LLMSup.EnsureReady(context.Background()) }()
	deadline := time.Now().Add(5 * time.Second)
	for d.LLMSup.Status().State != engine.StateStarting {
		if time.Now().After(deadline) {
			t.Fatalf("engine never reached starting: %+v", d.LLMSup.Status())
		}
		time.Sleep(10 * time.Millisecond)
	}
	code, body := doJSON(t, http.MethodDelete, srv.URL+"/v1/models/notes", "")
	if code != http.StatusConflict {
		t.Fatalf("DELETE while starting = %d %s, want 409", code, body)
	}
	if !exists(filepath.Join(dir, "models", config.NotesModelFile)) {
		t.Fatal("the model was removed while the engine loaded it")
	}
}

// A file that cannot be removed is an error the caller reads, not a 204.
func TestDeleteReportsAFileThatCannotBeRemoved(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root removes files from a read-only folder")
	}
	d, base, models := modelsServer(t)
	put(t, d.Cfg.NotesModel, 1)
	if err := os.Chmod(models, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(models, 0o755) })
	code, body := doJSON(t, http.MethodDelete, base+"/v1/models/notes", "")
	if code != http.StatusInternalServerError || !strings.Contains(body, "could not be removed") || strings.Contains(body, models) {
		t.Fatalf("DELETE = %d %s, want 500 with a fixed sentence and no path", code, body)
	}
	if !exists(d.Cfg.NotesModel) {
		t.Fatal("the file is gone")
	}
}

// startManagedNotesFake is startNotesFake with the model moved into <home>/models, the only folder a delete may touch.
// It returns the home.
func startManagedNotesFake(t *testing.T) (*Daemon, string) {
	t.Helper()
	d, _ := startNotesFake(t)
	managed := filepath.Join(d.Cfg.Home, "models", config.NotesModelFile)
	if err := os.MkdirAll(filepath.Dir(managed), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(d.Cfg.NotesModel, managed); err != nil {
		t.Fatal(err)
	}
	d.Cfg.NotesModel = managed
	return d, d.Cfg.Home
}

// A model an env override points to, in another folder, is managed outside OxSay: the pinned name is not enough.
// GET still lists it, with removable false so the app hides the button.
// Mutation: internal/daemon/models.go removeModel, delete the `!d.inModelsDir(path)` check -> RED.
func TestDeleteRefusesAModelManagedOutsideTheModelsFolder(t *testing.T) {
	d, base, _ := modelsServer(t)
	other := filepath.Join(filepath.Dir(d.Cfg.Home), "elsewhere", config.NotesModelFile)
	put(t, other, 5)
	d.Cfg.NotesModel = other
	code, body := doJSON(t, http.MethodDelete, base+"/v1/models/notes", "")
	if code != http.StatusBadRequest || !strings.Contains(body, "managed outside OxSay") {
		t.Fatalf("DELETE = %d %s, want 400 managed outside OxSay", code, body)
	}
	if !exists(other) {
		t.Fatal("the file outside the models folder was removed")
	}
	n := find(listModels(t, base), "notes")
	if !n.Installed || n.Removable || !n.Optional {
		t.Fatalf("list row: %+v, want installed, optional, not removable", n)
	}
	d.Cfg.NotesModel = filepath.Join(d.Cfg.Home, "models", config.NotesModelFile)
	put(t, d.Cfg.NotesModel, 1)
	if n := find(listModels(t, base), "notes"); !n.Removable {
		t.Fatalf("a model in the models folder is removable: %+v", n)
	}
}

// GET removable and DELETE use one rule, so the button the app shows is a delete that works. Each case is read through
// GET first and then DELETEd: removable true must be 204, false must be a refusal.
// Mutation: internal/daemon/models.go modelEntries, `e.Removable = d.inModelsDir(def.removal.file(d))` in place of the
// checkRemovable call (a folder-only check) -> RED.
func TestRemovableInGetAgreesWithDelete(t *testing.T) {
	cases := []struct {
		name   string
		setup  func(d *Daemon, models string)
		want   bool
		status int
	}{
		{"managed file", func(d *Daemon, _ string) { put(t, d.Cfg.NotesModel, 1) }, true, http.StatusNoContent},
		{"absent", func(*Daemon, string) {}, false, http.StatusNotFound},
		{"symlink in the models folder", func(d *Daemon, models string) {
			target := filepath.Join(filepath.Dir(models), "elsewhere", "real.gguf")
			put(t, target, 3)
			if err := os.Symlink(target, d.Cfg.NotesModel); err != nil {
				t.Fatal(err)
			}
		}, false, http.StatusBadRequest},
		{"own file in the models folder", func(d *Daemon, models string) {
			d.Cfg.NotesModel = filepath.Join(models, "my-own.gguf")
			put(t, d.Cfg.NotesModel, 1)
		}, false, http.StatusBadRequest},
		{"folder at the model path", func(d *Daemon, _ string) {
			if err := os.MkdirAll(d.Cfg.NotesModel, 0o755); err != nil {
				t.Fatal(err)
			}
		}, false, http.StatusBadRequest},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d, base, models := modelsServer(t)
			c.setup(d, models)
			n := find(listModels(t, base), "notes")
			if n.Removable != c.want {
				t.Fatalf("GET removable = %v, want %v: %+v", n.Removable, c.want, n)
			}
			if code, body := doJSON(t, http.MethodDelete, base+"/v1/models/notes", ""); code != c.status {
				t.Fatalf("DELETE = %d %s, want %d", code, body, c.status)
			}
		})
	}
}

// Recycle stops the engine before it kills the child; a deadline after that is a slow exit, not a busy engine.
// Mutation: internal/daemon/models.go stopModelEngine, delete the `sup.State() == engine.StateStopped` early return -> RED.
func TestDeleteTreatsASlowEngineExitAsStopped(t *testing.T) {
	old := modelStopWait
	modelStopWait = time.Nanosecond
	t.Cleanup(func() { modelStopWait = old })
	d, home := startManagedNotesFake(t)
	mux := http.NewServeMux()
	d.Routes(mux)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	if _, err := d.LLMSup.EnsureReady(t.Context()); err != nil {
		t.Fatal(err)
	}
	if code, body := doJSON(t, http.MethodDelete, srv.URL+"/v1/models/notes", ""); code != http.StatusNoContent {
		t.Fatalf("DELETE = %d %s, want 204 (the engine was stopped)", code, body)
	}
	if exists(filepath.Join(home, "models", config.NotesModelFile)) {
		t.Fatal("the model is still there")
	}
}

// Every 400 and 409 leaves one Info line with the model and the reason, and no path.
// Mutation: internal/daemon/models.go handleModelDelete, delete the `d.log.Info("model removal refused"` call -> RED.
func TestDeleteLogsItsRefusals(t *testing.T) {
	d, base, models := modelsServer(t)
	var buf bytes.Buffer
	d.log = slog.New(slog.NewTextHandler(&buf, nil))
	put(t, d.Cfg.STTWhisperModel, 1)
	d.transcribing.Add(1)
	defer d.transcribing.Add(-1)
	doJSON(t, http.MethodDelete, base+"/v1/models/parakeet", "")
	doJSON(t, http.MethodDelete, base+"/v1/models/whisper", "")
	out := buf.String()
	if strings.Count(out, "model removal refused") != 2 || !strings.Contains(out, "model=parakeet") || !strings.Contains(out, "model=whisper") {
		t.Fatalf("log = %q, want one refusal line per model", out)
	}
	if strings.Contains(out, models) {
		t.Fatalf("a path reached the log: %q", out)
	}
}
