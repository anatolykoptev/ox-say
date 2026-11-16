//go:build darwin

package meeting

import (
	"bytes"
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

// The wiring, with no seam: a real Store marks its real root on Create. This is what the daemon runs.
// Mutation: store.go ensureRoot, `mark = excludeFromBackup` -> `mark = func(string) error { return nil }` -> RED.
func TestAStoreCreateMarksItsRealRootExcluded(t *testing.T) {
	s := newStore(t)
	if _, _, err := s.Create(Manifest{Title: "x"}, t0); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, 128)
	n, err := unix.Getxattr(s.Root, backupExcludeAttr, got)
	if err != nil {
		t.Fatalf("meetings root not marked excluded from backup: %v", err)
	}
	if !bytes.Equal(got[:n], backupExcludeValue) {
		t.Fatalf("attribute value % x", got[:n])
	}
}
