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
	if ram := d.Cfg.HostMemoryBytes; ram > 0 && meta.Bytes > int64(ram*notesOwnRAMShare/10) {
		return refuse(http.StatusBadRequest,
			"The model file is %.1f GB; a notes model must fit in %d%% of this Mac's %d GB of memory.",
			float64(meta.Bytes)/1e9, notesOwnRAMShare*10, ram>>30)
	}
	if d.Cfg.NotesBin == "" {
		return refuse(http.StatusBadRequest, "The notes engine is not installed, so the model cannot be tried.")
	}
	// The trial and a model switch (or removal) touch the same engines and
	// the same choice; modelMu keeps them one at a time, and the queue's
	// admission lock makes the busy check and the trial one step.
	d.modelMu.Lock()
	defer d.modelMu.Unlock()
	var res notesModelTrial
	body := func(active int) error {
		if why := d.notesModelBusyAt(active); why != "" {
			res = refuse(http.StatusConflict, "%s", why)
			return nil
		}
		res = d.trialLoadModel(ctx, path, out)
		return nil
	}
	if d.Meet == nil {
		_ = body(0)
	} else {
		_ = d.Meet.WithAdmissionLock(body)
	}
	return res
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
	// A managed notes engine keeps its model resident; the trial is a
	// second large model in the same memory, so it goes first — the same
	// slot a notes run takes over.
	if d.LLMSup != nil && d.mem.managed(d.LLMSup) {
		if err := d.stopModelEngine(ctx, d.LLMSup); err != nil {
			var me *modelError
			if errors.As(err, &me) {
				return refuse(me.status, "%s", me.msg)
			}
			d.log.Warn("own notes model: the resident notes engine could not be stopped", "error", err)
			return refuse(http.StatusInternalServerError, "The notes engine could not be stopped for the model check.")
		}
	}
	sup, err := d.newNotesTrialSupervisor(path)
	if err != nil {
		d.log.Warn("own notes model: the trial engine could not be set up", "error", err)
		return refuse(http.StatusInternalServerError, "The model check could not start the notes engine.")
	}
	// The child dies on every path out of here — a failed start, a failed
	// completion, the caller's ctx ending, or the verdict arriving — and
	// d.trialSup lets the daemon's Shutdown kill it too.
	d.setTrialSup(sup)
	defer func() {
		d.clearTrialSup(sup)
		sup.Shutdown()
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
	cctx, cancel := context.WithTimeout(ctx, notesTrialCallTimeout)
	defer cancel()
	_, err = d.notesTrialChat(base).Complete(cctx, meeting.Request{User: notesTrialPrompt, MaxTokens: notesTrialMaxTokens})
	if err != nil {
		d.log.Warn("own notes model: the test completion failed", "error", err)
		if ctx.Err() != nil {
			return refuse(http.StatusServiceUnavailable, "The model check was cancelled.")
		}
		return refuse(http.StatusBadRequest, "The model loaded but did not answer a test completion.")
	}
	out.OK = true
	return out
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
// on a free loopback port, its own key and pid files, no idle stop.
func (d *Daemon) newNotesTrialSupervisor(path string) (*engine.Supervisor, error) {
	port, err := freeLoopbackPort()
	if err != nil {
		return nil, fmt.Errorf("no free loopback port: %w", err)
	}
	keyPath := filepath.Join(d.Cfg.RunDir(), notesTrialKeyFile)
	return engine.New(engine.Config{
		Name: "notes-trial", Bin: notesBinPath(d.Cfg), Port: port,
		StartupTimeout: notesTrialStartupTimeout,
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
func (d *Daemon) stopTrialSup() {
	d.trialMu.Lock()
	sup := d.trialSup
	d.trialMu.Unlock()
	if sup != nil {
		sup.Shutdown()
	}
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
