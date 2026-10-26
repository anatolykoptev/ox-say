package meeting

import (
	"go/ast"
	"go/constant"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// stubImporter lets the type checker read the package alone: the imports are empty packages, so a use of one is an
// error the checker reports and goes on from, while the package's own constants, which are all this reads, are
// folded as the compiler would fold them (`"vp" + ".json"`, a constant built from another).
type stubImporter struct{}

func (stubImporter) Import(path string) (*types.Package, error) {
	pkg := types.NewPackage(path, path[strings.LastIndex(path, "/")+1:])
	pkg.MarkComplete()
	return pkg, nil
}

// fileNameConstants reads the string constants of the package's own source that look like a file name (a name, a
// dot and an extension of any kind), from the source and not from a list written here: a list of the files the
// package knows cannot notice a file it has just learned. Constants are resolved by go/types, so a name built by
// concatenation or from another constant counts the same as a literal.
func fileNameConstants(t *testing.T) map[string]string {
	t.Helper()
	fileLike := regexp.MustCompile(`^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$`)
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	var files []*ast.File
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") || strings.HasSuffix(e.Name(), "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, e.Name(), nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, file)
	}
	conf := types.Config{Importer: stubImporter{}, IgnoreFuncBodies: true, Error: func(error) {}}
	pkg, _ := conf.Check("meeting", fset, files, nil)
	found := map[string]string{} // value -> constant name
	for _, name := range pkg.Scope().Names() {
		c, ok := pkg.Scope().Lookup(name).(*types.Const)
		if !ok || c.Val().Kind() != constant.String {
			continue
		}
		if v := constant.StringVal(c.Val()); fileLike.MatchString(v) {
			found[v] = name
		}
	}
	return found
}

// Every file a meeting directory can hold is either removed with the audio (audioFiles, or inside WorkDir) or on
// the explicit keep list, and the lists name no file the package does not know. A file added without deciding is
// a red test here, not a voiceprint that outlives the retention period.
// Mutations: internal/meeting/meeting.go, add the constant `ExtraJSON = "extra.json"` -> RED (unaccounted); add
// `VoiceprintBin = "voiceprint.bin"` -> RED (an extension the old pattern did not know); add
// `VP = "vp" + ".json"` -> RED (a name built by concatenation, not a literal);
// internal/meeting/retention.go, delete `DiarizationJSON` from workFiles -> RED.
func TestEveryMeetingFileIsAccountedFor(t *testing.T) {
	lists := map[string][]string{"audioFiles": audioFiles, "workFiles": workFiles, "keptFiles": keptFiles, "rootFiles": rootFiles}
	where := map[string][]string{} // file -> lists holding it
	for name, list := range lists {
		for _, f := range list {
			where[f] = append(where[f], name)
		}
	}
	consts := fileNameConstants(t)
	if len(consts) < 8 {
		t.Fatalf("read only %d file constants from the source: %v", len(consts), consts)
	}
	for value, name := range consts {
		switch got := where[value]; len(got) {
		case 0:
			t.Errorf("%s (%q) is on no list in retention.go: decide whether it goes with the audio or stays", name, value)
		case 1:
		default:
			t.Errorf("%s (%q) is on several lists: %v", name, value, got)
		}
	}
	for f, got := range where {
		if _, ok := consts[f]; !ok {
			t.Errorf("%q is on %v but no constant of the package names it", f, got)
		}
	}
	if !slices.Contains(workFiles, DiarizationJSON) {
		t.Errorf("the diarizer's answer must be on workFiles")
	}
}

// The keep list is a promise too: a sweep takes the audio and the work files and nothing else. Every file of every
// list is put in a meeting past its retention period, the sweep runs, and the audio and work files are gone while
// each kept file is still there with its content.
// Mutation: internal/meeting/retention.go deleteAudio, `for _, name := range audioFiles {` ->
// `for _, name := range append(slices.Clone(audioFiles), NotesJSON) {` -> RED (the notes went with the audio);
// delete the `for _, name := range workFiles {` loop together with the `os.RemoveAll(filepath.Join(dir, WorkDir))`
// line -> RED (the diarizer's answer survives); delete only the `os.RemoveAll(filepath.Join(dir, WorkDir))` line
// -> RED (the piece cache survives).
func TestASweepTakesTheAudioAndTheWorkFilesAndKeepsTheRest(t *testing.T) {
	f := newFixture(t)
	id := expiredMeeting(t, f)
	dir, _ := f.r.Store.Dir(id)
	if err := os.MkdirAll(filepath.Join(dir, WorkDir), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range audioFiles {
		writeFile(t, filepath.Join(dir, name), "audio")
	}
	for _, name := range workFiles {
		writeFile(t, filepath.Join(dir, WorkDir, name), "work")
	}
	piece := filepath.Join(dir, WorkDir, "them-0-30.json") // a piece cache: not a named work file, goes with work/ (#256)
	writeFile(t, piece, "cached")
	kept := map[string]string{}
	for _, name := range keptFiles {
		if name == ManifestFile {
			continue // rewritten by the sweep itself (AudioDeleted)
		}
		path := filepath.Join(dir, name)
		if b, err := os.ReadFile(path); err == nil {
			kept[name] = string(b)
			continue
		}
		kept[name] = "kept " + name
		writeFile(t, path, kept[name])
	}
	if n := f.r.SweepRetention(); n != 1 {
		t.Fatalf("swept %d meetings, want 1", n)
	}
	for _, name := range audioFiles {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			t.Errorf("%s survived the sweep", name)
		}
	}
	for _, name := range workFiles {
		if _, err := os.Stat(filepath.Join(dir, WorkDir, name)); err == nil {
			t.Errorf("work/%s survived the sweep", name)
		}
	}
	if _, err := os.Stat(piece); err == nil {
		t.Errorf("the piece cache survived the sweep")
	}
	for name, want := range kept {
		if got, err := os.ReadFile(filepath.Join(dir, name)); err != nil || string(got) != want {
			t.Errorf("%s did not survive the sweep intact: %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, ManifestFile)); err != nil {
		t.Errorf("the manifest is gone: %v", err)
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}
