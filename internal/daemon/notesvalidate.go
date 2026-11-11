package daemon

// The own-model check: before a {"path"} choice is saved, and on demand at
// POST /v1/meetings/notes-model/validate, the file is loaded the way the
// notes engine would load it — GGUF version, memory fit, a real ox-llm child
// on a free loopback port, /health, one short completion — so "your own
// model" can only ever be a file that actually runs. The trial child is a
// second large model for its short life: it takes the residency turn a notes
// job would take, is serialized against switches by modelMu, and is stopped
// on every way out. The path the user named never appears in an answer or in
// the daemon's log lines (the child's own engine log is its output, as for
// every engine).

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/meeting"
)

const (
	// notesTrialKeyFile is the trial child's own bearer key. Reusing
	// notes.key would rotate it under a resident engine that still serves
	// its first key — every later notes call would 401 until the next
	// spawn — so the trial gets a key of its own.
	notesTrialKeyFile = "notes-trial.key"
	// notesTrialPidFile lets the next trial reap a child whose daemon died
	// mid-check; the name is separate from the notes engine's own pid file.
	notesTrialPidFile = "notes-trial.pid"
	// notesTrialPrompt is the one short completion that proves the loaded
	// model answers; a few tokens are enough.
	notesTrialPrompt    = "Reply with OK."
	notesTrialMaxTokens = 4
	// notesOwnRAMShare is how much of this Mac's memory an own model may
	// fill: over it the check refuses before a child is even started.
	notesOwnRAMShare = 7 // of 10
)

var (
	// notesTrialStartupTimeout bounds the trial child's /health wait; the
	// notes engine's own startup budget is the honest figure — a model that
	// cannot load in it would not work as a notes model either.
	notesTrialStartupTimeout = notesStartupTimeout
	// notesTrialCallTimeout bounds the single completion after /health; a
	// var so a test can tighten it.
	notesTrialCallTimeout = 60 * time.Second
)

// notesModelTrial is the check's verdict, and the validate route's answer.
// Reason carries the refusal in plain words; the file's path is never part of
// any field.
type notesModelTrial struct {
	OK           bool   `json:"ok"`
	Name         string `json:"name,omitempty"`
	Architecture string `json:"architecture,omitempty"`
	Bytes        int64  `json:"bytes,omitempty"`
	Reason       string `json:"reason,omitempty"`
	status       int    // the refusal's HTTP status; 0 on success
}

// notesModelTrialRefusal adapts the verdict to the PUT's typed-refusal gate.
func (d *Daemon) notesModelTrialRefusal(ctx context.Context, path string) *modelError {
	res := d.notesModelTrial(ctx, path)
	if res.status == 0 {
		return nil
	}
	return &modelError{res.status, res.Reason}
}

// notesModelTrial runs the whole check: the static gates' caller already saw
// to the path itself; here the file must be a v2/v3 GGUF that fits this Mac,
// then the engine must really load it and answer once. Everything before the
// lock fails fast and costs nothing.
func (d *Daemon) notesModelTrial(ctx context.Context, path string) notesModelTrial {
	var out notesModelTrial
	refuse := func(status int, format string, args ...any) notesModelTrial {
		out.Reason = fmt.Sprintf(format, args...)
		out.status = status
		return out
	}
	meta, err := ggufReadMeta(path)
	if err != nil {
		d.log.Warn("own notes model refused at the metadata check", slog.String("reason", err.Error()))
		return refuse(http.StatusBadRequest, "%s", err)
	}
	out.Name, out.Architecture, out.Bytes = meta.Name, meta.Architecture, meta.Bytes
	if meta.Version != 2 && meta.Version != 3 {
		return refuse(http.StatusBadRequest, "The file is GGUF version %d; the notes engine loads version 2 or 3.", meta.Version)
	}
	// A Mac that cannot report its memory fails closed: the model cannot be
	// checked against a limit the daemon does not know.
	ram := d.Cfg.HostMemoryBytes
	if ram == 0 {
		return refuse(http.StatusBadRequest, "This Mac's memory size could not be read; the model cannot be checked.")
	}
	if meta.Bytes > int64(ram*notesOwnRAMShare/10) {
		return refuse(http.StatusBadRequest,
			"The model file is %.1f GB; a notes model must fit in %d%% of this Mac's %d GB of memory.",
			float64(meta.Bytes)/1e9, notesOwnRAMShare*10, ram>>30)
	}
	if d.Cfg.NotesBin == "" {
		return refuse(http.StatusBadRequest, "The notes engine is not installed, so the model cannot be tried.")
	}
	// The trial and a model switch (or removal) touch the same engines and
	// the same choice; modelMu keeps them one at a time. Under the queue's
	// admission lock the busy check and the engine reservation are one step,
	// so a job admitted later always finds the mark and waits the trial out
	// — the lock itself is never held for the run and a finish queues behind
	// nothing.
	d.modelMu.Lock()
	defer d.modelMu.Unlock()
	res := out
	reserved := false
	body := func(active int) error {
		if why := d.notesModelBusyAt(active); why != "" {
			res = refuse(http.StatusConflict, "%s", why)
			return nil
		}
		d.reserveNotesTrial()
		reserved = true
		return nil
	}
	if d.Meet == nil {
		_ = body(0)
	} else {
		_ = d.Meet.WithAdmissionLock(body)
	}
	if !reserved {
		return res
	}
	// The reservation lifts only here, after trialLoadModel's own defers
	// have stopped the child, removed the trial files and left the
	// residency turn — a job that waited on it starts against a free engine.
	defer d.releaseNotesTrial()
	return d.trialLoadModel(ctx, path, out)
}

// trialLoadModel is the part that owns a process: the residency turn a notes
// run of this model would take, the notes engine's own slot freed, then a
// trial ox-llm that is stopped on every way out.
func (d *Daemon) trialLoadModel(ctx context.Context, path string, out notesModelTrial) notesModelTrial {
	refuse := func(status int, format string, args ...any) notesModelTrial {
		out.Reason = fmt.Sprintf(format, args...)
		out.status = status
		return out
	}
	// A large file takes the large-engine turn like the notes job it would
	// be — also on a Mac where only a large notes model is exclusive.
	if out.Bytes > config.NotesExclusiveBytes {
		d.trialExclusive.Store(true)
		defer d.trialExclusive.Store(false)
	}
	leave, err := d.mem.enter(ctx, d.LLMSup, 0)
	if err != nil {
		var busy *engineBusyError
		switch {
		case errors.As(err, &busy):
			return refuse(http.StatusServiceUnavailable, "%s", busy)
		case ctx.Err() != nil:
			return refuse(http.StatusServiceUnavailable, "The model check was cancelled.")
		default:
			d.log.Warn("own notes model: the engine turn could not be taken", "error", err)
			return refuse(http.StatusInternalServerError, "The model check could not take the engine turn.")
		}
	}
	defer leave()
	// The resident notes engine is itself a second large model in memory: a
	// trial beside it can exceed physical RAM on ANY Mac — d.mem arbitrates
	// the engines' turns only where memory is tight, so on a Mac it does not
	// manage nothing else would make room. It goes first, whatever the
	// arbiter's state.
	if err := d.stopModelEngine(ctx, d.LLMSup); err != nil {
		var me *modelError
		if errors.As(err, &me) {
			return refuse(me.status, "%s", me.msg)
		}
		d.log.Warn("own notes model: the resident notes engine could not be stopped", "error", err)
		return refuse(http.StatusInternalServerError, "The notes engine could not be stopped for the model check.")
	}
	// The file's bytes plus every large model still resident — the voices,
	// where nothing evicts them — must leave the headroom the file alone
	// needed; memory the trial does not get still counts against it.
	if rem := out.Bytes + d.residentEngineBytes(); rem > int64(d.Cfg.HostMemoryBytes*notesOwnRAMShare/10) {
		return refuse(http.StatusConflict,
			"The model file plus the engines still resident is %.1f GB; together they must fit in %d%% of this Mac's %d GB of memory.",
			float64(rem)/1e9, notesOwnRAMShare*10, d.Cfg.HostMemoryBytes>>30)
	}
	sup, err := d.newNotesTrialSupervisor(path)
	if err != nil {
		d.log.Warn("own notes model: the trial engine could not be set up", "error", err)
		return refuse(http.StatusInternalServerError, "The model check could not start the notes engine.")
	}
	// The child dies on every path out of here — a failed start, a failed
	// completion, the caller's ctx ending, or the verdict arriving — and
	// d.trialSup lets the daemon's Shutdown kill it too. Its files go with
	// it: the key is a bearer credential and the pid file a dead handle.
	d.setTrialSup(sup)
	defer func() {
		d.clearTrialSup(sup)
		sup.Shutdown()
		d.removeNotesTrialFiles()
	}()
	base, err := sup.EnsureReady(ctx)
	if err != nil {
		d.log.Warn("own notes model: the trial engine did not start", "error", err)
		switch {
		case ctx.Err() != nil:
			return refuse(http.StatusServiceUnavailable, "The model check was cancelled.")
		case engine.IsStartTimeout(err):
			return refuse(http.StatusBadRequest, "The notes engine did not come up within %s — the file may not be a loadable model.", notesTrialStartupTimeout)
		default:
			return refuse(http.StatusBadRequest, "The notes engine could not load the file as a model.")
		}
	}
	// The engine is up and the check mid-run: a test parks here to act while
	// the trial still owns the engine. nil in production.
	if notesTrialProbe != nil {
		notesTrialProbe()
	}
	cctx, cancel := context.WithTimeout(ctx, notesTrialCallTimeout)
	defer cancel()
	// The guard marks the completion as work the child is serving, so the
	// idle stop can only ever fire on a child the check left behind.
	g := sup.Acquire()
	answer, err := d.notesTrialChat(base).Complete(cctx, meeting.Request{User: notesTrialPrompt, MaxTokens: notesTrialMaxTokens})
	g.Release()
	switch {
	case errors.Is(err, meeting.ErrTruncated):
		// finish_reason "length": the model answered past the token cap —
		// that answer is the proof it generates; only silence is a refusal.
	case err != nil:
		d.log.Warn("own notes model: the test completion failed", "error", err)
		if ctx.Err() != nil {
			return refuse(http.StatusServiceUnavailable, "The model check was cancelled.")
		}
		return refuse(http.StatusBadRequest, "The model loaded but did not answer a test completion.")
	}
	if strings.TrimSpace(answer) == "" {
		return refuse(http.StatusBadRequest, "The model loaded but did not answer a test completion.")
	}
	out.OK = true
	return out
}

// residentEngineBytes is the model memory the large engines still hold
// while the trial runs — each live supervisor's footprint, measured the way
// /v1/models reports it (the real file size, or the estimate where the file
// cannot be read back from a running child). The trial counts it against
// the same memory gate as its own file.
func (d *Daemon) residentEngineBytes() int64 {
	var n int64
	if d.Sup != nil && d.Sup.Status().PID != 0 {
		n += d.qwenModelEntry().Bytes
	}
	if d.VoxSup != nil && d.VoxSup.Status().PID != 0 {
		n += d.voxModelEntry().Bytes
	}
	if d.LLMSup != nil && d.LLMSup.Status().PID != 0 {
		n += d.notesModelEntry().Bytes
	}
	return n
}

// freeLoopbackPort asks the kernel for a free loopback port; the child binds
// it a moment later, the same known window notesPrepare documents.
func freeLoopbackPort() (int, error) {
	ln, err := net.Listen("tcp", voxLoopbackHost+":0")
	if err != nil {
		return 0, err
	}
	defer func() { _ = ln.Close() }()
	return ln.Addr().(*net.TCPAddr).Port, nil
}

// newNotesTrialSupervisor is the trial's ox-llm: the daemon's own notes argv
// on a free loopback port, its own key and pid files, and the notes engine's
// own idle stop — a child a check loses track of still self-terminates.
// Constructing it also reaps the previous trial's orphan through the pidfile.
func (d *Daemon) newNotesTrialSupervisor(path string) (*engine.Supervisor, error) {
	port, err := freeLoopbackPort()
	if err != nil {
		return nil, fmt.Errorf("no free loopback port: %w", err)
	}
	keyPath := filepath.Join(d.Cfg.RunDir(), notesTrialKeyFile)
	return engine.New(engine.Config{
		Name: "notes-trial", Bin: notesBinPath(d.Cfg), Port: port,
		StartupTimeout: notesTrialStartupTimeout,
		IdleStop:       d.Cfg.NotesIdleStop,
		LogName:        "notes-trial.log", LogDir: d.Cfg.EngineLogDir,
		PidPath: filepath.Join(d.Cfg.RunDir(), notesTrialPidFile),
		Logger:  d.log,
		Args:    func(p int) []string { return notesServerArgsKey(d.Cfg, p, path, notesTrialKeyFile) },
		Env:     notesServerEnv(d.Cfg),
		Prepare: func() error { return notesTrialPrepare(keyPath) },
		Verify:  notesVerifyAuth,
	})
}

// notesTrialPrepare is notesPrepare's key half: the trial's port came free
// from the kernel a moment ago, so only the key file needs making whole.
func notesTrialPrepare(keyPath string) error {
	if err := writeNotesKey(keyPath); err != nil {
		return fmt.Errorf("notes trial: cannot write the server key: %w", err)
	}
	if err := checkNotesKey(keyPath); err != nil {
		_ = os.Remove(keyPath)
		return fmt.Errorf("notes trial: %w; not starting the server", err)
	}
	return nil
}

// notesTrialChat is the trial's one completion client: the same
// OpenAI-compatible shape a notes run uses, keyed by the trial's own key
// file, read at call time like the resident engine's.
func (d *Daemon) notesTrialChat(base string) meeting.Chat {
	return meeting.HTTPChat{
		BaseURL: base,
		Key: func() (string, error) {
			raw, err := os.ReadFile(filepath.Join(d.Cfg.RunDir(), notesTrialKeyFile))
			key := strings.TrimSpace(string(raw))
			if err == nil && key == "" {
				err = errors.New("the notes server key is empty")
			}
			return key, err
		},
	}
}

// The trial child's supervisor while it runs: set before EnsureReady, cleared
// when the child is down, so a daemon shutdown landing mid-check still kills
// it.
func (d *Daemon) setTrialSup(sup *engine.Supervisor) {
	d.trialMu.Lock()
	d.trialSup = sup
	d.trialMu.Unlock()
}

func (d *Daemon) clearTrialSup(sup *engine.Supervisor) {
	d.trialMu.Lock()
	if d.trialSup == sup {
		d.trialSup = nil
	}
	d.trialMu.Unlock()
}

// stopTrialSup is the daemon-shutdown half of "no orphan ox-llm": a check in
// flight when the daemon ends loses its child here; Shutdown on an already
// stopped supervisor is a no-op, so the trial's own cleanup cannot conflict.
// The reservation and the child's files go with it wherever the check's
// goroutine is — its own defer may lose the race against process exit.
func (d *Daemon) stopTrialSup() {
	d.trialMu.Lock()
	sup := d.trialSup
	d.trialMu.Unlock()
	if sup != nil {
		sup.Shutdown()
	}
	d.releaseNotesTrial()
	d.removeNotesTrialFiles()
}

// notesTrialProbe, when set, runs inside a trial once its engine is ready —
// a test parks the check there to act while the trial still owns the engine.
var notesTrialProbe func()

// removeNotesTrialFiles deletes the trial child's key and pid files: the key
// is a bearer credential and neither has a reader once the child is down.
func (d *Daemon) removeNotesTrialFiles() {
	for _, name := range []string{notesTrialKeyFile, notesTrialPidFile} {
		if err := os.Remove(filepath.Join(d.Cfg.RunDir(), name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			d.log.Warn("own notes model: a trial file could not be removed", slog.String("file", name), slog.Any("error", err))
		}
	}
}

// reserveNotesTrial marks the notes engine as held by a trial; it runs where
// the idle check ran — inside the queue's admission lock — so a job admitted
// after it always sees the mark. The mark is a closed-once channel, so any
// number of notes jobs wait the same trial out.
func (d *Daemon) reserveNotesTrial() {
	d.trialMu.Lock()
	if d.trialDone != nil {
		close(d.trialDone) // a leaked reservation never strands a waiter
	}
	d.trialDone = make(chan struct{})
	d.trialMu.Unlock()
}

// releaseNotesTrial clears the reservation; a waiting notes job takes the
// engine turn next. Idempotent — the trial's own exit defer and stopTrialSup
// (daemon Shutdown) can both run it.
func (d *Daemon) releaseNotesTrial() {
	d.trialMu.Lock()
	if d.trialDone != nil {
		close(d.trialDone)
		d.trialDone = nil
	}
	d.trialMu.Unlock()
}

// waitNotesTrial holds a notes job's engine claim back while a trial owns
// the engine: the job waits the trial out on its own context — it is never
// refused and never lost.
func (d *Daemon) waitNotesTrial(ctx context.Context) error {
	d.trialMu.Lock()
	done := d.trialDone
	d.trialMu.Unlock()
	if done == nil {
		return nil
	}
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// notesEngineTurn is the notes model's residency turn (residency.go) behind
// the own-model trial's reservation: while a trial holds the engine the job
// waits it out instead of meeting the trial's second large model in the same
// memory. The trial itself enters d.mem directly — it cannot wait on its own
// mark.
func (d *Daemon) notesEngineTurn(ctx context.Context) (func(), error) {
	if err := d.waitNotesTrial(ctx); err != nil {
		return nil, err
	}
	return d.mem.enter(ctx, d.LLMSup, 0)
}

// handleNotesModelValidate answers POST /v1/meetings/notes-model/validate:
// the same check PUT {"path"} runs before saving, without saving anything.
// The verdict is always a 200 answer — ok plus the model's own name and
// architecture, or ok:false with the refusal in reason; only a malformed
// request is a 400.
func (d *Daemon) handleNotesModelValidate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Path string `json:"path"`
	}
	if err := decodeStrict(r, &req); err != nil || req.Path == "" {
		writeErr(w, http.StatusBadRequest, "The request body must be a JSON object like {\"path\":\"/abs/model.gguf\"}.")
		return
	}
	if why := notesModelPathError(req.Path); why != "" {
		writeJSON(w, http.StatusOK, notesModelTrial{Reason: why, status: http.StatusBadRequest})
		return
	}
	writeJSON(w, http.StatusOK, d.notesModelTrial(r.Context(), req.Path))
}
