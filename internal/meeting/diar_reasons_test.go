package meeting

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"strconv"
	"strings"
	"testing"
)

// Every reason code of diarize.go (the Diar* string constants) has its own sentence in the app. The app decodes the
// code as text and falls back to a general sentence for one it does not know, so a code added here without a row in
// DiarProblem.swift would show the wrong words and no test of either side would notice. It ships with the app's
// side (Task 20c), which is what makes the Swift file exist. The codes are read from this
// package's source and looked for as `case "<code>":` labels in the Swift file; the test fails, it never skips, when the file
// is not where it should be.
// Mutations: internal/meeting/diarize.go, add `DiarFoo = "foo_bar"` to the constants -> RED; DiarProblem.swift,
// delete `case "timeout": return .diarFailedTimeout` -> RED (the literal still stands in canRetry).
func TestEveryDiarReasonHasASwiftSentence(t *testing.T) {
	swift, err := os.ReadFile("../../app/dictation/Sources/DictationCore/DiarProblem.swift")
	if err != nil {
		t.Fatal(err)
	}
	file, err := parser.ParseFile(token.NewFileSet(), "diarize.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var codes []string
	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.CONST {
			continue
		}
		for _, spec := range gd.Specs {
			vs := spec.(*ast.ValueSpec)
			for i, name := range vs.Names {
				if !strings.HasPrefix(name.Name, "Diar") || i >= len(vs.Values) {
					continue
				}
				if lit, ok := vs.Values[i].(*ast.BasicLit); ok && lit.Kind == token.STRING {
					v, _ := strconv.Unquote(lit.Value)
					codes = append(codes, v)
				}
			}
		}
	}
	if len(codes) < 8 {
		t.Fatalf("read only %d Diar* codes from diarize.go: %v", len(codes), codes)
	}
	for _, c := range codes {
		// a `case "<code>":` label, not any occurrence of the literal: canRetry compares against "timeout" too, which
		// would keep this green with the sentence for it deleted
		if !strings.Contains(string(swift), `case "`+c+`":`) {
			t.Errorf("the reason %q has no case in DiarProblem.swift", c)
		}
	}
}
