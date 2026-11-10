package daemon

// The notes model's catalog, saved choice and switching. The catalog itself
// lives in internal/config (NotesCatalog); this file owns the pieces the
// daemon adds: the choice file at $OX_SAY_HOME/notes-model.json, the
// resolution that runs per engine start and per status read, the
// GET/PUT /v1/meetings/notes-model routes, and the per-catalog rows of
// /v1/models.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// notesChoiceFile is the saved notes-model choice, written by PUT
// /v1/meetings/notes-model: {"id":"<catalog id>"} or {"path":"/abs/x.gguf"}.
const notesChoiceFile = "notes-model.json"

// notesInstalled is the resolver's "is the file there": a regular file, like
// the model check every other gate makes.
func notesInstalled(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.Mode().IsRegular()
}

// readNotesChoice loads the saved choice. Absent, unreadable, malformed JSON,
// an unknown catalog id and a relative custom path all read as "no choice":
// the file is user-editable and a bad one must not take notes down.
func readNotesChoice(home string) *config.NotesChoice {
	raw, err := os.ReadFile(filepath.Join(home, notesChoiceFile))
	if err != nil {
		return nil
	}
	var ch config.NotesChoice
	if err := json.Unmarshal(raw, &ch); err != nil {
		return nil
	}
	switch {
	case ch.Path != "":
		if filepath.IsAbs(ch.Path) {
			return &config.NotesChoice{Path: ch.Path}
		}
	case ch.ID != "":
		if config.NotesModelByID(config.NotesCatalog, ch.ID) != nil {
			return &config.NotesChoice{ID: ch.ID}
		}
	}
	return nil
}

// writeNotesChoice stores the choice atomically, 0600 (a meeting's model pick
// is as private as the meeting): vproject.WriteAtomic stages a unique temp
// file, fsyncs it, renames it into place and fsyncs the directory — two
// concurrent writers never share one temp inode the way a fixed .tmp name
// made them.
func writeNotesChoice(home string, ch config.NotesChoice) (err error) {
	var buf bytes.Buffer
	if ch.Path != "" {
		err = json.NewEncoder(&buf).Encode(struct {
			Path string `json:"path"`
		}{Path: ch.Path})
	} else {
		err = json.NewEncoder(&buf).Encode(struct {
			ID string `json:"id"`
		}{ID: ch.ID})
	}
	if err != nil {
		return err
	}
	return vproject.WriteAtomic(filepath.Join(home, notesChoiceFile), buf.Bytes(), 0o600)
}

// notesResolve is the daemon's one call for "which notes model now": env pin,
// saved choice or the automatic pick of what is installed and fits.
func (d *Daemon) notesResolve() config.NotesResolution {
	return d.Cfg.ResolveNotes(readNotesChoice(d.Cfg.Home), notesInstalled)
}

// notesBlock is NotesBlock over the live resolution.
func (d *Daemon) notesBlock() (code, reason string) {
	return d.Cfg.NotesBlock(d.notesResolve())
}

// notesModelPath is the -m for this spawn: resolved per start, so a model the
// user switched to is the file the next child loads without a daemon restart.
func notesModelPath(cfg *config.Config) string {
	if res := cfg.ResolveNotes(readNotesChoice(cfg.Home), notesInstalled); res.Path != "" {
		return res.Path
	}
	return cfg.NotesModel
}

// notesCouldBeExclusive is the static half of notesExclusive: this Mac shares
// memory between the GPU engines (unified memory — a discrete card runs notes
// on the CPU and never takes turns) and is under config.NotesExclusiveBelowGB
// or of unknown size, so a large enough notes model could be exclusive here.
func (d *Daemon) notesCouldBeExclusive() bool {
	if !d.Cfg.UnifiedMemory() {
		return false
	}
	mem := d.Cfg.HostMemoryBytes
	if d.Cfg.AssumedMemoryBytes != 0 {
		mem = d.Cfg.AssumedMemoryBytes
	}
	return mem == 0 || mem < config.NotesExclusiveBelowGB*(1<<30)
}

// notesExclusive reports whether the resolved notes model is a large engine
// on this Mac: over config.NotesExclusiveBytes where notesCouldBeExclusive
// holds. The catalog pins the size; the user's own model is measured on disk.
func (d *Daemon) notesExclusive() bool {
	if !d.notesCouldBeExclusive() {
		return false
	}
	res := d.notesResolve()
	size := int64(0)
	switch {
	case res.Entry != nil:
		size = res.Entry.Bytes
	case res.Installed:
		size, _ = fileSize(res.Path) // the user's own model: its real size
	}
	return size > config.NotesExclusiveBytes
}

// --- GET/PUT /v1/meetings/notes-model ---------------------------------------

// notesModelGet is the answer of GET /v1/meetings/notes-model: the effective
// selection, where it came from, and every catalog row the PUT accepts.
type notesModelGet struct {
	Model     string             `json:"model"`  // resolved catalog id, or "custom"
	Source    string             `json:"source"` // env | saved | automatic
	Path      string             `json:"path"`   // the file the next start loads
	Installed bool               `json:"installed"`
	Choices   []notesModelChoice `json:"choices"`
}

// notesModelChoice is one selectable model in the GET answer.
type notesModelChoice struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	Bytes     int64  `json:"bytes"`
	Installed bool   `json:"installed"`
	Supported bool   `json:"supported"` // this Mac's memory runs it
}

func (d *Daemon) notesModelChoices() []notesModelChoice {
	out := make([]notesModelChoice, 0, len(config.NotesCatalog))
	for i := range config.NotesCatalog {
		e := &config.NotesCatalog[i]
		_, installed := fileSize(filepath.Join(d.Cfg.ModelsDir(), e.File))
		out = append(out, notesModelChoice{
			ID: e.ID, Name: e.Name, Kind: e.Kind, Bytes: e.Bytes,
			Installed: installed,
			Supported: d.Cfg.HostMemoryBytes == 0 || d.Cfg.HostMemoryBytes >= uint64(e.MinMemoryGB)<<30,
		})
	}
	return out
}

func (d *Daemon) handleNotesModelGet(w http.ResponseWriter, _ *http.Request) {
	res := d.notesResolve()
	writeJSON(w, http.StatusOK, notesModelGet{
		Model: res.ID, Source: res.Source, Path: res.Path,
		Installed: res.Installed, Choices: d.notesModelChoices(),
	})
}

// notesModelTrialLoad is where N1b's trial load plugs in: a check that opens
// the model the way the engine would, beyond the static gates of
// notesModelPathError. nil: the static checks are the whole validation.
var notesModelTrialLoad func(path string) string

// notesModelPathError is the PUT's gate for the user's own model file, run
// before the choice is saved: the path must be a canonical absolute path
// (no . or .. segments, no doubled separators) naming a regular file after
// links are followed — non-empty, a .gguf by name and a GGUF by magic — so
// a saved choice cannot send the engine at a folder, a missing file or
// something that is not a model at all. The returned sentence is the 400's
// reason; "" accepts.
func notesModelPathError(path string) string {
	switch {
	case !filepath.IsAbs(path):
		return "The model path must be absolute."
	case filepath.Clean(path) != path:
		return "The model path must not contain . or .. segments or doubled separators."
	}
	st, err := os.Stat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return "There is no file at the model path."
	case err != nil:
		return "The model path cannot be read."
	case !st.Mode().IsRegular():
		return "The model path is a folder or a device, not a model file."
	case !strings.EqualFold(filepath.Ext(path), ".gguf"):
		return "The model file must be a .gguf."
	case st.Size() == 0:
		return "The model file is empty."
	}
	f, err := os.Open(path)
	if err != nil {
		return "The model file cannot be read."
	}
	defer f.Close()
	var magic [4]byte
	if _, err := io.ReadFull(f, magic[:]); err != nil || string(magic[:]) != "GGUF" {
		return "The model file is not a GGUF model."
	}
	if notesModelTrialLoad != nil {
		return notesModelTrialLoad(path)
	}
	return ""
}

// notesModelSwitchProbe, when set, runs inside the model switch's critical
// section — after the busy check, before the stop and the write — so a test
// can hold the section open while a job tries to be admitted. nil in
// production; only tests set it.
var notesModelSwitchProbe func()

// notesModelSwitch is the PUT's critical section: the model mutex serializes
// every switch — also on a daemon with no meeting queue, and against the
// model removals that run the same busy-check-then-engine-stop shape under
// it — and the meeting queue's admission lock makes the busy check, the
// engine stop and the saved choice one step against job admission: a meeting
// cannot slip between the check and the stop and leave the old child serving
// a changed choice. The stop comes before the write, so a refused stop
// leaves the file — and the resolved model — exactly as they were.
func (d *Daemon) notesModelSwitch(ctx context.Context, ch config.NotesChoice) error {
	d.modelMu.Lock()
	defer d.modelMu.Unlock()
	body := func(active int) error {
		if why := d.notesModelBusyAt(active); why != "" {
			return &modelError{http.StatusConflict, why}
		}
		if notesModelSwitchProbe != nil {
			notesModelSwitchProbe()
		}
		// The resolved file changed: stop the child so its next start loads it.
		if err := d.stopModelEngine(ctx, d.LLMSup); err != nil {
			return err
		}
		if err := writeNotesChoice(d.Cfg.Home, ch); err != nil {
			d.log.Warn("notes model choice could not be saved", "error", err)
			return &modelError{http.StatusInternalServerError, "The choice could not be saved. Details are in the ox-say log."}
		}
		return nil
	}
	if d.Meet == nil {
		return body(0)
	}
	return d.Meet.WithAdmissionLock(body)
}

// handleNotesModelPut saves the user's choice. While the notes model is busy
// — a meeting queued or running, one still recording, a download in flight —
// it answers 409 and changes nothing; the busy check, the engine stop and
// the save are one step under the queue's admission lock, so nothing slips
// between them. While idle the child is stopped and the choice file written:
// the next start resolves the new path. The choice is validated first: an
// unknown catalog id, a model this Mac cannot run, "custom" without a file,
// or a path that does not name a real .gguf all fail 400.
func (d *Daemon) handleNotesModelPut(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ID   string `json:"id"`
		Path string `json:"path"`
	}
	if err := decodeStrict(r, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "The request body must be a JSON object like {\"id\":\"qwen3.5-9b\"}.")
		return
	}
	var ch config.NotesChoice
	switch {
	case req.Path != "":
		if why := notesModelPathError(req.Path); why != "" {
			writeErr(w, http.StatusBadRequest, why)
			return
		}
		ch = config.NotesChoice{Path: req.Path}
	case req.ID != "" && req.ID != config.NotesCustomID:
		e := config.NotesModelByID(config.NotesCatalog, req.ID)
		if e == nil {
			writeErr(w, http.StatusBadRequest, fmt.Sprintf("Unknown notes model %q.", req.ID))
			return
		}
		// Refuse what this Mac cannot run before anything is saved — the same
		// verdict (and sentence) /status gives through NotesBlock.
		if code, reason := d.Cfg.NotesBlock(config.NotesResolution{Entry: e}); code == config.NotesReasonUnsupported {
			writeErr(w, http.StatusBadRequest, reason)
			return
		}
		ch = config.NotesChoice{ID: req.ID}
	default:
		writeErr(w, http.StatusBadRequest, "Name the catalog id of the model, or the absolute path of your own .gguf.")
		return
	}
	if err := d.notesModelSwitch(r.Context(), ch); err != nil {
		var me *modelError
		if errors.As(err, &me) {
			writeErr(w, me.status, me.msg)
		} else {
			d.log.Warn("notes model switch: the engine could not be stopped", "error", err)
			writeErr(w, http.StatusInternalServerError, "The notes engine could not be stopped. Details are in the ox-say log.")
		}
		return
	}
	d.handleNotesModelGet(w, r)
}
