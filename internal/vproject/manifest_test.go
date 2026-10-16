package vproject

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The committed golden file is the GUI contract: a shape change must show up
// in review. Regenerate only on purpose: UPDATE_GOLDEN=1 go test ./internal/vproject.
// Mutation: rename any json tag in manifest.go -> RED.
func TestManifestGolden(t *testing.T) {
	at := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	m := &Manifest{Version: Version, ID: "20261015-120000-a1b2c3", Title: "Утренний рилс", Created: at, Updated: at,
		Status: StatusReview, Settings: Settings{Voice: "nar", Style: "calm", Preset: "reels", CloneMode: "reference",
			Seed: 42, Cfg: 2, Steps: 10, Takes: 2, LUFS: -14, ChunkPause: 0.2, ParagraphPause: 0.45,
			OutPath: "/Users/x/Movies/ox-say/reel/reel.wav", VoiceSHA: "aa", Engine: "eng1"},
		Progress: Progress{ChunksTotal: 2, ChunksDone: 2, Renders: 5, ElapsedS: 61.5},
		Chunks: []Chunk{{Index: 0, Paragraph: 0, Text: "Привет.", Spoken: "Привет.", PauseAfter: 0.45, Status: ChunkOK,
			Basis: "0123456789abcdef01234567", Pick: "89abcdef0123456789abcdef",
			Takes: []TakeRef{{Key: "89abcdef0123456789abcdef", Seed: 42, DurationS: 1.2, Passed: true}}, StartS: 0, EndS: 1.1}},
		Outputs: Outputs{WAV: "/Users/x/Movies/ox-say/reel/reel.wav", DurationS: 3.1},
		Notes:   []string{NoteNumbers}}
	got, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join("testdata", "manifest.v1.json")
	if os.Getenv("UPDATE_GOLDEN") == "1" {
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatalf("manifest v1 shape changed:\n%s", got)
	}
}

// D6: a v1 manifest written before Chunk.Superseded existed loads and
// re-marshals to the same bytes; the additive field is not a new version.
func TestV1ManifestWithoutSupersededRoundTrips(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "manifest.v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ManifestFile), raw, FileMode); err != nil {
		t.Fatal(err)
	}
	m, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if m.Version != 1 || len(m.Chunks) != 1 || m.Chunks[0].Superseded != nil {
		t.Fatalf("loaded: version %d chunks %+v", m.Version, m.Chunks)
	}
	got, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(raw) {
		t.Fatalf("a v1 manifest changed shape on load:\n%s", got)
	}
}

// A failed write never replaces a good manifest; temp files are swept.
// Mutation: os.WriteFile(manifest.json) in Save -> a torn file -> RED.
func TestSaveIsAtomicAndSweep(t *testing.T) {
	dir := t.TempDir()
	m := &Manifest{Version: Version, ID: "20261015-120000-a1b2c3", Status: StatusDone}
	if err := m.Save(dir); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	m.Status = StatusFailed
	if err := m.Save(dir); err == nil {
		t.Fatal("save into a read-only dir succeeded")
	}
	_ = os.Chmod(dir, 0o700)
	got, err := Load(dir)
	if err != nil || got.Status != StatusDone {
		t.Fatalf("%v %+v", err, got)
	}
	_ = os.WriteFile(filepath.Join(dir, ".manifest.json"+TempMark+"123"), []byte("x"), 0o600)
	if n := SweepTemp(dir); n != 1 {
		t.Fatalf("swept %d", n)
	}
}

// Ids and keys from disk or a URL are validated; containment refuses escapes.
func TestIDsKeysContainment(t *testing.T) {
	if !ValidID(NewID(time.Now())) || ValidID("../etc") || ValidID("20261015-120000-zzzzzz") {
		t.Fatal("ValidID")
	}
	root := t.TempDir()
	proj := filepath.Join(root, "20261015-120000-a1b2c3")
	if err := os.Mkdir(proj, DirMode); err != nil {
		t.Fatal(err)
	}
	if err := Contained(root, proj); err != nil {
		t.Fatal(err)
	}
	if err := Contained(root, filepath.Join(root, "..", "x")); err == nil {
		t.Fatal("escape accepted")
	}
	link := filepath.Join(root, "20261015-120000-ffffff")
	_ = os.Symlink(t.TempDir(), link)
	if err := Contained(root, link); err == nil {
		t.Fatal("symlinked project accepted")
	}
	m := &Manifest{Version: Version, Chunks: []Chunk{{Pick: "../../x"}}}
	if err := m.validate(); err == nil {
		t.Fatal("bad pick key accepted")
	}
}

// Containment is about the path's shape, not its spelling: every way out of
// the root, or down below it, is refused; a real directory whose name merely
// starts with two dots is not an escape.
// Mutation: manifest.go Contained, drop the ".." test -> RED.
// Mutation: manifest.go Contained, os.Lstat -> os.Stat (follows the link) -> RED.
func TestContainedRefusesEveryEscape(t *testing.T) {
	base := t.TempDir()
	root := filepath.Join(base, "produce")
	if err := os.Mkdir(root, DirMode); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(base, "elsewhere")
	for _, d := range []string{outside, filepath.Join(root, "nested", "deep"), filepath.Join(root, "..dots")} {
		if err := os.MkdirAll(d, DirMode); err != nil {
			t.Fatal(err)
		}
	}
	file := filepath.Join(root, "20261015-120000-aaaaaa")
	if err := os.WriteFile(file, []byte("x"), FileMode); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "20261015-120000-bbbbbb")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	refused := map[string]string{
		"parent":              base,
		"sibling via ..":      filepath.Join(root, "..", "elsewhere"),
		"raw dotdot":          root + "/20261015-120000-cccccc/../../elsewhere",
		"the root itself":     root,
		"nested":              filepath.Join(root, "nested", "deep"),
		"a file":              file,
		"a symlink":           link,
		"a missing directory": filepath.Join(root, "20261015-120000-dddddd"),
		"an absolute outside": outside,
	}
	for name, dir := range refused {
		if err := Contained(root, dir); err == nil {
			t.Errorf("%s: %s accepted", name, dir)
		}
	}
	if err := Contained(root, filepath.Join(root, "..dots")); err != nil {
		t.Errorf("a directory named ..dots is inside the root: %v", err)
	}
}

// The status view and a clone share nothing with the manifest they came from,
// and a client sees [] rather than null for an empty list.
// Mutation: manifest.go Clone, return m -> RED.
// Mutation: manifest.go Summary, Notes: m.Notes -> RED.
func TestSummaryAndCloneAreIndependent(t *testing.T) {
	m := &Manifest{Version: Version, Notes: []string{"n"}, Chunks: []Chunk{{Reasons: []string{"r"}, Takes: []TakeRef{{Key: "k"}}}}}
	c, s := m.Clone(), m.Summary()
	m.Notes[0], m.Chunks[0].Reasons[0], m.Chunks[0].Takes[0].Key = "changed", "changed", "changed"
	if c.Notes[0] != "n" || c.Chunks[0].Reasons[0] != "r" || c.Chunks[0].Takes[0].Key != "k" {
		t.Errorf("clone shares memory: %+v", c)
	}
	if s.Notes[0] != "n" || s.Chunks[0].Reasons[0] != "r" {
		t.Errorf("summary shares memory: %+v", s)
	}
	raw, _ := json.Marshal((&Manifest{Version: Version}).Summary())
	if !strings.Contains(string(raw), `"chunks":[]`) || !strings.Contains(string(raw), `"notes":[]`) {
		t.Errorf("empty lists are null: %s", raw)
	}
}

// Load reads what an older or newer writer left, within the contract:
// unknown keys are ignored, another version, bad JSON and a bad key refuse.
func TestLoadContract(t *testing.T) {
	write := func(body string) string {
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, ManifestFile), []byte(body), FileMode); err != nil {
			t.Fatal(err)
		}
		return d
	}
	if m, err := Load(write(`{"version":1,"status":"done","from_the_future":{"x":1}}`)); err != nil || m.Status != StatusDone {
		t.Errorf("unknown key refused: %v", err)
	}
	for name, body := range map[string]string{
		"version 2":   `{"version":2}`,
		"no version":  `{}`,
		"torn json":   `{"version":1,"chunks":[`,
		"bad pick":    `{"version":1,"chunks":[{"pick":"../../etc/passwd"}]}`,
		"bad take":    `{"version":1,"chunks":[{"takes":[{"key":"x/y"}]}]}`,
		"empty input": ``,
	} {
		if _, err := Load(write(body)); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}

// A failed Save leaves the Updated stamp as it was.
func TestFailedSaveKeepsUpdated(t *testing.T) {
	at := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	m := &Manifest{Version: Version, Updated: at}
	if err := m.Save(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("saved into a missing directory")
	}
	if !m.Updated.Equal(at) {
		t.Errorf("Updated moved to %v on a failed save", m.Updated)
	}
}

// SweepTemp reaches every directory a crash can leave a temp file in, and only
// temp files: the assembly's .assembled.tmp-*.wav and its .norm.wav live in
// out/, a half-written take or sidecar in takes/.
// Mutation: manifest.go SweepTemp, drop WorkDir from the list -> RED.
// Mutation: manifest.go SweepTemp, drop TakesDir from the list -> RED.
func TestSweepTempCoversTheWholeProject(t *testing.T) {
	dir := t.TempDir()
	temps := []string{
		filepath.Join(dir, ".manifest.json"+TempMark+"1"),
		filepath.Join(dir, TakesDir, ".aaaaaaaaaaaaaaaaaaaaaaaa.wav"+TempMark+"2"),
		filepath.Join(dir, WorkDir, ".assembled"+TempMark+"3.wav"),
		filepath.Join(dir, WorkDir, ".assembled"+TempMark+"3.wav.norm.wav"),
	}
	keep := []string{
		filepath.Join(dir, ManifestFile),
		filepath.Join(dir, TakesDir, "aaaaaaaaaaaaaaaaaaaaaaaa.wav"),
		filepath.Join(dir, WorkDir, "final.wav"),
	}
	for _, d := range []string{TakesDir, WorkDir} {
		if err := os.Mkdir(filepath.Join(dir, d), DirMode); err != nil {
			t.Fatal(err)
		}
	}
	for _, p := range append(append([]string{}, temps...), keep...) {
		if err := os.WriteFile(p, []byte("x"), FileMode); err != nil {
			t.Fatal(err)
		}
	}
	if n := SweepTemp(dir); n != len(temps) {
		t.Fatalf("swept %d, want %d", n, len(temps))
	}
	for _, p := range temps {
		if _, err := os.Lstat(p); !os.IsNotExist(err) {
			t.Errorf("%s survived", p)
		}
	}
	for _, p := range keep {
		if _, err := os.Lstat(p); err != nil {
			t.Errorf("%s was removed", p)
		}
	}
}

// SweepTemp removes only what WriteAtomic and the assembly name as temp files:
// a dot-name with the mark. A user file that merely contains the mark, a
// directory, and anything behind a symlinked takes/ or out/ are left alone.
// Mutation: manifest.go SweepTemp, test only strings.Contains(name, TempMark)
// -> the plain file is removed -> RED.
// Mutation: manifest.go SweepTemp, drop the IsDir skip -> the directory goes -> RED.
// Mutation: manifest.go SweepTemp, drop the Lstat symlink skip -> RED.
func TestSweepTempIsConservative(t *testing.T) {
	dir := t.TempDir()
	outside := t.TempDir()
	victim := filepath.Join(outside, ".victim"+TempMark+"1")
	if err := os.WriteFile(victim, []byte("x"), FileMode); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, TakesDir)); err != nil { // takes/ is a link out
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, WorkDir), DirMode); err != nil {
		t.Fatal(err)
	}
	gone := filepath.Join(dir, WorkDir, ".assembled"+TempMark+"1.wav")
	plain := filepath.Join(dir, WorkDir, "notes"+TempMark+"draft.txt")
	subdir := filepath.Join(dir, WorkDir, ".keep"+TempMark+"dir")
	for _, p := range []string{gone, plain} {
		if err := os.WriteFile(p, []byte("x"), FileMode); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(subdir, DirMode); err != nil {
		t.Fatal(err)
	}
	if n := SweepTemp(dir); n != 1 {
		t.Errorf("swept %d, want 1", n)
	}
	if _, err := os.Lstat(gone); !os.IsNotExist(err) {
		t.Errorf("the real temp file survived: %v", err)
	}
	for name, p := range map[string]string{"a user file with the mark inside": plain, "a directory": subdir, "a file behind a symlinked takes/": victim} {
		if _, err := os.Lstat(p); err != nil {
			t.Errorf("%s was removed: %v", name, err)
		}
	}
}

// Empty lists are [], never null: the GUI decodes them as non-optional arrays.
// Mutation: manifest.go MarshalJSON, skip the nil-to-empty fixes -> RED.
func TestMarshalNeverWritesNullLists(t *testing.T) {
	raw, err := json.Marshal(&Manifest{Version: Version, Chunks: []Chunk{{Index: 0}}})
	if err != nil {
		t.Fatal(err)
	}
	var back map[string]any
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if _, ok := back["notes"].([]any); !ok {
		t.Errorf("notes is %v", back["notes"])
	}
	chunk := back["chunks"].([]any)[0].(map[string]any)
	if _, ok := chunk["takes"].([]any); !ok {
		t.Errorf("takes is %v", chunk["takes"])
	}
	empty, _ := json.Marshal(Manifest{Version: Version}) // by value too
	if !strings.Contains(string(empty), `"chunks":[]`) || strings.Contains(string(empty), "null") {
		t.Errorf("empty manifest: %s", empty)
	}
	// Save goes through the same path, and the marshalling did not touch m.
	m := &Manifest{Version: Version}
	dir := t.TempDir()
	if err := m.Save(dir); err != nil {
		t.Fatal(err)
	}
	disk, _ := os.ReadFile(filepath.Join(dir, ManifestFile))
	if strings.Contains(string(disk), "null") || m.Chunks != nil {
		t.Errorf("saved %s; m.Chunks nil=%v", disk, m.Chunks == nil)
	}
}

// A take's reasons are copied too.
// Mutation: manifest.go Clone, share TakeRef.Reasons -> RED.
func TestCloneCopiesTakeReasons(t *testing.T) {
	m := &Manifest{Version: Version, Chunks: []Chunk{{Takes: []TakeRef{{Key: "k", Reasons: []string{"r"}}}}}}
	c := m.Clone()
	m.Chunks[0].Takes[0].Reasons[0] = "changed"
	if c.Chunks[0].Takes[0].Reasons[0] != "r" {
		t.Error("clone shares a take's reasons")
	}
}

// A temp file written within minAge may belong to a live orphan writer (the
// ffmpeg of a SIGKILLed daemon): it stays; an old one goes (#154 amendment 4).
// Mutation: manifest.go SweepStaleTemp, drop the ModTime check -> the fresh file goes -> RED.
func TestSweepStaleTempSkipsFreshFiles(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, WorkDir), 0o700); err != nil {
		t.Fatal(err)
	}
	fresh := filepath.Join(dir, WorkDir, ".assembled"+TempMark+"1.wav.norm.wav")
	stale := filepath.Join(dir, WorkDir, ".assembled"+TempMark+"2.wav")
	for _, p := range []string{fresh, stale} {
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}
	if n := SweepStaleTemp(dir, time.Minute); n != 1 {
		t.Fatalf("swept %d, want only the stale file", n)
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Fatalf("a file written seconds ago was removed: %v", err)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("the stale file stayed")
	}
}
