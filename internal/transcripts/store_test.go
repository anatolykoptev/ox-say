package transcripts

import (
	"bytes"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPutGetListDelete(t *testing.T) {
	s, err := New(filepath.Join(t.TempDir(), "transcripts"), nil)
	if err != nil {
		t.Fatal(err)
	}
	a, err := s.Put(Meta{Title: "Interview", Seconds: 12}, []byte(`{"text":"one"}`))
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.Put(Meta{Title: "Note"}, []byte(`{"text":"two"}`))
	if err != nil {
		t.Fatal(err)
	}
	list, err := s.List(10)
	if err != nil || len(list) != 2 || list[0].ID != b.ID || list[1].ID != a.ID {
		t.Fatalf("list %+v %v, want newest first", list, err)
	}
	m, ox, err := s.Get(a.ID)
	if err != nil || m.Title != "Interview" || m.Seconds != 12 || string(ox) != `{"text":"one"}` {
		t.Fatalf("get %+v %s %v", m, ox, err)
	}
	if err := s.Delete(a.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Get(a.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("after delete: %v", err)
	}
	if err := s.Delete(a.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second delete: %v, want ErrNotFound", err)
	}
}

// Two uploads in one second must not collide: the id carries a random suffix, and List orders them
// deterministically (Created, then id) however fast they arrive.
func TestSameSecondPutsGetDistinctIDsAndAStableOrder(t *testing.T) {
	s, _ := New(filepath.Join(t.TempDir(), "t"), nil)
	at := time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)
	seen := map[string]bool{}
	for i := 0; i < 20; i++ {
		m, err := s.Put(Meta{Title: "x", Created: at}, []byte(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		if seen[m.ID] {
			t.Fatalf("id %s issued twice", m.ID)
		}
		seen[m.ID] = true
		if !strings.HasPrefix(m.ID, "20261102-100000-") {
			t.Fatalf("id %s does not carry the second of Created", m.ID)
		}
	}
	first, _ := s.List(100)
	if len(first) != 20 {
		t.Fatalf("listed %d, want 20", len(first))
	}
	for i := 1; i < len(first); i++ {
		if first[i-1].ID < first[i].ID {
			t.Fatalf("equal Created must order by id descending: %s before %s", first[i-1].ID, first[i].ID)
		}
	}
	again, _ := s.List(100)
	for i := range first {
		if first[i].ID != again[i].ID {
			t.Fatal("List order changed between calls")
		}
	}
}

func TestRealPutsInOneSecondListNewestFirst(t *testing.T) {
	s, _ := New(filepath.Join(t.TempDir(), "t"), nil)
	var ids []string
	for i := 0; i < 5; i++ {
		m, err := s.Put(Meta{Title: "x"}, []byte(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, m.ID)
	}
	list, _ := s.List(10)
	for i, m := range list {
		if want := ids[len(ids)-1-i]; m.ID != want {
			t.Fatalf("position %d: %s, want %s (insertion order reversed)", i, m.ID, want)
		}
	}
}

func TestListLimit(t *testing.T) {
	s, _ := New(filepath.Join(t.TempDir(), "t"), nil)
	for i := 0; i < 3; i++ {
		_, _ = s.Put(Meta{Title: "x"}, []byte(`{}`))
	}
	if list, _ := s.List(2); len(list) != 2 {
		t.Fatalf("limit 2 gave %d", len(list))
	}
	if list, _ := s.List(0); len(list) != 3 {
		t.Fatalf("limit 0 means no limit, gave %d", len(list))
	}
}

func TestIDsAreValidatedBeforeTheDiskIsTouched(t *testing.T) {
	root := t.TempDir()
	s, _ := New(filepath.Join(root, "t"), nil)
	// a victim next to the store: a traversal id must not reach it
	victim := filepath.Join(root, "x")
	if err := os.MkdirAll(victim, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"", "../x", "..%2Fx", "20261001-000000-zzzzzz", "20261001-000000-abc", "a/b",
		"20261001-000000-abcdef\n", "20261001-000000-abcdef/..", "20261001-000000-ABCDEF", ".tmp-20261001-000000-abcdef"} {
		if ValidID(bad) {
			t.Errorf("%q: ValidID must refuse", bad)
		}
		if _, _, err := s.Get(bad); !errors.Is(err, ErrInvalidID) {
			t.Errorf("%q: Get: want ErrInvalidID, got %v", bad, err)
		}
		if err := s.Delete(bad); !errors.Is(err, ErrInvalidID) {
			t.Errorf("%q: Delete: want ErrInvalidID, got %v", bad, err)
		}
	}
	if _, err := os.Stat(victim); err != nil {
		t.Fatalf("the sibling directory was touched: %v", err)
	}
	if !ValidID("20261001-000000-abcdef") {
		t.Fatal("a well-formed id must be valid")
	}
}

func TestPutRefusesACallerIDThatIsNotValid(t *testing.T) {
	s, _ := New(filepath.Join(t.TempDir(), "t"), nil)
	if _, err := s.Put(Meta{ID: "../x", Title: "x"}, []byte(`{}`)); !errors.Is(err, ErrInvalidID) {
		t.Fatalf("Put with a traversal id: %v, want ErrInvalidID", err)
	}
}

func TestFilesAreOwnerOnly(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "t")
	s, _ := New(dir, nil)
	m, _ := s.Put(Meta{Title: "x"}, []byte(`{}`))
	for _, p := range []string{dir, filepath.Join(dir, m.ID), filepath.Join(dir, m.ID, "meta.json"), filepath.Join(dir, m.ID, "ox.json")} {
		st, err := os.Stat(p)
		if err != nil || st.Mode().Perm()&0o077 != 0 {
			t.Errorf("%s: %v %v, transcripts are private", p, st, err)
		}
	}
}

func TestNewTightensALooseExistingDirectory(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "t")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := New(dir, nil); err != nil {
		t.Fatal(err)
	}
	if st, _ := os.Stat(dir); st.Mode().Perm()&0o077 != 0 {
		t.Fatalf("existing directory left at %v", st.Mode().Perm())
	}
}

func TestAFailedWriteLeavesNoPartialTranscript(t *testing.T) {
	dir := t.TempDir()
	s, _ := New(dir, nil)
	old := rename
	rename = func(string, string) error { return errors.New("boom") }
	defer func() { rename = old }()
	if _, err := s.Put(Meta{Title: "x"}, []byte(`{}`)); err == nil {
		t.Fatal("a failed rename must fail Put")
	}
	if list, _ := s.List(10); len(list) != 0 {
		t.Fatalf("partial transcript visible: %+v", list)
	}
	if left, _ := filepath.Glob(filepath.Join(dir, ".tmp-*")); len(left) != 0 {
		t.Fatalf("temp dir left behind: %v", left)
	}
}

func TestNewSweepsTempDirsACrashLeft(t *testing.T) {
	dir := t.TempDir()
	left := filepath.Join(dir, ".tmp-20261001-000000-abcdef")
	if err := os.MkdirAll(left, 0o700); err != nil {
		t.Fatal(err)
	}
	staleAt := time.Now().Add(-2 * tmpSweepMinAge)
	if err := os.Chtimes(left, staleAt, staleAt); err != nil {
		t.Fatal(err)
	}
	if _, err := New(dir, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(left); !os.IsNotExist(err) {
		t.Fatalf("leftover temp dir survived New: %v", err)
	}
}

// A temp dir modified within tmpSweepMinAge may be a live daemon's in-flight
// Put: a second `ox-say serve` must leave it alone.
func TestNewLeavesAFreshTempDirAlone(t *testing.T) {
	dir := t.TempDir()
	fresh := filepath.Join(dir, ".tmp-20261001-000000-abcdef")
	if err := os.MkdirAll(fresh, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := New(dir, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Fatalf("a temp dir a live writer may own was removed: %v", err)
	}
}

// A leftover that cannot be removed warns and does not fail New: one stuck
// temp dir must not take the store down.
func TestNewWarnsAndOpensOnAStuckTempDir(t *testing.T) {
	dir := t.TempDir()
	stuck := filepath.Join(dir, ".tmp-20261001-000000-abcdef")
	if err := os.MkdirAll(stuck, 0o700); err != nil {
		t.Fatal(err)
	}
	staleAt := time.Now().Add(-2 * tmpSweepMinAge)
	if err := os.Chtimes(stuck, staleAt, staleAt); err != nil {
		t.Fatal(err)
	}
	old := removeAll
	removeAll = func(string) error { return errors.New("boom") }
	defer func() { removeAll = old }()
	var logs bytes.Buffer
	s, err := New(dir, slog.New(slog.NewTextHandler(&logs, nil)))
	if err != nil || s == nil {
		t.Fatalf("a stuck temp dir failed New: %v", err)
	}
	if !strings.Contains(logs.String(), "cannot remove a leftover temp dir") {
		t.Fatalf("the sweep failure was not logged: %q", logs.String())
	}
}

func TestListSkipsWhatIsNotATranscript(t *testing.T) {
	dir := t.TempDir()
	s, _ := New(dir, nil)
	good, _ := s.Put(Meta{Title: "ok"}, []byte(`{}`))
	// a stray file, a half-deleted dir without meta, a dir with a broken meta
	_ = os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("x"), 0o600)
	_ = os.MkdirAll(filepath.Join(dir, "20261001-000000-abcdef"), 0o700)
	bad := filepath.Join(dir, "20261001-000001-abcdef")
	_ = os.MkdirAll(bad, 0o700)
	_ = os.WriteFile(filepath.Join(bad, "meta.json"), []byte("{nope"), 0o600)
	list, err := s.List(10)
	if err != nil || len(list) != 1 || list[0].ID != good.ID {
		t.Fatalf("list %+v %v, want only the good one", list, err)
	}
}

// An entry that lost its ox.json — or a Delete that landed between the two
// reads — is a transcript that is not there, not a server fault.
func TestGetMissingDocumentIsNotFound(t *testing.T) {
	dir := t.TempDir()
	s, _ := New(dir, nil)
	m, _ := s.Put(Meta{Title: "x"}, []byte(`{}`))
	if err := os.Remove(filepath.Join(dir, m.ID, "ox.json")); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Get(m.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("meta without a document must read as not found, got %v", err)
	}
}
