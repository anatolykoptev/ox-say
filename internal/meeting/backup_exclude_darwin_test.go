//go:build darwin

package meeting

import (
	"bytes"
	"errors"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

// The real mark: written on a real directory and read back through the same extended attribute Time Machine reads.
// Mutation: backup_exclude_darwin.go, change backupExcludeAttr's name in the Setxattr call -> RED.
func TestExcludeFromBackupWritesTheAttributeOnARealDirectory(t *testing.T) {
	dir := t.TempDir()
	if err := excludeFromBackup(dir); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, 128)
	n, err := unix.Getxattr(dir, backupExcludeAttr, got)
	if err != nil {
		t.Fatalf("attribute not written: %v", err)
	}
	if !bytes.Equal(got[:n], backupExcludeValue) {
		t.Fatalf("attribute value % x, want % x", got[:n], backupExcludeValue)
	}
}

// The wiring, with no seam: the real work directory carries the mark, and the meetings root, the meeting directory
// and the manifest (what the user keeps) do not.
// Mutation: backup_exclude.go MakeWorkDir, `excludeBackup(work)` -> `error(nil)` -> RED (work dir "attribute not found");
// store.go Create, add `excludeFromBackup(s.Root)` after the MkdirAll -> RED (the root is marked).
func TestARealWorkDirIsExcludedAndTheRestOfTheMeetingIsNot(t *testing.T) {
	s := newStore(t)
	_, dir, err := s.Create(Manifest{Title: "x"}, t0)
	if err != nil {
		t.Fatal(err)
	}
	work, err := MakeWorkDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	has := func(p string) bool {
		_, err := unix.Getxattr(p, backupExcludeAttr, make([]byte, 128))
		if err != nil && !errors.Is(err, unix.ENOATTR) {
			t.Fatalf("Getxattr %s: %v", p, err)
		}
		return err == nil
	}
	if !has(work) {
		t.Errorf("work directory not marked excluded from backup")
	}
	for name, p := range map[string]string{"meetings root": s.Root, "meeting directory": dir, "manifest": filepath.Join(dir, ManifestFile)} {
		if has(p) {
			t.Errorf("%s is excluded from backup: the transcript and notes under it must stay in the user's backup", name)
		}
	}
}
