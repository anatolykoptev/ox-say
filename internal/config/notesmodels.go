package config

import (
	"fmt"
	"path/filepath"
)

// The notes-model catalog: the one place that names the files the daemon can
// download for meeting notes. Kind drives behaviour, not order: standard and
// compact are the automatic choices (in this order); uncensored is offered
// only where it fits and is never picked automatically. custom is not a row —
// it is the user's own file, which ox-say never downloads and never deletes.
type NotesModelEntry struct {
	ID          string // catalog id, as PUT /v1/meetings/notes-model takes it
	Kind        string // standard | compact | uncensored
	Name        string // shown in the app's model list
	File        string // file name inside <home>/models
	Bytes       int64  // pinned download size (progress and disk check)
	SHA256      string // integrity pin fetch-models.sh verifies
	URL         string // https://huggingface.co/<repo>/resolve/<rev> the file is fetched from
	MinMemoryGB int    // the smallest Mac this model is offered on
}

const (
	NotesKindStandard   = "standard"
	NotesKindCompact    = "compact"
	NotesKindUncensored = "uncensored"
	// NotesCustomID is the resolved id of a model that is not in the catalog:
	// the user's own GGUF (OX_SAY_NOTES_MODEL or a saved {"path"} choice).
	NotesCustomID = "custom"
)

// NotesCatalog is ordered for the automatic choice: the standard model first,
// the compact one as its lighter fallback. The uncensored entry is offered to
// a user who asks for it, never picked on its own.
var NotesCatalog = []NotesModelEntry{
	{
		ID: "qwen3.5-9b", Kind: NotesKindStandard, Name: "Qwen3.5-9B Q4_K_M",
		File: "Qwen3.5-9B-Q4_K_M.gguf", Bytes: 5680522464,
		SHA256: "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8",
		URL:    "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/3885219b6810b007914f3a7950a8d1b469d598a5",
		// Provisional: the 9B is gated until it is measured below 24 GB.
		MinMemoryGB: 16,
	},
	{
		ID: "qwen3.5-4b", Kind: NotesKindCompact, Name: "Qwen3.5-4B Q4_K_M",
		File: NotesModelFile, Bytes: NotesModelBytes,
		SHA256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
		URL:    "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523",
		// NotesMinMemoryGB: the smallest Mac any catalog model is offered on.
		MinMemoryGB: NotesMinMemoryGB,
	},
	{
		ID: "qwen3.8-27b-uncensored", Kind: NotesKindUncensored, Name: "Qwen3.8-27B abliterated UD Q5_K_XL",
		File: "Huihui-Qwen3.8-27B-abliterated-UD-Q5_K_XL.gguf", Bytes: 20673612704,
		SHA256:      "a6ff520853eba5cad302a2a16144b7fe683792cca7fb2830a08479e78ebe12b6",
		URL:         "https://huggingface.co/huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF/resolve/1c69098e9c32db6dc06fc48f1d6cc75ad07da89e",
		MinMemoryGB: 32,
	},
}

// NotesExclusiveBytes is the size above which a notes model is a large
// exclusive engine (see NotesExclusiveBelowGB); below it the notes engine may
// stay resident next to the voices on a big Mac.
const NotesExclusiveBytes = 12 << 30

// NotesExclusiveBelowGB is the Mac size under which a notes model over
// NotesExclusiveBytes takes turns with the other large engines — a wider net
// than OneLargeEngineBelowGB, because a 20 GB model does not share a 32 GB Mac.
const NotesExclusiveBelowGB = 48

// NotesModelEnv records that OX_SAY_NOTES_MODEL (or --notes-model) was given,
// so the resolver can tell an operator's pin from the built-in default even
// when the pin names the default path.

// Sources of the resolved notes model: env (OX_SAY_NOTES_MODEL, fixed by the
// install), saved (the user's stored choice), automatic (the catalog default).
const (
	NotesSourceEnv       = "env"
	NotesSourceSaved     = "saved"
	NotesSourceAutomatic = "automatic"
)

// NotesChoice is the user's stored pick of notes model — the contents of
// $OX_SAY_HOME/notes-model.json: {"id":"<catalog id>"} or {"path":"/abs/x.gguf"}.
// Exactly one of ID and Path is set; a file that holds neither (or an unknown
// id, or a relative path) is treated as no choice by the loader.
type NotesChoice struct {
	ID   string `json:"id,omitempty"`
	Path string `json:"path,omitempty"`
}

// NotesResolveInput is what ResolveNotesModel needs; the caller gathers the
// IO (env, saved file, host memory, installed checks) so the choice itself
// stays pure and table-tested.
type NotesResolveInput struct {
	EnvPath   string            // OX_SAY_NOTES_MODEL, "" when unset
	Choice    *NotesChoice      // nil: no saved choice (absent, unreadable or unknown)
	ModelsDir string            // <home>/models
	HostMem   uint64            // bytes of RAM; 0 = unknown, fits everything
	Catalog   []NotesModelEntry // the rows the choice may name
	Installed func(string) bool // regular-file check on a model path
}

// NotesResolution is the answer: which file the notes engine loads next, why
// that file, and whether it is on disk. Entry is nil for a custom file.
type NotesResolution struct {
	Source    string           // env | saved | automatic
	ID        string           // catalog id, or "custom"
	Path      string           // the file ox-llm's -m names
	Entry     *NotesModelEntry // the catalog row, nil for a custom file
	Installed bool
}

// NotesModelByID finds a catalog entry by id.
func NotesModelByID(catalog []NotesModelEntry, id string) *NotesModelEntry {
	for i := range catalog {
		if catalog[i].ID == id {
			return &catalog[i]
		}
	}
	return nil
}

// notesModelByFile finds a catalog entry by file name (what an env path or a
// saved custom path's base names).
func notesModelByFile(catalog []NotesModelEntry, base string) *NotesModelEntry {
	for i := range catalog {
		if catalog[i].File == base {
			return &catalog[i]
		}
	}
	return nil
}

// notesFits reports whether this Mac's memory runs the entry; an unknown size
// (0) never blocks, the same convention as the other memory gates.
func notesFits(e *NotesModelEntry, hostMem uint64) bool {
	return hostMem == 0 || hostMem >= uint64(e.MinMemoryGB)*bytesPerGB
}

// automaticEntry picks the model an install with no id downloads and a
// resolution with nothing installed reports: the first catalog entry of the
// automatic kinds (standard, then compact) that fits this Mac, or the compact
// entry when nothing fits (the lightest file, for a sensible -m and size).
func automaticEntry(catalog []NotesModelEntry, hostMem uint64) *NotesModelEntry {
	var compact *NotesModelEntry
	for i := range catalog {
		e := &catalog[i]
		if e.Kind == NotesKindCompact {
			compact = e
		}
		if e.Kind == NotesKindUncensored {
			continue // offered only where it fits and asked for, never automatic
		}
		if notesFits(e, hostMem) {
			return e
		}
	}
	return compact
}

// ResolveNotesModel is the one place the notes model file is chosen, in order:
//
//  1. OX_SAY_NOTES_MODEL set (an operator's pin, written by the installer):
//     it wins over a saved choice. Its base name matching a catalog file is
//     that entry; anything else is a custom file.
//  2. A saved choice: a catalog id resolves to <models dir>/<its file>; a
//     custom path resolves to the path itself.
//  3. Automatic: the first of the automatic entries (9B, then 4B) that fits
//     this Mac's memory AND is installed; when none is installed, the first
//     that fits — so a Mac that only ever downloaded the 4B keeps running it
//     while the 9B is the reported default.
//
// It runs per notes-engine start and per status read: a model deleted or
// fetched between calls is picked up without a restart.
func ResolveNotesModel(in NotesResolveInput) NotesResolution {
	if in.EnvPath != "" {
		out := NotesResolution{Source: NotesSourceEnv, Path: in.EnvPath}
		if e := notesModelByFile(in.Catalog, filepath.Base(in.EnvPath)); e != nil {
			out.ID, out.Entry = e.ID, e
		} else {
			out.ID = NotesCustomID
		}
		out.Installed = in.Installed(in.EnvPath)
		return out
	}
	if in.Choice != nil {
		out := NotesResolution{Source: NotesSourceSaved}
		switch {
		case in.Choice.Path != "":
			out.ID, out.Path = NotesCustomID, in.Choice.Path
		default:
			if e := NotesModelByID(in.Catalog, in.Choice.ID); e != nil {
				out.ID, out.Entry = e.ID, e
				out.Path = filepath.Join(in.ModelsDir, e.File)
			}
		}
		if out.ID != "" {
			out.Installed = in.Installed(out.Path)
			return out
		}
		// A choice the loader should never have passed (unknown id): fall
		// through to automatic rather than resolving nothing.
	}
	out := NotesResolution{Source: NotesSourceAutomatic}
	// The first fitting model that is already here wins; only when none is
	// installed does the reported model become the first fitting download.
	var firstFit *NotesModelEntry
	for i := range in.Catalog {
		e := &in.Catalog[i]
		if e.Kind == NotesKindUncensored || !notesFits(e, in.HostMem) {
			continue
		}
		if firstFit == nil {
			firstFit = e
		}
		path := filepath.Join(in.ModelsDir, e.File)
		if in.Installed(path) {
			out.ID, out.Entry, out.Path, out.Installed = e.ID, e, path, true
			return out
		}
	}
	if firstFit == nil {
		firstFit = automaticEntry(in.Catalog, in.HostMem)
	}
	if firstFit != nil {
		out.ID, out.Entry = firstFit.ID, firstFit
		out.Path = filepath.Join(in.ModelsDir, firstFit.File)
		out.Installed = in.Installed(out.Path)
	}
	return out
}

// MissingText is the model_missing sentence for this resolution: the catalog
// names its own size; a custom file that is not there gets no download size.
func (r NotesResolution) MissingText() string {
	if r.Entry != nil {
		return fmt.Sprintf("The notes model is not downloaded yet (about %.1f GB).", float64(r.Entry.Bytes)/1e9)
	}
	return "The notes model file the notes engine is configured to use is not there."
}

// ModelsDir is <home>/models, where ox-say's downloads live.
func (c *Config) ModelsDir() string { return filepath.Join(c.Home, "models") }

// NotesEnvPath is the path OX_SAY_NOTES_MODEL (or --notes-model) names, or ""
// when the operator set nothing. A Config literal that points NotesModel at a
// file other than the built-in default counts as an env path — that is the
// value load itself stores.
func (c *Config) NotesEnvPath() string {
	switch {
	case c.NotesModelEnv:
		return c.NotesModel
	case c.NotesModel == "", c.NotesModel == filepath.Join(c.Home, "models", NotesModelFile):
		return ""
	default:
		return c.NotesModel
	}
}

// ResolveNotes resolves the notes model this daemon would load now, against
// the real catalog, this Mac's memory and the stored choice the caller read.
func (c *Config) ResolveNotes(choice *NotesChoice, installed func(string) bool) NotesResolution {
	return ResolveNotesModel(NotesResolveInput{
		EnvPath:   c.NotesEnvPath(),
		Choice:    choice,
		ModelsDir: c.ModelsDir(),
		HostMem:   c.HostMemoryBytes,
		Catalog:   NotesCatalog,
		Installed: installed,
	})
}

// NotesAutomaticDefault is the model an install with no id downloads and a
// missing-everything resolution reports: the first automatic entry this Mac
// can run.
func (c *Config) NotesAutomaticDefault() *NotesModelEntry {
	return automaticEntry(NotesCatalog, c.HostMemoryBytes)
}
