package meeting

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

func newStore(t *testing.T) *Store {
	t.Helper()
	return &Store{Root: filepath.Join(t.TempDir(), "meetings")}
}

var t0 = time.Date(2026, 10, 23, 14, 30, 0, 0, time.UTC)

func TestStoreCreateLoadUpdateList(t *testing.T) {
	s := newStore(t)
	m, dir, err := s.Create(Manifest{Title: "Standup", Labels: Labels{Me: "Anatoly", Them: "Other"}}, t0)
	if err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(dir); err != nil || st.Mode().Perm() != 0o700 {
		t.Fatalf("meeting dir = %v, %v; want mode 0700 (private audio)", st, err)
	}
	if m.Status != StatusRecording || m.Version != ManifestVersion {
		t.Fatalf("created manifest = %+v", m)
	}
	if _, err := s.Update(m.ID, func(x *Manifest) { x.Status = StatusQueued }); err != nil {
		t.Fatal(err)
	}
	got, err := s.Load(m.ID)
	if err != nil || got.Status != StatusQueued || got.Title != "Standup" {
		t.Fatalf("Load = %+v, %v", got, err)
	}
	// a second, later meeting lists first
	m2, _, _ := s.Create(Manifest{Title: "Later"}, t0.Add(time.Hour))
	list, err := s.List()
	if err != nil || len(list) != 2 || list[0].ID != m2.ID {
		t.Fatalf("List = %v, %v; want the later meeting first", list, err)
	}
}

func TestStoreRefusesForeignIDs(t *testing.T) {
	s := newStore(t)
	for _, id := range []string{"", "..", "../x", "20261023-143000-zzzzzz", "meetings"} {
		if _, err := s.Load(id); !errors.Is(err, ErrNotFound) {
			t.Errorf("Load(%q) = %v, want ErrNotFound", id, err)
		}
		if err := s.Delete(id); !errors.Is(err, ErrNotFound) {
			t.Errorf("Delete(%q) = %v, want ErrNotFound", id, err)
		}
	}
}

// A symlink named like a meeting is not a meeting: Delete answers ErrNotFound
// and leaves the link and its target alone. (os.RemoveAll on a symlink would
// remove only the link, never the target; the guard's value is that contract.)
// Mutation: internal/meeting/store.go Delete, drop the vproject.Contained
// call -> RED (Delete returns nil and the link is gone).
func TestStoreDeleteDoesNotFollowASymlink(t *testing.T) {
	s := newStore(t)
	if err := os.MkdirAll(s.Root, 0o700); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()
	keep := filepath.Join(outside, "keep.txt")
	if err := os.WriteFile(keep, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	id := "20261023-143000-abcdef"
	if err := os.Symlink(outside, filepath.Join(s.Root, id)); err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(id); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Delete(symlink) = %v, want ErrNotFound", err)
	}
	if _, err := os.Stat(keep); err != nil {
		t.Fatalf("the symlink target was touched: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(s.Root, id)); err != nil {
		t.Fatalf("the planted link was removed: %v", err)
	}
}

func TestListSkipsAnUnreadableMeeting(t *testing.T) {
	s := newStore(t)
	good, _, _ := s.Create(Manifest{Title: "ok"}, t0)
	bad := filepath.Join(s.Root, "20261023-150000-aaaaaa")
	if err := os.MkdirAll(bad, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bad, ManifestFile), []byte("{broken"), 0o600); err != nil {
		t.Fatal(err)
	}
	list, err := s.List()
	if err != nil || len(list) != 1 || list[0].ID != good.ID {
		t.Fatalf("List = %v, %v; want only the readable meeting", list, err)
	}
}

// An id already on disk belongs to another meeting: Create must not reuse the
// directory (it would overwrite that manifest) but take a fresh id.
// Mutation: internal/meeting/store.go Create, replace os.Mkdir(dir, 0o700)
// with os.MkdirAll(dir, 0o700) -> RED (the taken id is reused).
func TestStoreCreateNeverReusesAnExistingDirectory(t *testing.T) {
	s := newStore(t)
	taken := "20261023-143000-aaaaaa"
	if err := os.MkdirAll(filepath.Join(s.Root, taken), 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(s.Root, taken, "other.txt")
	if err := os.WriteFile(marker, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	ids := []string{taken, "20261023-143000-bbbbbb"}
	s.newID = func(time.Time) string { id := ids[0]; ids = ids[1:]; return id }
	m, dir, err := s.Create(Manifest{Title: "fresh"}, t0)
	if err != nil {
		t.Fatal(err)
	}
	if m.ID != "20261023-143000-bbbbbb" || filepath.Base(dir) != m.ID {
		t.Fatalf("Create reused the taken id: %s in %s", m.ID, dir)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("the existing meeting directory was disturbed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(s.Root, taken, ManifestFile)); err == nil {
		t.Fatal("a manifest was written into the taken directory")
	}
}

// If every id is taken Create gives up with an error instead of looping.
func TestStoreCreateGivesUpWhenEveryIDIsTaken(t *testing.T) {
	s := newStore(t)
	taken := "20261023-143000-aaaaaa"
	if err := os.MkdirAll(filepath.Join(s.Root, taken), 0o700); err != nil {
		t.Fatal(err)
	}
	calls := 0
	s.newID = func(time.Time) string { calls++; return taken }
	if _, _, err := s.Create(Manifest{}, t0); err == nil {
		t.Fatal("Create succeeded on a taken id")
	}
	if calls != createTries {
		t.Fatalf("newID called %d times, want %d", calls, createTries)
	}
}

// When the save fails the caller gets no manifest: it must not mistake the
// in-memory edit for what is on disk.
// Mutation: internal/meeting/store.go Update, return `m, s.save(dir, m)` -> RED.
func TestStoreUpdateReturnsNilWhenTheSaveFails(t *testing.T) {
	s := newStore(t)
	m, dir, err := s.Create(Manifest{Title: "x"}, t0)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o500); err != nil { // read-only: the atomic write cannot create its temp file
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	got, err := s.Update(m.ID, func(x *Manifest) { x.Status = StatusQueued })
	if err == nil {
		t.Skip("directory permissions do not stop writes here (running as root?)")
	}
	if got != nil {
		t.Fatalf("Update = %+v with error %v; want nil manifest", got, err)
	}
}

// fn edits the record, not its identity: a changed ID would save the manifest
// under the wrong name.
// Mutation: internal/meeting/store.go Update, delete `m.ID = id` -> RED.
func TestStoreUpdateKeepsTheID(t *testing.T) {
	s := newStore(t)
	m, _, _ := s.Create(Manifest{Title: "x"}, t0)
	got, err := s.Update(m.ID, func(x *Manifest) { x.ID = "20261023-999999-ffffff"; x.Title = "y" })
	if err != nil || got.ID != m.ID || got.Title != "y" {
		t.Fatalf("Update = %+v, %v; want ID %s kept and the title changed", got, err, m.ID)
	}
	if disk, err := s.Load(m.ID); err != nil || disk.ID != m.ID {
		t.Fatalf("on disk = %+v, %v", disk, err)
	}
}

// A skipped meeting leaves one log line with the directory and the error,
// and nothing from inside the manifest.
// Mutation: internal/meeting/store.go List, delete the s.log().Warn call -> RED.
func TestListLogsWhatItSkips(t *testing.T) {
	var buf bytes.Buffer
	s := newStore(t)
	s.Log = slog.New(slog.NewTextHandler(&buf, nil))
	bad := "20261023-150000-aaaaaa"
	if err := os.MkdirAll(filepath.Join(s.Root, bad), 0o700); err != nil {
		t.Fatal(err)
	}
	secret := `{"title":"SECRETWORDS", "version": 9`
	if err := os.WriteFile(filepath.Join(s.Root, bad, ManifestFile), []byte(secret), 0o600); err != nil {
		t.Fatal(err)
	}
	// a directory with no manifest yet (Create is mid-flight) is not an error
	if err := os.MkdirAll(filepath.Join(s.Root, "20261023-150100-bbbbbb"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := s.List(); err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	if strings.Count(out, "\n") != 1 || !strings.Contains(out, bad) || strings.Contains(out, "SECRETWORDS") {
		t.Fatalf("log = %q; want one line naming %s and no manifest text", out, bad)
	}
}

// DeleteIf judges the manifest and removes the directory under one hold of the
// store lock: a runner Update cannot slip a status change between the two.
// Mutation: internal/meeting/store.go DeleteIf, call check before s.mu.Lock()
// -> RED (the check ran outside the lock).
func TestDeleteIfChecksUnderTheStoreLock(t *testing.T) {
	s := &Store{Root: t.TempDir()}
	m, dir, err := s.Create(Manifest{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	refusal := errors.New("not now")
	err = s.DeleteIf(m.ID, func(got Manifest) error {
		if s.mu.TryLock() {
			s.mu.Unlock()
			t.Error("check ran without the store lock")
		}
		if got.ID != m.ID || got.Status != StatusRecording {
			t.Errorf("check saw %+v", got)
		}
		return refusal
	})
	if !errors.Is(err, refusal) {
		t.Fatalf("err = %v, want the check's refusal", err)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("a refused delete removed the directory: %v", err)
	}
	if err := s.DeleteIf(m.ID, func(Manifest) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("an allowed delete left the directory: %v", err)
	}
	if err := s.DeleteIf(m.ID, func(Manifest) error { return nil }); !errors.Is(err, ErrNotFound) {
		t.Fatalf("DeleteIf on a gone meeting = %v, want ErrNotFound", err)
	}
}
