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
	// Selected marks the notes row that is the effective model: true on the
	// resolved catalog row or notes:custom, mirrored by the "notes" row that
	// always names it. Absent (false) everywhere else.
	Selected   bool   `json:"selected,omitempty"`
	ReasonCode string `json:"reason_code,omitempty"`
	Reason     string `json:"reason,omitempty"`
	// Upstream is the uncensored notes model's "is the file still on its
	// host" (available | gone | unknown) while it is not installed; omitted
	// everywhere else.
	Upstream string `json:"upstream,omitempty"`
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
	// pinnedFor, when set, supplies the pinned name per call (the "notes" row's
	// pinned name is the resolved model's catalog file); "" answers never
	// removable, the user's own file.
	pinnedFor func(d *Daemon) string
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
	{id: cleanModelID, entry: (*Daemon).cleanModelEntry},
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
}

// notesModelDefs builds the notes rows per call — the resolved model's own
// "notes" (the id the app has always used), one "notes:<id>" row per catalog
// file, and "notes:custom" when the notes model is the user's own file (never
// deletable). Static defs cannot hold them: which file "notes" names depends
// on the resolution.
func (d *Daemon) notesModelDefs() []modelDef {
	defs := []modelDef{{id: "notes", entry: (*Daemon).notesModelEntry, removal: &modelRemoval{
		file: func(d *Daemon) string { return d.notesResolve().Path },
		pinnedFor: func(d *Daemon) string {
			if e := d.notesResolve().Entry; e != nil {
				return e.File
			}
			return ""
		},
		busy:   (*Daemon).notesModelBusy,
		engine: func(d *Daemon) *engine.Supervisor { return d.LLMSup },
	}}}
	for i := range config.NotesCatalog {
		e := &config.NotesCatalog[i]
		defs = append(defs, modelDef{
			id:    "notes:" + e.ID,
			entry: func(d *Daemon) modelEntry { return d.notesCatalogEntry(e) },
			removal: &modelRemoval{
				file:   func(d *Daemon) string { return filepath.Join(d.Cfg.ModelsDir(), e.File) },
				pinned: e.File,
				busy:   (*Daemon).notesModelBusy,
				engine: func(d *Daemon) *engine.Supervisor {
					if res := d.notesResolve(); res.Entry != nil && res.Entry.ID == e.ID {
						return d.LLMSup
					}
					return nil
				},
			},
		})
	}
	if d.notesResolve().Entry == nil {
		defs = append(defs, modelDef{id: "notes:custom", entry: (*Daemon).notesCustomEntry})
	}
	return defs
}

// modelEntries builds every row. Each model stats its one or two files and nothing else: no directory is walked, so the
// call costs the same on a 3 GB model as on an empty one.
func (d *Daemon) modelEntries() []modelEntry {
	defs := make([]modelDef, 0, len(modelTable)+len(config.NotesCatalog)+2)
	defs = append(defs, modelTable...)
	defs = append(defs, d.notesModelDefs()...)
	out := make([]modelEntry, 0, len(defs))
	for _, def := range defs {
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

// cleanModelID is the voice-cleanup model's row. It is required by the feature, not optional: nothing deletes it
// through the API (a reinstall replaces it), and the first cleanup downloads it.
const cleanModelID = "voice_cleanup"

func (d *Daemon) cleanModelEntry() modelEntry {
	code, reason := d.cleanReady()
	e := modelEntry{
		ID: cleanModelID, Kind: "cleanup", Name: "MossFormer2 SE 48K (Core ML)",
		Bytes: config.CleanModelsBytes, Installed: d.Cfg.CleanModelsReady(), Supported: true,
		Installing: d.cleanInstalling() > 0, ReasonCode: code, Reason: reason,
	}
	// A missing model is what the first cleanup downloads; an old macOS or a missing engine is what it cannot fix.
	if code != "" && code != CleanModelsMissing {
		e.Supported = false
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

// sttModelBytes is the resident STT server's model footprint for the
// memory gate: the recognizer file — the parakeet row's measure — plus
// the VAD model where one is on disk, since the server's argv loads it
// whenever it stats (STTServeArgs).
func (d *Daemon) sttModelBytes() int64 {
	n, _ := fileSize(d.Cfg.STTModel)
	if vad, ok := fileSize(d.Cfg.STTVADModel); ok {
		n += vad
	}
	return n
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

// notesModelEntry is the "notes" row: the resolved model — what notes runs on
// — under the id the app has always used. Its name and size are the catalog
// entry's, or the user's own file's.
func (d *Daemon) notesModelEntry() modelEntry {
	res := d.notesResolve()
	size, ok := fileSize(res.Path)
	name, bytes := "your own model", size
	if res.Entry != nil {
		name = res.Entry.Name
		if !ok {
			bytes = res.Entry.Bytes
		}
	}
	e := modelEntry{
		ID: "notes", Kind: "notes", Name: name,
		Bytes: bytes, Installed: ok,
		Default:   res.Entry != nil && res.Entry.ID == d.Cfg.NotesAutomaticDefault().ID,
		Supported: true, Installing: d.notesInstalling() > 0,
		Selected: true, // the notes row always names the effective model
	}
	// A missing model is what the download fixes; the other blocks (memory, a missing engine, a taken port) are not.
	if code, reason := d.Cfg.NotesBlock(res); code != "" && code != config.NotesReasonModelMissing {
		e.Supported, e.ReasonCode, e.Reason = false, code, reason
	}
	return e
}

// notesCatalogEntry is a "notes:<id>" row: one catalog file, whether or not
// it is the resolved one.
func (d *Daemon) notesCatalogEntry(entry *config.NotesModelEntry) modelEntry {
	path := filepath.Join(d.Cfg.ModelsDir(), entry.File)
	size, ok := fileSize(path)
	res := d.notesResolve()
	e := modelEntry{
		ID: "notes:" + entry.ID, Kind: "notes", Name: entry.Name,
		Bytes: size, Installed: ok,
		Default:   entry.ID == d.Cfg.NotesAutomaticDefault().ID,
		Supported: true,
		Selected:  res.Entry != nil && res.Entry.ID == entry.ID,
		Upstream:  d.notesUpstream(entry, ok),
	}
	if !ok {
		e.Bytes = entry.Bytes
	}
	if file, _, _ := d.notes.target(); file == path && d.notesInstalling() > 0 {
		e.Installing = true
	}
	// Only the memory floor makes a catalog model unsupportable; a missing
	// file or engine is what an install fixes.
	if d.Cfg.HostMemoryBytes != 0 && d.Cfg.HostMemoryBytes < uint64(entry.MinMemoryGB)<<30 {
		e.Supported, e.ReasonCode = false, config.NotesReasonUnsupported
		e.Reason = fmt.Sprintf("%s needs at least %d GB of memory; this Mac has %d GB.",
			entry.Name, entry.MinMemoryGB, d.Cfg.HostMemoryBytes>>30)
	}
	return e
}

// notesCustomEntry is the "notes:custom" row, present while the notes model
// is the user's own file. It is display only — ox-say never deletes it (no
// removal), so it is not optional.
func (d *Daemon) notesCustomEntry() modelEntry {
	res := d.notesResolve()
	size, ok := fileSize(res.Path)
	return modelEntry{
		ID: "notes:custom", Kind: "notes", Name: filepath.Base(res.Path),
		Bytes: size, Installed: ok, Supported: true,
		Selected: res.Entry == nil, // the row exists only while the custom file resolves
	}
}

// notesModelBusy: the notes model is read by a meeting that is queued or running, a meeting still being recorded (its
// notes are made when it ends), and the download writes it.
func (d *Daemon) notesModelBusy() string {
	active := 0
	if d.Meet != nil {
		active = d.Meet.Active()
	}
	return d.notesModelBusyAt(active)
}

// notesModelBusyAt is notesModelBusy for a caller holding the queue's
// admission lock: the pending count is handed over so the answer cannot move
// under the caller (the notes-model switch checks and acts as one step).
func (d *Daemon) notesModelBusyAt(active int) string {
	if d.notesInstalling() > 0 {
		return "The notes model is being downloaded. Try again when it has finished."
	}
	if active > 0 {
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
	defs := make([]modelDef, 0, len(modelTable)+len(config.NotesCatalog)+2)
	defs = append(defs, modelTable...)
	defs = append(defs, d.notesModelDefs()...)
	var def *modelDef
	for i := range defs {
		if defs[i].id == id {
			def = &defs[i]
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
	pinned := rm.pinned
	if rm.pinnedFor != nil {
		pinned = rm.pinnedFor(d)
	}
	if path == "" || !filepath.IsAbs(path) || pinned == "" || filepath.Base(path) != pinned {
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
