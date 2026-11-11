package config

import (
	"path/filepath"
	"testing"
)

// The notes model resolver: env pin, saved choice, then the automatic pick —
// an installed fitting catalog model first, the catalog default next. These
// are table tests over ResolveNotesModel; the journeys each falsification
// guards are named on their rows.
func TestResolveNotesModel(t *testing.T) {
	dir := "/models"
	have := func(files ...string) func(string) bool {
		set := map[string]bool{}
		for _, f := range files {
			set[f] = true
		}
		return func(p string) bool { return set[p] }
	}
	mem16 := uint64(16) << 30
	for _, tc := range []struct {
		name                       string
		in                         NotesResolveInput
		wantID, wantSrc, wantPath  string
		wantInstalled, wantCatalog bool
	}{
		{
			// The upgrade journey (F1): a Mac that downloaded the 4B and never
			// chose anything keeps notes — the installed fitting model wins
			// over the newer default. Mutation: delete the installed branch of
			// the automatic loop -> the 9B is answered -> RED.
			name:          "the installed 4B keeps notes after the update",
			in:            NotesResolveInput{ModelsDir: dir, HostMem: mem16, Catalog: NotesCatalog, Installed: have(filepath.Join(dir, "Qwen3.5-4B-Q4_K_M.gguf"))},
			wantID:        "qwen3.5-4b",
			wantSrc:       NotesSourceAutomatic,
			wantPath:      filepath.Join(dir, "Qwen3.5-4B-Q4_K_M.gguf"),
			wantInstalled: true, wantCatalog: true,
		},
		{
			name:          "nothing installed on 24 GB: the automatic pick is the 9B, not installed",
			in:            NotesResolveInput{ModelsDir: dir, HostMem: uint64(24) << 30, Catalog: NotesCatalog, Installed: have()},
			wantID:        "qwen3.5-9b",
			wantSrc:       NotesSourceAutomatic,
			wantPath:      filepath.Join(dir, "Qwen3.5-9B-Q4_K_M.gguf"),
			wantInstalled: false, wantCatalog: true,
		},
		{
			// The env pin is the installer's: it outranks a saved choice (F2).
			// Mutation: swap the env/saved order in ResolveNotesModel -> the
			// saved 4B is answered -> RED.
			name: "an env pin wins over a saved choice",
			in: NotesResolveInput{
				EnvPath:   filepath.Join(dir, "Qwen3.5-9B-Q4_K_M.gguf"),
				Choice:    &NotesChoice{ID: "qwen3.5-4b"},
				ModelsDir: dir, HostMem: mem16, Catalog: NotesCatalog,
				Installed: have(filepath.Join(dir, "Qwen3.5-9B-Q4_K_M.gguf"), filepath.Join(dir, "Qwen3.5-4B-Q4_K_M.gguf")),
			},
			wantID:        "qwen3.5-9b",
			wantSrc:       NotesSourceEnv,
			wantPath:      filepath.Join(dir, "Qwen3.5-9B-Q4_K_M.gguf"),
			wantInstalled: true, wantCatalog: true,
		},
		{
			name: "a saved catalog id resolves to its file in the models dir",
			in: NotesResolveInput{
				Choice:    &NotesChoice{ID: "qwen3.5-4b"},
				ModelsDir: dir, HostMem: mem16, Catalog: NotesCatalog,
				Installed: have(filepath.Join(dir, "Qwen3.5-4B-Q4_K_M.gguf")),
			},
			wantID:        "qwen3.5-4b",
			wantSrc:       NotesSourceSaved,
			wantPath:      filepath.Join(dir, "Qwen3.5-4B-Q4_K_M.gguf"),
			wantInstalled: true, wantCatalog: true,
		},
		{
			name: "a saved custom path is the user's own file, catalog nil",
			in: NotesResolveInput{
				Choice:    &NotesChoice{Path: "/home/u/mine.gguf"},
				ModelsDir: dir, HostMem: mem16, Catalog: NotesCatalog,
				Installed: have("/home/u/mine.gguf"),
			},
			wantID:        NotesCustomID,
			wantSrc:       NotesSourceSaved,
			wantPath:      "/home/u/mine.gguf",
			wantInstalled: true, wantCatalog: false,
		},
		{
			name: "an env path the catalog does not know is a custom file",
			in: NotesResolveInput{
				EnvPath:   "/elsewhere/own.gguf",
				ModelsDir: dir, HostMem: mem16, Catalog: NotesCatalog, Installed: have("/elsewhere/own.gguf"),
			},
			wantID:        NotesCustomID,
			wantSrc:       NotesSourceEnv,
			wantPath:      "/elsewhere/own.gguf",
			wantInstalled: true, wantCatalog: false,
		},
		{
			name: "a saved choice for a not-yet-downloaded model resolves to it uninstalled",
			in: NotesResolveInput{
				Choice:    &NotesChoice{ID: "qwen3.5-9b"},
				ModelsDir: dir, HostMem: mem16, Catalog: NotesCatalog, Installed: have(),
			},
			wantID:        "qwen3.5-9b",
			wantSrc:       NotesSourceSaved,
			wantPath:      filepath.Join(dir, "Qwen3.5-9B-Q4_K_M.gguf"),
			wantInstalled: false, wantCatalog: true,
		},
		{
			name: "the uncensored model is never picked automatically",
			in: NotesResolveInput{
				ModelsDir: dir, HostMem: uint64(48) << 30, Catalog: NotesCatalog,
				Installed: have(filepath.Join(dir, "Huihui-Qwen3.8-27B-abliterated-UD-Q5_K_XL.gguf")),
			},
			// Only the 27B is on disk; automatic still names the default 9B —
			// the uncensored file is used only when it is the saved pick.
			wantID:        "qwen3.5-9b",
			wantSrc:       NotesSourceAutomatic,
			wantPath:      filepath.Join(dir, "Qwen3.5-9B-Q4_K_M.gguf"),
			wantInstalled: false, wantCatalog: true,
		},
		{
			name: "a saved pick of the uncensored model resolves to it",
			in: NotesResolveInput{
				Choice:    &NotesChoice{ID: "qwen3.8-27b-uncensored"},
				ModelsDir: dir, HostMem: uint64(48) << 30, Catalog: NotesCatalog,
				Installed: have(filepath.Join(dir, "Huihui-Qwen3.8-27B-abliterated-UD-Q5_K_XL.gguf")),
			},
			wantID:        "qwen3.8-27b-uncensored",
			wantSrc:       NotesSourceSaved,
			wantPath:      filepath.Join(dir, "Huihui-Qwen3.8-27B-abliterated-UD-Q5_K_XL.gguf"),
			wantInstalled: true, wantCatalog: true,
		},
		{
			// Mutation: internal/config/notesmodels.go qwen3.5-9b MinMemoryGB
			// 24 -> 16 -> RED (the 16 GB Mac is answered the 9B).
			name:          "the 9B on a 16 GB Mac is not automatic: memory keeps the 4B",
			in:            NotesResolveInput{ModelsDir: dir, HostMem: mem16, Catalog: NotesCatalog, Installed: have()},
			wantID:        "qwen3.5-4b", // the 9B needs 24 GB: a 16 GB Mac keeps room for the call
			wantSrc:       NotesSourceAutomatic,
			wantPath:      filepath.Join(dir, "Qwen3.5-4B-Q4_K_M.gguf"),
			wantInstalled: false, wantCatalog: true,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := ResolveNotesModel(tc.in)
			if got.ID != tc.wantID || got.Source != tc.wantSrc || got.Path != tc.wantPath || got.Installed != tc.wantInstalled {
				t.Fatalf("resolved = %+v, want id %q source %q path %q installed %v", got, tc.wantID, tc.wantSrc, tc.wantPath, tc.wantInstalled)
			}
			if (got.Entry != nil) != tc.wantCatalog {
				t.Fatalf("Entry = %v, want a catalog row: %v", got.Entry, tc.wantCatalog)
			}
		})
	}
}

// The memory floor decides the automatic pick on a host too small for the
// standard model (F5): with a test catalog whose 9B needs 24 GB a 16 GB Mac
// gets the 4B. Mutation: ignore MinMemoryGB in the resolver (notesFits
// returns true always) -> the 9B is answered -> RED.
func TestResolveNotesModelHonoursTheMemoryFloor(t *testing.T) {
	dir := "/models"
	catalog := []NotesModelEntry{
		{ID: "big", Kind: NotesKindStandard, File: "big.gguf", MinMemoryGB: 24},
		{ID: "small", Kind: NotesKindCompact, File: "small.gguf", MinMemoryGB: 16},
	}
	in := NotesResolveInput{
		ModelsDir: dir, HostMem: 16 << 30, Catalog: catalog,
		Installed: func(string) bool { return false },
	}
	got := ResolveNotesModel(in)
	if got.ID != "small" || got.Entry == nil || got.Path != filepath.Join(dir, "small.gguf") {
		t.Fatalf("16 GB Mac resolved to %+v, want the compact model", got)
	}
	// And nothing fits at all -> the compact entry anyway: the lightest file
	// for a sensible -m and size line.
	in.HostMem = 8 << 30
	got = ResolveNotesModel(in)
	if got.ID != "small" {
		t.Fatalf("8 GB Mac resolved to %q, want the compact fallback", got.ID)
	}
	// Unknown memory blocks nothing (0 = cannot tell).
	in.HostMem = 0
	got = ResolveNotesModel(in)
	if got.ID != "big" {
		t.Fatalf("unknown memory resolved to %q, want the standard model", got.ID)
	}
}

// The saved choice that the loader would never pass (an unknown id) falls
// through to automatic rather than resolving to nothing.
func TestResolveNotesModelDropsAnUnknownSavedID(t *testing.T) {
	got := ResolveNotesModel(NotesResolveInput{
		Choice:    &NotesChoice{ID: "no-such-model"},
		ModelsDir: "/m", HostMem: 0, Catalog: NotesCatalog,
		Installed: func(string) bool { return false },
	})
	if got.Source != NotesSourceAutomatic || got.ID != "qwen3.5-9b" {
		t.Fatalf("an unknown saved id resolved to %+v, want the automatic 9B", got)
	}
}

// NotesEnvPath: the default path and an empty value are "no operator pin";
// anything else is one — including the flag's NotesModelEnv marker for the
// case where the pin happens to name the default file.
func TestNotesEnvPath(t *testing.T) {
	home := t.TempDir()
	def := filepath.Join(home, "models", NotesModelFile)
	for _, tc := range []struct {
		name string
		c    Config
		want string
	}{
		{"unset", Config{Home: home, NotesModel: def}, ""},
		{"empty", Config{Home: home}, ""},
		{"a foreign file", Config{Home: home, NotesModel: "/m/own.gguf"}, "/m/own.gguf"},
		{"the env flag names even the default file", Config{Home: home, NotesModel: def, NotesModelEnv: true}, def},
		{"the 9B path", Config{Home: home, NotesModel: filepath.Join(home, "models", "Qwen3.5-9B-Q4_K_M.gguf")}, filepath.Join(home, "models", "Qwen3.5-9B-Q4_K_M.gguf")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.c.NotesEnvPath(); got != tc.want {
				t.Fatalf("NotesEnvPath = %q, want %q", got, tc.want)
			}
		})
	}
}

// The catalog pins: the 9B is the automatic default, the 4B its compact
// fallback with the unchanged pin, the 27B is opt-in only. A regressed pin is
// what this table is for: the fetch downloads what these rows name.
func TestNotesCatalogPins(t *testing.T) {
	if got := (&Config{}).NotesAutomaticDefault(); got == nil || got.ID != "qwen3.5-9b" {
		t.Fatalf("automatic default = %v, want the 9B", got)
	}
	byID := map[string]NotesModelEntry{}
	for _, e := range NotesCatalog {
		byID[e.ID] = e
	}
	four := byID["qwen3.5-4b"]
	if four.File != NotesModelFile || four.Bytes != NotesModelBytes ||
		four.SHA256 != "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4" ||
		four.URL != "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523" {
		t.Fatalf("the 4B pin changed: %+v", four)
	}
	nine := byID["qwen3.5-9b"]
	if nine.Kind != NotesKindStandard || nine.File != "Qwen3.5-9B-Q4_K_M.gguf" || nine.Bytes != 5680522464 {
		t.Fatalf("the 9B row: %+v", nine)
	}
	unc := byID["qwen3.8-27b-uncensored"]
	if unc.Kind != NotesKindUncensored || unc.MinMemoryGB != 32 || unc.Bytes != 20673612704 {
		t.Fatalf("the uncensored row: %+v", unc)
	}
}
