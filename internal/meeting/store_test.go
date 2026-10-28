package meeting

import (
	"bytes"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
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

// A delete takes the meeting out of the store under the lock (a rename to a tombstone) and unlinks the files after
// letting it go: another meeting's Update, the runner's status write, does not wait for the unlink of a long
// recording (#252). The unlink is held here until an Update of another meeting has gone through; with the unlink
// under the lock that Update would never return.
// Mutation: internal/meeting/store.go tombstone, change `os.Rename(dir, tomb)` to `s.unlink(dir)` -> RED (the Update
// times out).
func TestDeleteUnlinksOutsideTheStoreLock(t *testing.T) {
	for name, del := range map[string]func(s *Store, id string) error{
		"Delete":   func(s *Store, id string) error { return s.Delete(id) },
		"DeleteIf": func(s *Store, id string) error { return s.DeleteIf(id, func(Manifest) error { return nil }) },
	} {
		t.Run(name, func(t *testing.T) {
			s := &Store{Root: t.TempDir()}
			gone, goneDir, err := s.Create(Manifest{}, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			other, _, err := s.Create(Manifest{}, time.Now().Add(time.Second))
			if err != nil {
				t.Fatal(err)
			}
			started, release := make(chan string, 2), make(chan struct{})
			s.removeAll = func(path string) error {
				started <- path
				<-release
				return os.RemoveAll(path)
			}
			done := make(chan error, 1)
			go func() { done <- del(s, gone.ID) }()
			tomb := <-started
			if _, err := os.Stat(goneDir); !errors.Is(err, os.ErrNotExist) {
				t.Errorf("the meeting is still in the store while its files are unlinked: %v", err)
			}
			if _, err := os.Stat(tomb); err != nil {
				t.Errorf("the tombstone %s: %v", tomb, err)
			}
			upd := make(chan error, 1)
			go func() { _, err := s.Update(other.ID, func(m *Manifest) { m.Title = "x" }); upd <- err }()
			select {
			case err := <-upd:
				if err != nil {
					t.Errorf("Update of another meeting: %v", err)
				}
			case <-time.After(5 * time.Second):
				t.Error("Update of another meeting waited for the unlink")
			}
			close(release)
			if err := <-done; err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(tomb); !errors.Is(err, os.ErrNotExist) {
				t.Errorf("the tombstone survived: %v", err)
			}
		})
	}
}

// A tombstone a crash left behind (the daemon died between the rename and the unlink) is not a meeting and is
// removed by the next List.
// Mutation: internal/meeting/store.go List, delete the `s.sweepTombstones(entries)` call -> RED.
func TestAStrayTombstoneIsSweptByList(t *testing.T) {
	s := &Store{Root: t.TempDir()}
	stray := filepath.Join(s.Root, tombstonePrefix+"20261023-150100-aaaaaa-1")
	if err := os.MkdirAll(stray, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stray, ThemPCM), []byte("audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	if list, err := s.List(); err != nil || len(list) != 0 {
		t.Fatalf("List = %v, %v", list, err)
	}
	if _, err := os.Stat(stray); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the stray tombstone survived List: %v", err)
	}
}

// A delete in flight is still unlinking its tombstone when another request lists the store: List leaves a tombstone
// younger than the grace period to the delete that made it, and sweeps the ones a crash left (#262).
// Mutation: internal/meeting/store.go sweepTombstones, delete the `time.Since(born) < tombstoneGrace` check -> RED
// (the fresh tombstone is unlinked under the delete's feet).
func TestListLeavesAFreshTombstoneToItsDelete(t *testing.T) {
	s := &Store{Root: t.TempDir()}
	fresh := filepath.Join(s.Root, tombstonePrefix+"20261023-150100-aaaaaa-"+strconv.FormatInt(time.Now().UnixNano(), 36))
	if err := os.MkdirAll(fresh, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := s.List(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Fatalf("List swept a tombstone its delete is still unlinking: %v", err)
	}
	// a tombstone born past the grace period is a leftover
	old := filepath.Join(s.Root, tombstonePrefix+"20261023-150100-bbbbbb-"+strconv.FormatInt(time.Now().Add(-2*tombstoneGrace).UnixNano(), 36))
	if err := os.MkdirAll(old, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := s.List(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(old); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the old tombstone survived List: %v", err)
	}
}

// A tombstone that cannot be unlinked is reported once per process, not by every List (#262).
// Mutation: internal/meeting/store.go sweepTombstones, delete the `s.warned.LoadOrStore` check -> RED (three warnings).
func TestAStuckTombstoneIsReportedOnce(t *testing.T) {
	var logs bytes.Buffer
	s := &Store{Root: t.TempDir(), Log: slog.New(slog.NewTextHandler(&logs, nil))}
	s.removeAll = func(string) error { return errors.New("permission denied") }
	if err := os.MkdirAll(filepath.Join(s.Root, tombstonePrefix+"20261023-150100-aaaaaa-1"), 0o700); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		if _, err := s.List(); err != nil {
			t.Fatal(err)
		}
	}
	if got := strings.Count(logs.String(), "cannot unlink a tombstone"); got != 1 {
		t.Fatalf("%d warnings for one stuck tombstone in 3 Lists, want 1:\n%s", got, logs.String())
	}
}

// A tombstone whose name says it was born in the future (the clock was set back after the delete, or the name was
// made on a machine with a fast clock) would be "younger than the grace period" until the clock catches up, so a
// crash leftover could stay for ever. The directory's modification time stands in then: a leftover that was last
// touched long ago is swept, and one touched just now still belongs to a delete in flight and is left alone.
// Mutation: internal/meeting/store.go tombstoneBorn, return `time.Unix(0, ns)` without the `After(time.Now())`
// fallback -> RED (the leftover with the future suffix survives List).
func TestListSweepsATombstoneWithAFutureSuffixByItsMtime(t *testing.T) {
	s := &Store{Root: t.TempDir()}
	future := strconv.FormatInt(time.Now().Add(365*24*time.Hour).UnixNano(), 36)
	leftover := filepath.Join(s.Root, tombstonePrefix+"20261023-150100-cccccc-"+future)
	inFlight := filepath.Join(s.Root, tombstonePrefix+"20261023-150100-dddddd-"+future)
	for _, dir := range []string{leftover, inFlight} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	long := time.Now().Add(-2 * tombstoneGrace)
	if err := os.Chtimes(leftover, long, long); err != nil {
		t.Fatal(err)
	}
	if _, err := s.List(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(leftover); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("a leftover with a future-dated suffix survived List: %v", err)
	}
	if _, err := os.Stat(inFlight); err != nil {
		t.Errorf("a tombstone touched just now was swept: %v", err)
	}
}
