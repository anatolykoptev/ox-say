package daemon

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/meeting"
)

// Expected sizes of the optional models that scripts/fetch-models.sh does not pin by size (it pins a SHA-256). They
// are the README's figures, shown for a model that is not installed yet; an installed model reports its real size.
const (
	approxVoxCPM2Bytes = 3_000_000_000
	approxWhisperBytes = 1_600_000_000
)

// modelStopWait bounds how long a removal waits for an engine to finish a request it holds a guard for. The busy lanes
// are checked first, so this only covers work the lanes do not count; the removal then answers 409 and keeps the file.
// A variable so a test can shorten it.
var modelStopWait = 5 * time.Second

// modelEntry is one row of GET /v1/models.
type modelEntry struct {
	ID         string `json:"id"`   // qwen3-tts | voxcpm2 | parakeet | whisper | notes
	Kind       string `json:"kind"` // speech | transcribe | notes
	Name       string `json:"name"` // real model name, shown only in Advanced
	Bytes      int64  `json:"bytes"`
	Installed  bool   `json:"installed"`
	Default    bool   `json:"default"`   // the daemon's own default for its kind
	Optional   bool   `json:"optional"`  // the user may install / remove it
	Removable  bool   `json:"removable"` // optional, and its file is in <home>/models: false when an env override puts it elsewhere
	Installing bool   `json:"installing"`
	Supported  bool   `json:"supported"` // this Mac can run it (not "ready now": a missing model or engine is still supported)
	ReasonCode string `json:"reason_code,omitempty"`
	Reason     string `json:"reason,omitempty"`
}

// modelRemoval says how one optional model is removed. A model without one is required by the release and is never
// deletable. Everything a removal touches comes from here, never from the request: the request supplies only an id,
// and the id selects a row of modelTable.
type modelRemoval struct {
	// file is the configured path of the model.
	file func(d *Daemon) string
	// pinned is the one file name fetch-models.sh writes. Another name is the user's own file (OX_SAY_*_MODEL points at
	// it) and is never removed, as InstallNotesModel never downloads over it.
	pinned string
	// busy is the plain-words reason the model is in use right now, or "".
	busy func(d *Daemon) string
	// engine is the supervisor whose child has the file open; nil when nothing resident does (whisper runs per call).
	engine func(d *Daemon) *engine.Supervisor
}

// modelDef is one model: its row and, for an optional one, its removal. A branch that adds a model appends one def; the
// diarization models (a directory with a revision marker) are not in this table and cannot be reached by DELETE.
type modelDef struct {
	id      string
	entry   func(d *Daemon) modelEntry
	removal *modelRemoval
}

var modelTable = []modelDef{
	{id: config.TTSModelQwen, entry: (*Daemon).qwenModelEntry},
	{id: config.TTSModelVoxCPM2, entry: (*Daemon).voxModelEntry, removal: &modelRemoval{
		file:   func(d *Daemon) string { return d.Cfg.VoxCPM2Model },
		pinned: config.VoxCPM2ModelFile,
		busy: func(d *Daemon) string {
			b := d.busy()
			if b.Speaking > 0 || b.Designing > 0 || b.Produce > 0 {
				return "The studio voice is being used right now. Try again when it has finished."
			}
			return ""
		},
		engine: func(d *Daemon) *engine.Supervisor { return d.VoxSup },
	}},
	{id: "parakeet", entry: (*Daemon).parakeetModelEntry},
	{id: "whisper", entry: (*Daemon).whisperModelEntry, removal: &modelRemoval{
		file:   func(d *Daemon) string { return d.Cfg.STTWhisperModel },
		pinned: "ggml-large-v3-turbo.bin",
		busy: func(d *Daemon) string {
			if d.busy().Transcribing > 0 {
				return "A transcription is running. Try again when it has finished."
			}
			return ""
		},
	}},
	{id: "notes", entry: (*Daemon).notesModelEntry, removal: &modelRemoval{
		file:   func(d *Daemon) string { return d.Cfg.NotesModel },
		pinned: config.NotesModelFile,
		busy:   (*Daemon).notesModelBusy,
		engine: func(d *Daemon) *engine.Supervisor { return d.LLMSup },
	}},
}

// modelEntries builds every row. Each model stats its one or two files and nothing else: no directory is walked, so the
// call costs the same on a 3 GB model as on an empty one.
func (d *Daemon) modelEntries() []modelEntry {
	out := make([]modelEntry, 0, len(modelTable))
	for _, def := range modelTable {
		e := def.entry(d)
		e.Optional = def.removal != nil
		if def.removal != nil {
			_, _, err := d.checkRemovable(def.removal)
			e.Removable = err == nil
		}
		out = append(out, e)
	}
	return out
}

// fileSize is the size of a regular file at path. A link is followed (a model kept on another disk is still installed);
// a folder, a missing path and an unreadable one are not a model.
func fileSize(path string) (int64, bool) {
	if path == "" {
		return 0, false
	}
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() {
		return 0, false
	}
	return st.Size(), true
}

// filesSize is the total size of paths; installed only when every one is a regular file.
func filesSize(paths ...string) (total int64, installed bool) {
	for _, p := range paths {
		n, ok := fileSize(p)
		if !ok {
			return 0, false
		}
		total += n
	}
	return total, true
}

func (d *Daemon) qwenModelEntry() modelEntry {
	size, ok := filesSize(d.Cfg.Model, d.Cfg.Codec)
	return modelEntry{
		ID: config.TTSModelQwen, Kind: "speech", Name: "Qwen3-TTS 0.6B",
		Bytes: size, Installed: ok, Default: d.Cfg.TTSModel == config.TTSModelQwen || d.Cfg.TTSModel == "",
		Supported: true,
	}
}

func (d *Daemon) voxModelEntry() modelEntry {
	size, ok := fileSize(d.Cfg.VoxCPM2Model)
	e := modelEntry{
		ID: config.TTSModelVoxCPM2, Kind: "speech", Name: "VoxCPM2 Q8_0",
		Bytes: size, Installed: ok, Default: d.Cfg.TTSModel == config.TTSModelVoxCPM2, Supported: true,
	}
	if !ok {
		e.Bytes = approxVoxCPM2Bytes
	}
	// A missing model or engine is what an install fixes: this Mac can still run it. Only hardware says no.
	if code, reason := d.voxBlock(); code == config.VoxReasonUnsupported {
		e.Supported, e.ReasonCode, e.Reason = false, code, reason
	}
	return e
}

func (d *Daemon) parakeetModelEntry() modelEntry {
	size, ok := fileSize(d.Cfg.STTModel)
	return modelEntry{
		ID: "parakeet", Kind: "transcribe", Name: "Parakeet TDT 0.6B v3",
		Bytes: size, Installed: ok, Default: true, Supported: true,
	}
}

func (d *Daemon) whisperModelEntry() modelEntry {
	size, ok := fileSize(d.Cfg.STTWhisperModel)
	e := modelEntry{
		ID: "whisper", Kind: "transcribe", Name: "Whisper large-v3-turbo",
		Bytes: size, Installed: ok, Supported: true,
	}
	if !ok {
		e.Bytes = approxWhisperBytes
	}
	return e
}

func (d *Daemon) notesModelEntry() modelEntry {
	size, ok := fileSize(d.Cfg.NotesModel)
	e := modelEntry{
		ID: "notes", Kind: "notes", Name: "Qwen3.5-4B Q4_K_M",
		Bytes: size, Installed: ok, Default: true, Supported: true, Installing: d.notesInstalling() > 0,
	}
	if !ok {
		e.Bytes = config.NotesModelBytes
	}
	// A missing model is what the download fixes; the other blocks (memory, a missing engine, a taken port) are not.
	if code, reason := d.Cfg.NotesBlock(); code != "" && code != config.NotesReasonModelMissing {
		e.Supported, e.ReasonCode, e.Reason = false, code, reason
	}
	return e
}

// notesModelBusy: the notes model is read by a meeting that is queued or running, a meeting still being recorded (its
// notes are made when it ends), and the download writes it.
func (d *Daemon) notesModelBusy() string {
	if d.notesInstalling() > 0 {
		return "The notes model is being downloaded. Try again when it has finished."
	}
	if d.Meet != nil && d.Meet.Active() > 0 {
		return "A meeting is being processed and needs the notes model. Try again when it has finished."
	}
	if d.Meet != nil && d.Meet.Store != nil {
		list, err := d.Meet.Store.List()
		if err != nil {
			d.log.Warn("model removal: cannot read the meetings, refusing", slog.Any("error", err))
			return "The meetings cannot be read right now. Try again in a moment."
		}
		for _, m := range list {
			if m.Status == meeting.StatusRecording {
				return "A meeting is being recorded and its notes need this model. Try again when it has ended."
			}
		}
	}
	return ""
}

func (d *Daemon) modelRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/models", d.handleModelsList)
	mux.HandleFunc("DELETE /v1/models/{id}", d.handleModelDelete)
}

func (d *Daemon) handleModelsList(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"models": d.modelEntries()})
}

// modelError is a refused removal with the status it answers.
type modelError struct {
	status int
	msg    string
}

func (e *modelError) Error() string { return e.msg }

func (d *Daemon) handleModelDelete(w http.ResponseWriter, r *http.Request) {
	err := d.removeModel(r.Context(), r.PathValue("id"))
	var me *modelError
	switch {
	case err == nil:
		w.WriteHeader(http.StatusNoContent)
	case errors.As(err, &me):
		if me.status == http.StatusBadRequest || me.status == http.StatusConflict {
			// id is a known model here: refusals 400/409 happen only after the table lookup.
			d.log.Info("model removal refused", slog.String("model", r.PathValue("id")), slog.Int("status", me.status), slog.String("reason", me.msg))
		}
		writeErr(w, me.status, me.msg)
	default:
		d.log.Warn("model removal failed", slog.String("model", r.PathValue("id")), slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "The model could not be removed. Details are in the ox-say log.")
	}
}

// removeModel deletes one optional model's file. The id only selects a row of modelTable; the path is the row's
// configured one, never built from the request. In order: the file must be the pinned name and a plain file (not the
// user's own, not a link or folder), no lane that reads it may be busy, the resident engine is stopped and the lanes
// are read again (a request that arrived meanwhile keeps the file), then the file is unlinked. A running child keeps
// its open file until it exits, so a delete never pulls a model out from under a request; the sole window left is a
// request admitted between the last check and the unlink, which gets the ordinary "model missing" answer.
func (d *Daemon) removeModel(ctx context.Context, id string) error {
	var def *modelDef
	for i := range modelTable {
		if modelTable[i].id == id {
			def = &modelTable[i]
			break
		}
	}
	if def == nil {
		return &modelError{http.StatusNotFound, "no such model"}
	}
	rm := def.removal
	if rm == nil {
		return &modelError{http.StatusBadRequest, "this model is required and cannot be removed"}
	}
	d.modelMu.Lock()
	defer d.modelMu.Unlock()

	path, size, err := d.checkRemovable(rm)
	if err != nil {
		return err
	}
	if why := rm.busy(d); why != "" {
		return &modelError{http.StatusConflict, why}
	}
	if rm.engine != nil {
		if err := d.stopModelEngine(ctx, rm.engine(d)); err != nil {
			return err
		}
		if why := rm.busy(d); why != "" {
			return &modelError{http.StatusConflict, why}
		}
	}
	if err := os.Remove(path); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return &modelError{http.StatusNotFound, "this model is not installed"}
		}
		return fmt.Errorf("cannot remove the model file: %w", err)
	}
	d.log.Info("model removed", slog.String("model", def.id), slog.Int64("bytes", size))
	return nil
}

// stopModelEngine stops the resident engine whose child has the model open, through the supervisor's own recycle (it
// waits for requests holding a guard and never kills one). An engine that is starting is loading the very file, so the
// removal waits for another try. A supervisor that is nil or not running needs nothing.
func (d *Daemon) stopModelEngine(ctx context.Context, sup *engine.Supervisor) error {
	if sup == nil {
		return nil
	}
	st := sup.Status()
	if st.State == engine.StateStarting {
		return &modelError{http.StatusConflict, "The engine is starting. Try again in a moment."}
	}
	if st.State != engine.StateReady {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, modelStopWait)
	defer cancel()
	if err := sup.Recycle(ctx, st.PID); err != nil {
		// Recycle marks the engine stopped before it kills the child. A deadline after that point is a slow exit, not a
		// busy engine: the child is on its way out and an unlinked file is safe under it.
		if (errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled)) && sup.State() == engine.StateStopped {
			return nil
		}
		if errors.Is(err, engine.ErrRecycleBusy) || errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
			return &modelError{http.StatusConflict, "The engine is still working. Try again when it has finished."}
		}
		return fmt.Errorf("cannot stop the engine: %w", err)
	}
	return nil
}

// checkRemovable is the one rule for "this model's file may be deleted by ox-say", shared by GET (removable) and
// removeModel so the two cannot disagree: the configured path is absolute and has the pinned name, sits in
// <home>/models, and is a plain file that exists (not a link or a folder). It returns the path and size, or a
// *modelError (400 for a file ox-say does not own, 404 when not installed), or a plain error when the file cannot be
// inspected.
func (d *Daemon) checkRemovable(rm *modelRemoval) (path string, size int64, err error) {
	path = rm.file(d)
	if path == "" || !filepath.IsAbs(path) || filepath.Base(path) != rm.pinned {
		return "", 0, &modelError{http.StatusBadRequest, "this model is your own file; remove it yourself"}
	}
	if !d.inModelsDir(path) {
		return "", 0, &modelError{http.StatusBadRequest, "This model is managed outside OxSay; remove it yourself."}
	}
	// Lstat: a link to a model kept elsewhere is not removed and never followed (removing it would leave the data and
	// report the model gone); a folder is not a model file.
	st, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return "", 0, &modelError{http.StatusNotFound, "this model is not installed"}
	}
	if err != nil {
		return "", 0, fmt.Errorf("cannot inspect the model file: %w", err)
	}
	if !st.Mode().IsRegular() {
		return "", 0, &modelError{http.StatusBadRequest, "this model is a link or a folder, not a file ox-say downloaded; remove it yourself"}
	}
	return path, st.Size(), nil
}

// inModelsDir reports whether path sits directly in <home>/models, comparing the folders after resolving symlinks so a
// models folder kept on another disk through a link still counts. A model an env override points elsewhere is managed
// outside OxSay and is never deleted by it.
func (d *Daemon) inModelsDir(path string) bool {
	if path == "" || !filepath.IsAbs(path) {
		return false
	}
	resolve := func(p string) string {
		if r, err := filepath.EvalSymlinks(p); err == nil {
			return r
		}
		return filepath.Clean(p)
	}
	return resolve(filepath.Dir(path)) == resolve(filepath.Join(d.Cfg.Home, "models"))
}
