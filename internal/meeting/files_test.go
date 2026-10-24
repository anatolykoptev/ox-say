package meeting

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
)

// fileNameConstants reads the string constants of the package's own source that name a file, from the source and
// not from a list written here: a list of the files the package knows cannot notice a file it has just learned.
func fileNameConstants(t *testing.T) map[string]string {
	t.Helper()
	fileLike := regexp.MustCompile(`^[a-z0-9._-]+\.(json|md|pcm|wav)$`)
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	found := map[string]string{} // value -> constant name
	fset := token.NewFileSet()
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") || strings.HasSuffix(e.Name(), "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, e.Name(), nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, decl := range file.Decls {
			gd, ok := decl.(*ast.GenDecl)
			if !ok || gd.Tok != token.CONST {
				continue
			}
			for _, spec := range gd.Specs {
				vs := spec.(*ast.ValueSpec)
				for i, name := range vs.Names {
					if i >= len(vs.Values) {
						continue
					}
					lit, ok := vs.Values[i].(*ast.BasicLit)
					if !ok || lit.Kind != token.STRING {
						continue
					}
					if v, err := strconv.Unquote(lit.Value); err == nil && fileLike.MatchString(v) {
						found[v] = name.Name
					}
				}
			}
		}
	}
	return found
}

// Every file a meeting directory can hold is either removed with the audio (audioFiles, or inside WorkDir) or on
// the explicit keep list, and the lists name no file the package does not know. A file added without deciding is
// a red test here, not a voiceprint that outlives the retention period.
// Mutations: internal/meeting/meeting.go, add the constant `ExtraJSON = "extra.json"` -> RED (unaccounted);
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
