package meeting

import (
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// Every place that marks a meeting failed (Status failed, or the notes pending as "failed") goes through markFailed /
// markNotesFailed, which set Manifest.FailReason with it. The sites are found in the source of this package and of the
// daemon, not listed here: a statement `m.Status = StatusFailed`, a composite literal `Manifest{Status: StatusFailed}`,
// a `meeting.StatusFailed` from another package, or a `NotesPending: "failed"`, written anywhere else by hand with no
// code, fails this test.
// Mutation: internal/meeting/runner.go stop, replace the `m.markFailed(err, &failedAt)` line with
// `m.Status, m.Error, m.FailedAt = StatusFailed, err.Error(), &failedAt` -> RED.
// Mutation: add `_ = Manifest{Status: StatusFailed}` to any function of runner.go -> RED (composite literal).
// Mutation: add `_ = meeting.Manifest{NotesPending: "failed"}` to a daemon function -> RED (other package).
func TestEveryFailureSiteSetsACode(t *testing.T) {
	fset := token.NewFileSet()
	marked := 0
	for _, dir := range []string{".", "../daemon"} {
		files, err := filepath.Glob(filepath.Join(dir, "*.go"))
		if err != nil || len(files) == 0 {
			t.Fatalf("no sources in %s: %v", dir, err)
		}
		for _, name := range files {
			if strings.HasSuffix(name, "_test.go") {
				continue
			}
			file, err := parser.ParseFile(fset, name, nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			for _, decl := range file.Decls {
				fd, ok := decl.(*ast.FuncDecl)
				if !ok || fd.Body == nil {
					continue
				}
				allowed := dir == "." && (fd.Name.Name == "markFailed" || fd.Name.Name == "markNotesFailed")
				ast.Inspect(fd.Body, func(n ast.Node) bool {
					var hits []ast.Node
					switch v := n.(type) {
					case *ast.AssignStmt: // m.Status = StatusFailed, m.Status, m.Error = StatusFailed, ...
						for i, lhs := range v.Lhs {
							if i < len(v.Rhs) && isFailureField(lhs) && marksFailure(v.Rhs[i]) {
								hits = append(hits, v)
							}
						}
					case *ast.KeyValueExpr: // Manifest{Status: StatusFailed}
						if isFailureField(v.Key) && marksFailure(v.Value) {
							hits = append(hits, v)
						}
					}
					for _, h := range hits {
						if allowed {
							marked++
						} else {
							t.Errorf("%s: %s marks a meeting failed without a reason code; use markFailed / markNotesFailed",
								fset.Position(h.Pos()), fd.Name.Name)
						}
					}
					return true
				})
			}
		}
	}
	if marked < 2 {
		t.Fatalf("found %d marking sites inside markFailed / markNotesFailed, want both", marked)
	}
}

// isFailureField: the left side (or key) names a Manifest's Status or NotesPending, as `m.Status` or a bare key.
func isFailureField(e ast.Expr) bool {
	switch v := e.(type) {
	case *ast.Ident:
		return v.Name == "Status" || v.Name == "NotesPending"
	case *ast.SelectorExpr:
		return v.Sel.Name == "Status" || v.Sel.Name == "NotesPending"
	}
	return false
}

// marksFailure: the value is StatusFailed (bare in this package, `meeting.StatusFailed` outside it) or the literal
// "failed". A `vproject.StatusFailed` is another type's constant and does not count.
func marksFailure(e ast.Expr) bool {
	switch v := e.(type) {
	case *ast.Ident:
		return v.Name == "StatusFailed"
	case *ast.SelectorExpr:
		x, ok := v.X.(*ast.Ident)
		return ok && x.Name == "meeting" && v.Sel.Name == "StatusFailed"
	case *ast.BasicLit:
		s, err := strconv.Unquote(v.Value)
		return err == nil && s == "failed"
	}
	return false
}

// Each way a run can fail leaves its own code, next to the free text kept for the log.
// Mutation: internal/meeting/fail_reason.go failReason, move `case errors.As(err, &path)` above the ENOSPC case -> RED
// (the disk full rows); delete the `case errors.As(err, &model)` arm -> RED
// (speech_model_missing); delete the `errors.As(err, &down)` arm -> RED (the three notes_engine_* rows).
func TestAFailedRunRecordsItsCode(t *testing.T) {
	down := func(reason string) error { return &EngineDownError{Err: errors.New("raw english"), Reason: reason} }
	speech := func(err error) func(*fixture) {
		return func(f *fixture) {
			f.r.Transcribe = func(context.Context, string) (*stt.Result, error) { return nil, err }
		}
	}
	notes := func(err error) func(*fixture) {
		return func(f *fixture) { f.r.Chat = &fakeChat{errs: []error{err, err, err, err}} }
	}
	cases := []struct {
		name   string
		setup  func(*fixture)
		status Status
		pend   string
		want   string
	}{
		{"model missing", speech(&stt.ModelError{}), StatusFailed, "", FailSpeechModelMissing},
		{"busy", speech(stt.ErrBusy), StatusFailed, "", FailSpeechBusy},
		{"engine broke", speech(errors.New("boom")), StatusFailed, "", FailSpeechFailed},
		{"file error", speech(&os.PathError{Op: "write", Path: "x", Err: os.ErrPermission}), StatusFailed, "", FailStorage},
		{"disk full", speech(&os.PathError{Op: "write", Path: "x", Err: syscall.ENOSPC}), StatusFailed, "", FailDiskFull},
		{"rename onto a full disk", speech(&os.LinkError{Op: "rename", Old: "a", New: "b", Err: syscall.ENOSPC}), StatusFailed, "", FailDiskFull},
		{"notes: engine start", notes(down(FailNotesEngineStart)), StatusTranscribed, "failed", FailNotesEngineStart},
		{"notes: verify refused", notes(down(FailNotesEngineVerify)), StatusTranscribed, "failed", FailNotesEngineVerify},
		{"notes: timed out", notes(down(FailNotesEngineTimeout)), StatusTranscribed, "failed", FailNotesEngineTimeout},
		{"notes: no cause given", notes(&EngineDownError{Err: errors.New("x")}), StatusTranscribed, "failed", FailNotesEngineStart},
		{"notes: every chunk failed", notes(errors.New("bad json")), StatusTranscribed, "failed", FailNotesEmpty},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			tc.setup(f)
			id := f.start(t, 30, 30, 5000, false)
			_ = f.r.Process(context.Background(), id)
			m := f.load(t, id)
			if m.Status != tc.status || m.NotesPending != tc.pend || m.FailReason != tc.want {
				t.Fatalf("manifest = status %s pending %q reason %q error %q; want %s %q %q",
					m.Status, m.NotesPending, m.FailReason, m.Error, tc.status, tc.pend, tc.want)
			}
			if tc.name == "engine broke" && m.Error != "boom" {
				t.Fatalf("the log text = %q, want the raw error kept", m.Error)
			}
		})
	}
}

// A transcript that cannot be read fails the meeting with its own code; a write that fails after the model answered is
// a storage failure.
func TestNoTranscriptAndNotesWriteHaveCodes(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 30, 30, 5000, false)
	if _, err := f.r.Store.Update(id, func(m *Manifest) { m.Status = StatusSummarizing }); err != nil {
		t.Fatal(err)
	}
	_ = f.r.Process(context.Background(), id) // no transcript.json was ever written
	if m := f.load(t, id); m.Status != StatusFailed || m.FailReason != FailNoTranscript {
		t.Fatalf("manifest = status %s reason %q err %q, want failed / %s", m.Status, m.FailReason, m.Error, FailNoTranscript)
	}

	g := newFixture(t)
	id = g.start(t, 30, 30, 5000, false)
	dir, _ := g.r.Store.Dir(id)
	if err := os.MkdirAll(filepath.Join(dir, NotesMD, "x"), 0o700); err != nil {
		t.Fatal(err)
	}
	_ = g.r.Process(context.Background(), id)
	if m := g.load(t, id); m.NotesPending != "failed" || m.FailReason != FailStorage {
		t.Fatalf("manifest = %+v, want notes failed / %s", m, FailStorage)
	}
}

// The code goes with the failure: a retry, and a finished meeting, carry none.
// Mutation: internal/meeting/runner.go Retry, delete `m.FailReason, ` from the update -> RED.
func TestTheCodeClearsWithTheFailure(t *testing.T) {
	f := newFixture(t)
	f.r.Transcribe = func(context.Context, string) (*stt.Result, error) { return nil, errors.New("boom") }
	id := f.start(t, 30, 30, 5000, false)
	_ = f.r.Process(context.Background(), id)
	if f.load(t, id).FailReason == "" {
		t.Fatal("setup: no code recorded")
	}
	f.r.Transcribe = newFixture(t).r.Transcribe
	if _, err := f.r.Retry(id); err != nil {
		t.Fatal(err)
	}
	if m := f.load(t, id); m.FailReason != "" || m.Error != "" {
		t.Fatalf("after Retry: %+v", m)
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if m := f.load(t, id); m.Status != StatusDone || m.FailReason != "" {
		t.Fatalf("after the run: %+v", m)
	}
}

// Every Fail* code has its sentence in the app. The codes are read from fail_reason.go, and each must stand as a
// `case "<code>":` label in MeetingFailure.swift: a code added here with no row there would show the general sentence
// and no test of either side would notice. The test fails, never skips, when the Swift file is not where it should be.
// Mutations: fail_reason.go, add `FailFoo = "foo_bar"` to the constants -> RED; MeetingFailure.swift, delete
// `case "notes_empty": return .meetingNotesEmpty` -> RED.
func TestEveryFailReasonHasASwiftSentence(t *testing.T) {
	swift, err := os.ReadFile("../../app/dictation/Sources/DictationCore/MeetingFailure.swift")
	if err != nil {
		t.Fatal(err)
	}
	file, err := parser.ParseFile(token.NewFileSet(), "fail_reason.go", nil, 0)
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
				if !strings.HasPrefix(name.Name, "Fail") || i >= len(vs.Values) {
					continue
				}
				if lit, ok := vs.Values[i].(*ast.BasicLit); ok && lit.Kind == token.STRING {
					v, _ := strconv.Unquote(lit.Value)
					codes = append(codes, v)
				}
			}
		}
	}
	if len(codes) < 10 {
		t.Fatalf("read only %d Fail* codes from fail_reason.go: %v", len(codes), codes)
	}
	for _, c := range codes {
		if !strings.Contains(string(swift), `case "`+c+`":`) {
			t.Errorf("the reason %q has no case in MeetingFailure.swift", c)
		}
	}
}

// A meeting that finishes carries no code, whatever put one there: the clear is on the done transition itself (the
// short-transcript path writes notes without passing through "summarizing").
// Mutation: internal/meeting/runner.go writeNotes, delete `m.FailReason = ""` from the StatusDone update -> RED.
func TestADoneMeetingCarriesNoCode(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if _, err := f.r.Store.Update(id, func(m *Manifest) { m.Status, m.FailReason = StatusSummarizing, FailNotesEmpty }); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	if err := f.r.writeNotes(id, dir, "# notes\n", nil); err != nil {
		t.Fatal(err)
	}
	if m := f.load(t, id); m.Status != StatusDone || m.FailReason != "" {
		t.Fatalf("manifest = %+v, want done with no code", m)
	}
}
