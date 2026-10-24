package meeting

import (
	"errors"
	"os"
	"path/filepath"
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

// A symlink named like a meeting must not be followed by Delete: it would
// remove the target's contents.
// Mutation: internal/meeting/store.go Delete, drop the vproject.Contained
// call -> RED (the symlink's target is emptied).
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
