package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// trialDaemon is a meeting daemon whose ox-llm is the test binary re-exec'd
// as the fake llm; every spawn stamps its argv as "llm-spawn-<pid>" in dir.
func trialDaemon(t *testing.T, dir string, edit func(*config.Config)) (*Daemon, *http.ServeMux) {
	t.Helper()
	t.Setenv("OXSAY_FAKE_LLM", "1")
	t.Setenv("OXSAY_FAKE_DIR", dir)
	return meetingFixture(t, func(c *config.Config) {
		c.NotesBin = os.Args[0]
		if edit != nil {
			edit(c)
		}
	})
}

// ownGGUF writes a loadable-looking v3 model file the static gate accepts.
func ownGGUF(t *testing.T, dir string, kvs []ggufKV) string {
	t.Helper()
	path := filepath.Join(dir, "own.gguf")
	if err := os.WriteFile(path, writeTestGGUF(t, 3, kvs), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func llmSpawnPids(dir string) []int {
	paths, _ := filepath.Glob(filepath.Join(dir, "llm-spawn-*"))
	var pids []int
	for _, p := range paths {
		if pid, err := strconv.Atoi(strings.TrimPrefix(filepath.Base(p), "llm-spawn-")); err == nil {
			pids = append(pids, pid)
		}
	}
	return pids
}

func llmArgv(t *testing.T, dir string, pid int) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dir, "llm-spawn-"+strconv.Itoa(pid)))
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func childAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// The validate route proves the file loads the way the notes engine would
// load it: a real ox-llm child on the daemon's own argv, its own key, one
// completion — and the child is gone once the verdict is out.
func TestNotesModelValidateLoadsAnOwnModel(t *testing.T) {
	dir := t.TempDir()
	d, mux := trialDaemon(t, dir, nil)
	path := ownGGUF(t, dir, []ggufKV{
		{Key: "general.architecture", Type: ggufTypeString, Str: "qwen3"},
		{Key: "general.name", Type: ggufTypeString, Str: "Mine"},
	})
	rec := call(t, mux, http.MethodPost, "/v1/meetings/notes-model/validate", `{"path":`+strconv.Quote(path)+`}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("validate: %d %s", rec.Code, bodyText(rec))
	}
	var out struct {
		OK           bool   `json:"ok"`
		Name         string `json:"name"`
		Architecture string `json:"architecture"`
		Bytes        int64  `json:"bytes"`
		Reason       string `json:"reason"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if !out.OK || out.Name != "Mine" || out.Architecture != "qwen3" || out.Bytes == 0 || out.Reason != "" {
		t.Fatalf("verdict = %+v", out)
	}
	pids := llmSpawnPids(dir)
	if len(pids) != 1 {
		t.Fatalf("%d trial spawns, want one", len(pids))
	}
	argv := llmArgv(t, dir, pids[0])
	// The daemon's own notes argv: the model path on -m, the trial's own key
	// file — never notes.key, which a resident child still serves.
	for _, want := range []string{
		"-m\n" + path,
		"--jinja", "-np\n1", "--api-key-file\n" + filepath.Join(d.Cfg.RunDir(), notesTrialKeyFile),
	} {
		if !strings.Contains(argv, want) {
			t.Fatalf("trial argv\n%s\nmissing %q", argv, want)
		}
	}
	testutil.WaitFor(t, 5*time.Second, func() bool { return !childAlive(pids[0]) },
		"the trial child to be stopped after the verdict")
	// And nothing was saved by a check: no choice file.
	if ch := readNotesChoice(d.Cfg.Home); ch != nil {
		t.Fatalf("a validate saved a choice: %+v", ch)
	}
}

// PUT {"path"} runs the same check before the choice may be saved: a file
// the engine refuses is a reasoned 400 and writes nothing; a file that loads
// is saved and answers the resolved custom model.
func TestNotesModelPutRunsTheTrialBeforeSaving(t *testing.T) {
	dir := t.TempDir()
	d, mux := trialDaemon(t, dir, nil)
	path := ownGGUF(t, dir, nil)
	// A file the engine cannot load.
	t.Setenv("OXSAY_FAKE_LLM_EXIT", "1")
	rec := call(t, mux, http.MethodPut, "/v1/meetings/notes-model", `{"path":`+strconv.Quote(path)+`}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("PUT an unloadable model: %d %s", rec.Code, bodyText(rec))
	}
	if got := bodyText(rec); strings.Contains(got, path) {
		t.Fatalf("the refusal names the user's path: %s", got)
	}
	if ch := readNotesChoice(d.Cfg.Home); ch != nil {
		t.Fatalf("a refused model was saved: %+v", ch)
	}
	// The same file with a working engine.
	t.Setenv("OXSAY_FAKE_LLM_EXIT", "")
	rec = call(t, mux, http.MethodPut, "/v1/meetings/notes-model", `{"path":`+strconv.Quote(path)+`}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT a loadable model: %d %s", rec.Code, bodyText(rec))
	}
	if res := d.notesResolve(); res.ID != config.NotesCustomID || res.Path != path {
		t.Fatalf("resolved = %+v, want the custom own model", res)
	}
}

// The route's own surface: a reasoned 200 verdict for a file that fails the
// static gate, a 400 only for a malformed request.
func TestNotesModelValidateRouteAnswers(t *testing.T) {
	dir := t.TempDir()
	_, mux := trialDaemon(t, dir, nil)
	for _, body := range []string{`{}`, `{"path":""}`, `not json`, `{"path":1}`} {
		if rec := call(t, mux, http.MethodPost, "/v1/meetings/notes-model/validate", body); rec.Code != http.StatusBadRequest {
			t.Fatalf("validate %s: %d, want 400", body, rec.Code)
		}
	}
	rec := call(t, mux, http.MethodPost, "/v1/meetings/notes-model/validate", `{"path":"rel/x.gguf"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("validate a bad path: %d", rec.Code)
	}
	var out struct {
		OK     bool   `json:"ok"`
		Reason string `json:"reason"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out.OK || !strings.Contains(out.Reason, "absolute") {
		t.Fatalf("verdict = %+v, want ok:false on the relative path", out)
	}
}

// F3 — the user points at a 30 GB-class GGUF on a 16 GB Mac: refused before
// any child starts, with the sizes named and the path never echoed. The
// named mutation drops the RAM-share check at the call site in
// notesModelTrial -> RED (a child then spawns, and the verdict turns ok).
func TestNotesModelTrialRefusesAModelTooBigForRAM(t *testing.T) {
	dir := t.TempDir()
	_, mux := trialDaemon(t, dir, func(c *config.Config) { c.HostMemoryBytes = 16 << 30 })
	path := ownGGUF(t, dir, nil)
	if err := os.Truncate(path, 12<<30); err != nil { // a sparse 12 GB file
		t.Fatal(err)
	}
	rec := call(t, mux, http.MethodPost, "/v1/meetings/notes-model/validate", `{"path":`+strconv.Quote(path)+`}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("validate: %d", rec.Code)
	}
	var out struct {
		OK     bool   `json:"ok"`
		Reason string `json:"reason"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out.OK || !strings.Contains(out.Reason, "12.9 GB") || !strings.Contains(out.Reason, "16 GB") {
		t.Fatalf("verdict = %+v, want the sizes named in GB", out)
	}
	if strings.Contains(out.Reason, path) {
		t.Fatalf("the refusal echoes the path: %s", out.Reason)
	}
	rec = call(t, mux, http.MethodPut, "/v1/meetings/notes-model", `{"path":`+strconv.Quote(path)+`}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("PUT a too-big model: %d, want 400", rec.Code)
	}
	if pids := llmSpawnPids(dir); len(pids) != 0 {
		t.Fatalf("a refused model spawned %d children", len(pids))
	}
}

// F4 — a file the engine cannot load: refused, and no ox-llm child survives
// the refusal. The named mutation drops the stop on the failure path in
// trialLoadModel -> RED: the completion-failure row's child stays alive and
// its pid is asserted gone.
func TestNotesModelTrialRefusesAModelThatDoesNotLoad(t *testing.T) {
	dir := t.TempDir()
	d, _ := trialDaemon(t, dir, nil)
	path := ownGGUF(t, dir, nil)
	assertNoLiveChild := func(t *testing.T) {
		t.Helper()
		for _, pid := range llmSpawnPids(dir) {
			testutil.WaitFor(t, 5*time.Second, func() bool { return !childAlive(pid) },
				"the trial child to be gone")
		}
	}
	t.Run("the engine exits at once", func(t *testing.T) {
		t.Setenv("OXSAY_FAKE_LLM_EXIT", "1")
		res := d.notesModelTrial(context.Background(), path)
		if res.OK || !strings.Contains(res.Reason, "could not load") {
			t.Fatalf("verdict = %+v", res)
		}
		assertNoLiveChild(t)
	})
	t.Run("the engine never answers health", func(t *testing.T) {
		t.Setenv("OXSAY_FAKE_LLM_LOADING_SPAWNS", "99")
		old := notesTrialStartupTimeout
		notesTrialStartupTimeout = 300 * time.Millisecond
		t.Cleanup(func() { notesTrialStartupTimeout = old })
		res := d.notesModelTrial(context.Background(), path)
		if res.OK || !strings.Contains(res.Reason, "did not come up") {
			t.Fatalf("verdict = %+v", res)
		}
		assertNoLiveChild(t)
	})
	t.Run("the model does not answer a completion", func(t *testing.T) {
		old := notesTrialCallTimeout
		notesTrialCallTimeout = time.Nanosecond // the completion's ctx is born dead
		t.Cleanup(func() { notesTrialCallTimeout = old })
		res := d.notesModelTrial(context.Background(), path)
		if res.OK || !strings.Contains(res.Reason, "did not answer") {
			t.Fatalf("verdict = %+v", res)
		}
		assertNoLiveChild(t)
	})
}

// F5 — the trial takes the residency turn like a notes job: the other large
// engine is evicted for it, and the turn goes back on every way out —
// including a refused load. The named mutation drops the release in
// trialLoadModel -> RED (n stays 1).
func TestNotesModelTrialHoldsAndReleasesTheResidencyTurn(t *testing.T) {
	dir := t.TempDir()
	d, _ := trialDaemon(t, dir, nil)
	t.Setenv("OXSAY_FAKE_LLM_EXIT", "1")
	other := &engine.Supervisor{}
	var mu sync.Mutex
	stopped := map[*engine.Supervisor]bool{}
	d.mem = &residency{
		change:  make(chan struct{}),
		engines: []*engine.Supervisor{d.LLMSup, other},
		log:     testLogger(t),
		stop: func(_ context.Context, e *engine.Supervisor) error {
			mu.Lock()
			stopped[e] = true
			mu.Unlock()
			return nil
		},
	}
	path := ownGGUF(t, dir, nil)
	res := d.notesModelTrial(context.Background(), path)
	if res.OK {
		t.Fatal("the exit-1 model must be refused")
	}
	mu.Lock()
	evicted := stopped[other]
	mu.Unlock()
	if !evicted {
		t.Fatal("the trial never took the residency turn")
	}
	d.mem.mu.Lock()
	n := d.mem.n
	d.mem.mu.Unlock()
	if n != 0 {
		t.Fatalf("the turn outlived the trial: n=%d", n)
	}
}

// The trial and a switch are one-at-a-time under modelMu: a refused model
// leaves the saved choice untouched and the turn free for the next one.
func TestNotesModelTrialLeavesTheChoiceUntouched(t *testing.T) {
	dir := t.TempDir()
	d, _ := trialDaemon(t, dir, nil)
	t.Setenv("OXSAY_FAKE_LLM_EXIT", "1")
	if err := writeNotesChoice(d.Cfg.Home, config.NotesChoice{ID: "qwen3.5-4b"}); err != nil {
		t.Fatal(err)
	}
	if res := d.notesModelTrial(context.Background(), ownGGUF(t, dir, nil)); res.OK {
		t.Fatal("the exit-1 model must be refused")
	}
	if ch := readNotesChoice(d.Cfg.Home); ch == nil || ch.ID != "qwen3.5-4b" {
		t.Fatalf("a refused trial changed the saved choice: %+v", ch)
	}
}
