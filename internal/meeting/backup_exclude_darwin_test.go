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
