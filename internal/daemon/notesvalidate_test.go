package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/meeting"
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
		c.HostMemoryBytes = 32 << 30 // the test Mac reports its memory
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

// The trial's key is a bearer credential and its pid file a dead handle once
// the check is over — both are gone on every way out: a verdict, a child
// that never loads, a health timeout, a dead completion, a cancel mid-check,
// a daemon shutdown mid-check. Mutation: notesvalidate.go trialLoadModel,
// drop the d.removeNotesTrialFiles() call in the exit defer -> the key
// survives every direct exit -> all rows but the shutdown one RED; that row's
// mutation is the call in stopTrialSup.
func TestNotesModelTrialLeavesNoFilesBehind(t *testing.T) {
	dir := t.TempDir()
	d, _ := trialDaemon(t, dir, nil)
	keyPath := filepath.Join(d.Cfg.RunDir(), notesTrialKeyFile)
	pidPath := filepath.Join(d.Cfg.RunDir(), notesTrialPidFile)
	gone := func(t *testing.T) {
		t.Helper()
		for _, p := range []string{keyPath, pidPath} {
			if _, err := os.Stat(p); !errors.Is(err, fs.ErrNotExist) {
				t.Fatalf("%s survived the trial", filepath.Base(p))
			}
		}
	}
	// spawned parks the check where the key must already exist and the
	// supervisor is registered: a child of THIS trial spawned (Prepare runs
	// ahead of it). A leftover key from a refused row would pass a plain
	// stat at once.
	spawned := func(t *testing.T, before int) {
		t.Helper()
		testutil.WaitFor(t, 5*time.Second, func() bool {
			return len(llmSpawnPids(dir)) > before
		}, "the trial child to spawn")
	}
	path := ownGGUF(t, dir, nil)

	t.Run("a verdict arrives", func(t *testing.T) {
		if res := d.notesModelTrial(context.Background(), path); !res.OK {
			t.Fatalf("verdict = %+v", res)
		}
		gone(t)
	})
	t.Run("the engine exits at once", func(t *testing.T) {
		t.Setenv("OXSAY_FAKE_LLM_EXIT", "1")
		if res := d.notesModelTrial(context.Background(), path); res.OK {
			t.Fatal("the exit-1 model must be refused")
		}
		gone(t)
	})
	t.Run("the engine never answers health", func(t *testing.T) {
		t.Setenv("OXSAY_FAKE_LLM_LOADING_SPAWNS", "99")
		old := notesTrialStartupTimeout
		notesTrialStartupTimeout = 300 * time.Millisecond
		t.Cleanup(func() { notesTrialStartupTimeout = old })
		if res := d.notesModelTrial(context.Background(), path); res.OK {
			t.Fatal("a never-healthy engine must be refused")
		}
		gone(t)
	})
	t.Run("the model does not answer a completion", func(t *testing.T) {
		old := notesTrialCallTimeout
		notesTrialCallTimeout = time.Nanosecond // the completion's ctx is born dead
		t.Cleanup(func() { notesTrialCallTimeout = old })
		if res := d.notesModelTrial(context.Background(), path); res.OK {
			t.Fatal("a dead completion must be refused")
		}
		gone(t)
	})
	t.Run("the check is cancelled mid-start", func(t *testing.T) {
		t.Setenv("OXSAY_FAKE_LLM_LOADING_SPAWNS", "99")
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan notesModelTrial, 1)
		before := len(llmSpawnPids(dir))
		go func() { done <- d.notesModelTrial(ctx, path) }()
		spawned(t, before)
		cancel()
		res := <-done
		if res.OK || !strings.Contains(res.Reason, "cancelled") {
			t.Fatalf("verdict = %+v", res)
		}
		gone(t)
	})
	t.Run("the daemon is shut down mid-check", func(t *testing.T) {
		// The probe parks the check with its engine up: while it parks, its
		// own exit defer cannot have run — files gone right after Shutdown
		// are stopTrialSup's doing alone.
		inTrial := make(chan struct{})
		release := make(chan struct{})
		var once sync.Once
		free := func() { once.Do(func() { close(release) }) }
		defer free()
		notesTrialProbe = func() { close(inTrial); <-release }
		defer func() { notesTrialProbe = nil }()
		done := make(chan notesModelTrial, 1)
		go func() { done <- d.notesModelTrial(context.Background(), path) }()
		<-inTrial
		d.Shutdown()
		gone(t)
		free()
		if res := <-done; res.OK {
			t.Fatalf("verdict = %+v", res)
		}
		gone(t)
	})
}

// The trial's engine reservation — not the queue's admission lock — is what
// a meeting's notes wait on: the probe parks a running trial mid-check, and
// while it holds the engine a real Finish still lands at once and the queued
// job's notes run once the reservation lifts. Mutation: notesvalidate.go
// notesModelTrial, run trialLoadModel inside the WithAdmissionLock body ->
// the finish parks behind it -> RED.
func TestNotesModelTrialNeverBlocksAFinish(t *testing.T) {
	dir := t.TempDir()
	d, _ := trialDaemon(t, dir, nil)

	// The probe parks the trial with its engine up: the reservation is held
	// for as long as the check still runs.
	inTrial := make(chan struct{})
	release := make(chan struct{})
	notesTrialProbe = func() { close(inTrial); <-release }
	t.Cleanup(func() { notesTrialProbe = nil })
	trial := make(chan notesModelTrial, 1)
	go func() { trial <- d.notesModelTrial(context.Background(), ownGGUF(t, dir, nil)) }()
	<-inTrial

	// A real Finish of a real recording lands while the trial still runs:
	// the admission lock was held for the reservation only.
	m, mdir, err := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	writeTone(t, filepath.Join(mdir, meeting.MePCM), 5)
	fin := make(chan error, 1)
	go func() {
		_, err := d.Meet.Finish(m.ID, time.Now())
		fin <- err
	}()
	var ferr error
	testutil.WaitFor(t, 5*time.Second, func() bool {
		select {
		case ferr = <-fin:
			return true
		default:
			return false
		}
	}, "the finish to return while the trial runs")
	if ferr != nil {
		t.Fatal(ferr)
	}
	// The meeting is queued and its notes wait the trial out — they are
	// never refused and never lost.
	if got := meetingManifest(t, d, m.ID); got.Status != meeting.StatusQueued {
		t.Fatalf("status = %s, want queued", got.Status)
	}
	runCtx, stopRun := context.WithCancel(context.Background())
	t.Cleanup(stopRun)
	go d.Meet.Run(runCtx)
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return meetingManifest(t, d, m.ID).Status == meeting.StatusSummarizing
	}, "the meeting's notes to be waiting on the trial")
	close(release)
	if res := <-trial; !res.OK {
		t.Fatalf("verdict = %+v", res)
	}
	testutil.WaitFor(t, 10*time.Second, func() bool {
		return meetingManifest(t, d, m.ID).Status == meeting.StatusDone
	}, "the queued meeting's notes to run once the trial ends")
	if _, err := os.Stat(filepath.Join(mdir, meeting.NotesJSON)); err != nil {
		t.Fatalf("no notes.json after the wait: %v", err)
	}
}

// A Mac that cannot report its memory fails closed: the model cannot be
// checked, so no child starts — the fit gate is not skipped. Mutation:
// notesvalidate.go notesModelTrial, delete the `ram == 0` refusal -> the 70%
// gate is skipped, a child spawns and the verdict is ok -> RED.
func TestNotesModelTrialRefusesWhenMemoryIsUnknown(t *testing.T) {
	dir := t.TempDir()
	_, mux := trialDaemon(t, dir, func(c *config.Config) { c.HostMemoryBytes = 0 })
	path := ownGGUF(t, dir, nil)
	rec := call(t, mux, http.MethodPost, "/v1/meetings/notes-model/validate", `{"path":`+strconv.Quote(path)+`}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("validate: %d %s", rec.Code, bodyText(rec))
	}
	var out struct {
		OK     bool   `json:"ok"`
		Reason string `json:"reason"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out.OK || !strings.Contains(out.Reason, "memory size could not be read") {
		t.Fatalf("verdict = %+v, want ok:false on unknown memory", out)
	}
	if pids := llmSpawnPids(dir); len(pids) != 0 {
		t.Fatalf("an unchecked model spawned %d children", len(pids))
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

// A model that answers in more tokens than the trial's cap still proved it
// generates: finish_reason "length" is an answer — only silence, an error
// or an empty body is not. Mutation: notesvalidate.go trialLoadModel, drop
// the errors.Is(err, meeting.ErrTruncated) case -> RED (the capped answer
// is refused as "did not answer").
func TestNotesModelTrialAcceptsATruncatedAnswer(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_LLM_TRUNCATED", "1")
	d, _ := trialDaemon(t, dir, nil)
	if res := d.notesModelTrial(context.Background(), ownGGUF(t, dir, nil)); !res.OK {
		t.Fatalf("verdict = %+v, a capped answer must prove the model", res)
	}
}

// Two daemons in one process: the PUT's trial must run on the daemon it
// was addressed to — its engine, its run dir, its busy state — never the
// one constructed last. The spawned child's argv is the evidence: the
// trial key file sits in the OWNING daemon's run dir. Mutation:
// notesmodel.go handleNotesModelPut, route the trial through a
// package-level hook bound by the last newDaemon -> RED (the argv names
// the second daemon's run dir).
func TestNotesModelPutTrialsOnItsOwnDaemon(t *testing.T) {
	dirA, dirB := t.TempDir(), t.TempDir()
	dA, muxA := trialDaemon(t, dirA, nil)
	_, _ = trialDaemon(t, dirB, nil)
	path := ownGGUF(t, dirB, nil) // trial stamps land under dirB — the last OXSAY_FAKE_DIR
	rec := call(t, muxA, http.MethodPut, "/v1/meetings/notes-model", `{"path":`+strconv.Quote(path)+`}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT: %d %s", rec.Code, bodyText(rec))
	}
	pids := llmSpawnPids(dirB)
	if len(pids) != 1 {
		t.Fatalf("%d trial spawns, want one", len(pids))
	}
	argv := llmArgv(t, dirB, pids[0])
	want := filepath.Join(dA.Cfg.RunDir(), notesTrialKeyFile)
	if !strings.Contains(argv, "--api-key-file\n"+want) {
		t.Fatalf("trial argv\n%s\nnames %s — the PUT ran the other daemon's trial", argv, want)
	}
}

// A resident notes model is a second large engine on EVERY Mac — the
// residency arbiter only arbitrates turns where memory is tight, so on a
// 48 GB host an unmanaged daemon would leave a resident 20 GB model beside
// a 30 GB trial. The resident child must be down BEFORE the trial child
// comes up. Mutation: notesvalidate.go trialLoadModel, restore the
// `d.mem.managed(d.LLMSup)` condition on the stop -> RED (the resident
// child is still alive inside the trial).
func TestNotesModelTrialStopsAResidentNotesEngine(t *testing.T) {
	dir := t.TempDir()
	d, _ := trialDaemon(t, dir, func(c *config.Config) { c.HostMemoryBytes = 48 << 30 })
	resident := filepath.Join(dir, "resident.gguf")
	if err := os.WriteFile(resident, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(resident, 20<<30); err != nil { // a sparse 20 GB model
		t.Fatal(err)
	}
	if err := writeNotesChoice(d.Cfg.Home, config.NotesChoice{Path: resident}); err != nil {
		t.Fatal(err)
	}
	if _, err := d.LLMSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	resPid := d.LLMSup.Status().PID
	if resPid == 0 {
		t.Fatal("the resident notes child did not start")
	}
	// The probe sees the trial with its engine ready — the resident child
	// must already be down by then.
	var sawResident atomic.Bool
	notesTrialProbe = func() {
		if childAlive(resPid) {
			sawResident.Store(true)
		}
	}
	t.Cleanup(func() { notesTrialProbe = nil })
	own := ownGGUF(t, dir, nil)
	if err := os.Truncate(own, 30<<30); err != nil { // a sparse 30 GB own model
		t.Fatal(err)
	}
	if res := d.notesModelTrial(context.Background(), own); !res.OK {
		t.Fatalf("verdict = %+v", res)
	}
	if sawResident.Load() {
		t.Fatal("the resident notes child was still alive inside the trial")
	}
}

// The trial counts against the same memory gate as the file alone: its
// bytes plus every large engine still resident must leave the gate's
// headroom. A resident fast voice holding 5 GB puts a 30 GB trial over the
// 33.6 GB gate of a 48 GB Mac — refused 409 before a trial child spawns,
// and the resident voice is left running. Mutation: notesvalidate.go
// trialLoadModel, drop the residentBytes term -> RED (the over-gate trial
// runs and answers ok).
func TestNotesModelTrialCountsResidentEnginesAgainstMemory(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_CHILD", "1")
	talker := filepath.Join(dir, "talker.gguf")
	if err := os.WriteFile(talker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(talker, 5<<30); err != nil { // a sparse 5 GB talker
		t.Fatal(err)
	}
	codec := filepath.Join(dir, "codec.gguf")
	if err := os.WriteFile(codec, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	d, _ := trialDaemon(t, dir, func(c *config.Config) {
		c.HostMemoryBytes = 48 << 30
		c.Model, c.Codec = talker, codec
	})
	if _, err := d.Sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	own := ownGGUF(t, dir, nil)
	if err := os.Truncate(own, 30<<30); err != nil {
		t.Fatal(err)
	}
	before := len(llmSpawnPids(dir))
	res := d.notesModelTrial(context.Background(), own)
	if res.OK || res.status != http.StatusConflict {
		t.Fatalf("verdict = %+v, want a 409 refusal", res)
	}
	if got := len(llmSpawnPids(dir)); got != before {
		t.Fatalf("a refused trial spawned %d children", got-before)
	}
	if d.Sup.Status().PID == 0 {
		t.Fatal("the refusal stopped the resident voice engine")
	}
}

// The resident STT server is never part of the residency turns — it is
// small and deliberately never evicted — but its model is still in memory
// while a trial runs, so the same gate counts it: a resident 4 GB
// recognizer puts a 30 GB trial over the 33.6 GB gate of a 48 GB Mac —
// refused 409 before a trial child spawns, and the STT child keeps
// running. Mutation: residency.go residentEngines, drop the STT row ->
// RED (the over-gate trial runs and answers ok).
func TestNotesModelTrialCountsTheResidentSTTAgainstMemory(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_STT", "1")
	sttModel := filepath.Join(dir, "parakeet.bin")
	if err := os.WriteFile(sttModel, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(sttModel, 4<<30); err != nil { // a sparse 4 GB recognizer
		t.Fatal(err)
	}
	d, _ := trialDaemon(t, dir, func(c *config.Config) {
		c.HostMemoryBytes = 48 << 30
		c.STTModel = sttModel
	})
	// The fakes are chosen by env at spawn and the LLM marker shadows the
	// STT one (FakeChildMain checks it first): the marker is off for the
	// resident child's spawn — the real --serve fake — then back on for
	// the trial's, which must never come.
	t.Setenv("OXSAY_FAKE_LLM", "")
	if _, err := d.STTSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Setenv("OXSAY_FAKE_LLM", "1")
	own := ownGGUF(t, dir, nil)
	if err := os.Truncate(own, 30<<30); err != nil { // a sparse 30 GB own model
		t.Fatal(err)
	}
	before := len(llmSpawnPids(dir))
	res := d.notesModelTrial(context.Background(), own)
	if res.OK || res.status != http.StatusConflict {
		t.Fatalf("verdict = %+v, want a 409 refusal", res)
	}
	if !strings.Contains(res.Reason, "36.5 GB") {
		t.Fatalf("reason = %q, want the file-plus-engines total named", res.Reason)
	}
	if got := len(llmSpawnPids(dir)); got != before {
		t.Fatalf("a refused trial spawned %d children", got-before)
	}
	if d.STTSup.Status().PID == 0 {
		t.Fatal("the refusal stopped the resident STT server")
	}
}

// A daemon killed mid-check leaves its trial child running: notes-trial.pid
// names it, and the next daemon's startup reaps it through the same exe +
// start-token check the next trial would use — before any regular notes
// work. A pidfile naming a live same-binary process that is NOT that child
// is left alone. Mutation: service.go newDaemon, delete the startup trial
// reap -> RED (row one: the orphaned child survives startup; row two turns
// red only if the reap ignores the token, e.g. a bare kill of the pid).
func TestDaemonStartupReapsAnOrphanedTrialChild(t *testing.T) {
	t.Run("a leftover trial child is reaped", func(t *testing.T) {
		dir := t.TempDir()
		d1, _ := trialDaemon(t, dir, nil)
		// Park the check mid-trial: the child is up and the pidfile
		// written — the state a SIGKILLed daemon leaves behind.
		inTrial, release := make(chan struct{}), make(chan struct{})
		notesTrialProbe = func() { close(inTrial); <-release }
		t.Cleanup(func() { notesTrialProbe = nil })
		done := make(chan notesModelTrial, 1)
		go func() { done <- d1.notesModelTrial(context.Background(), ownGGUF(t, dir, nil)) }()
		<-inTrial
		pids := llmSpawnPids(dir)
		if len(pids) != 1 {
			t.Fatalf("%d trial spawns, want one", len(pids))
		}
		pidPath := filepath.Join(d1.Cfg.RunDir(), notesTrialPidFile)
		if _, err := os.Stat(pidPath); err != nil {
			t.Fatalf("the trial wrote no pidfile: %v", err)
		}
		// The daemon "dies": the home lock is released while its children
		// stay — the launchd restart next must reap by the pidfile.
		if err := d1.lockFile.Close(); err != nil {
			t.Fatal(err)
		}
		d1.lockFile = nil
		// The restarted daemon comes up on the same home: the parent dir of
		// d1's home, since testCfg builds home = <dir>/home.
		_ = newTestDaemonSTT(t, filepath.Dir(d1.Cfg.Home), func(c *config.Config) {
			c.NotesBin = os.Args[0]
			c.HostMemoryBytes = 32 << 30
		}, nil, nil)
		testutil.WaitFor(t, 5*time.Second, func() bool { return !childAlive(pids[0]) },
			"the orphaned trial child to be reaped at startup")
		if _, err := os.Stat(pidPath); !errors.Is(err, fs.ErrNotExist) {
			t.Fatal("the trial pidfile outlived its child")
		}
		close(release)
		if res := <-done; res.OK {
			t.Fatalf("verdict = %+v, want the reaped-child refusal", res)
		}
	})
	t.Run("a start-token mismatch is left alone", func(t *testing.T) {
		dir := t.TempDir()
		t.Setenv("OXSAY_FAKE_LLM", "1")
		orphan := exec.Command(os.Args[0], "--port", strconv.Itoa(testutil.FreePort(t)))
		orphan.Env = os.Environ()
		if err := orphan.Start(); err != nil {
			t.Fatal(err)
		}
		waitDone := make(chan struct{})
		go func() { _ = orphan.Wait(); close(waitDone) }()
		t.Cleanup(func() { _ = orphan.Process.Kill(); <-waitDone })
		// The pidfile names it, but the token is not its own start instant:
		// a pid recycled onto a same-binary process, never to be killed.
		pidPath := filepath.Join(dir, "home", "run", notesTrialPidFile)
		if err := os.MkdirAll(filepath.Dir(pidPath), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(pidPath, []byte(strconv.Itoa(orphan.Process.Pid)+" 0"), 0o644); err != nil {
			t.Fatal(err)
		}
		_ = newTestDaemonSTT(t, dir, func(c *config.Config) {
			c.NotesBin = os.Args[0]
			c.HostMemoryBytes = 32 << 30
		}, nil, nil)
		// The fake child does not trap SIGTERM: a kill would land within
		// milliseconds; 500 ms is ample on a loaded box.
		select {
		case <-waitDone:
			t.Fatal("the startup reap killed a process whose start token did not match")
		case <-time.After(500 * time.Millisecond):
		}
		if _, err := os.Stat(pidPath); err != nil {
			t.Fatal("the pidfile was removed for a live start-token mismatch")
		}
	})
}

// A trial child the daemon loses track of still self-terminates: its
// supervisor carries the notes engine's own idle stop — the only watchdog
// left once the check's defers and the daemon itself are gone. The child
// is brought up through the trial's own constructor and parked unguarded
// — exactly what a crashed daemon leaves behind — and it must be down
// within one idle window. Mutation: notesvalidate.go
// newNotesTrialSupervisor, drop the IdleStop line -> RED (the parked
// child outlives the window).
func TestNotesModelTrialChildStopsWhenIdle(t *testing.T) {
	dir := t.TempDir()
	d, _ := trialDaemon(t, dir, func(c *config.Config) { c.NotesIdleStop = 300 * time.Millisecond })
	sup, err := d.newNotesTrialSupervisor(ownGGUF(t, dir, nil))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(sup.Shutdown)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatalf("the trial child did not start: %v", err)
	}
	pid := sup.Status().PID
	if pid == 0 {
		t.Fatal("the trial child did not start")
	}
	// No Acquire — the state a daemon crash leaves the child in: ready
	// with nothing holding it, its own idle stop the only stopper.
	testutil.WaitFor(t, 5*time.Second, func() bool { return !childAlive(pid) },
		"the unguarded trial child to be stopped for idleness")
}

// The check holds the child's in-flight guard for the whole run, so the
// idle stop can never find it ready and unguarded: the probe parks the
// check far past the child's own idle window and the guarded child is
// still up at the end of the park, the verdict still ok. Mutation:
// notesvalidate.go trialLoadModel, move the Acquire back below
// EnsureReady, guarding only the completion -> RED (the parked child is
// idle-stopped and the check refused).
func TestNotesModelTrialChildIsGuardedThroughTheCheck(t *testing.T) {
	dir := t.TempDir()
	d, _ := trialDaemon(t, dir, func(c *config.Config) { c.NotesIdleStop = 300 * time.Millisecond })
	var lived atomic.Bool
	notesTrialProbe = func() {
		// A 300 ms idle stop fires inside this park if the child is
		// unguarded; 5x the window leaves the scheduler its margin.
		time.Sleep(1500 * time.Millisecond)
		for _, pid := range llmSpawnPids(dir) {
			lived.Store(childAlive(pid))
		}
	}
	t.Cleanup(func() { notesTrialProbe = nil })
	res := d.notesModelTrial(context.Background(), ownGGUF(t, dir, nil))
	if !lived.Load() {
		t.Fatal("the trial child was idle-stopped while the check still held it")
	}
	if !res.OK {
		t.Fatalf("verdict = %+v", res)
	}
}
