package meeting

import (
	"errors"
	"os"
	"testing"
)

// Creating a meeting marks the meetings directory excluded from backup: the audio is private and is deleted on a
// schedule, so it must not stay on a backup disk. The mark is on the root, which covers every meeting under it.
// Mutation: store.go ensureRoot, delete the `mark(s.Root)` call -> RED.
func TestCreateExcludesTheMeetingsRootFromBackup(t *testing.T) {
	s := newStore(t)
	var marked []string
	s.exclude = func(p string) error { marked = append(marked, p); return nil }
	if _, _, err := s.Create(Manifest{Title: "x"}, t0); err != nil {
		t.Fatal(err)
	}
	if len(marked) != 1 || marked[0] != s.Root {
		t.Fatalf("marked %v, want exactly the root %q", marked, s.Root)
	}
}

// The settings write makes the root too (a first run can set retention before any meeting), and marks it.
// Mutation: retention.go SetSettings, `s.ensureRoot()` -> `os.MkdirAll(s.Root, 0o700)` -> RED.
func TestSetSettingsExcludesTheMeetingsRootFromBackup(t *testing.T) {
	s := newStore(t)
	var marked []string
	s.exclude = func(p string) error { marked = append(marked, p); return nil }
	if err := s.SetSettings(Settings{RetentionDays: DefaultRetention}); err != nil {
		t.Fatal(err)
	}
	if len(marked) != 1 || marked[0] != s.Root {
		t.Fatalf("marked %v, want exactly the root %q", marked, s.Root)
	}
}

// A mark that fails must not stop the recording.
// Mutation: store.go ensureRoot, `return err` after a failed mark -> RED.
func TestAFailedBackupMarkDoesNotRefuseTheMeeting(t *testing.T) {
	s := newStore(t)
	s.exclude = func(string) error { return errors.New("xattr not supported here") }
	if _, dir, err := s.Create(Manifest{Title: "x"}, t0); err != nil {
		t.Fatalf("Create refused the meeting over a failed backup mark: %v", err)
	} else if _, err := os.Stat(dir); err != nil {
		t.Fatal(err)
	}
}

// The mark's bytes are what macOS writes itself (`tmutil addexclusion`): a binary plist with the string
// "com.apple.backupd". A different value is ignored by Time Machine without any error.
func TestBackupExcludeValueIsABinaryPlistOfBackupd(t *testing.T) {
	v := backupExcludeValue
	if string(v[:8]) != "bplist00" {
		t.Fatalf("header %q", v[:8])
	}
	if v[8] != 0x5f || v[9] != 0x10 || int(v[10]) != len("com.apple.backupd") {
		t.Fatalf("string marker % x", v[8:11])
	}
	if got := string(v[11 : 11+len("com.apple.backupd")]); got != "com.apple.backupd" {
		t.Fatalf("string %q", got)
	}
	if len(v) != 61 {
		t.Fatalf("length %d, want 61 (tmutil's)", len(v))
	}
}
