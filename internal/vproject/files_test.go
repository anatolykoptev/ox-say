package vproject

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ValidKey is the gate between a key read from disk and a path it names.
// Mutation: loosen keyRe to allow "/" or ".." -> RED.
func TestValidKey(t *testing.T) {
	good := strings.Repeat("a0", 12)
	if !ValidKey(good) {
		t.Fatal("a producer key was refused")
	}
	for _, k := range []string{"", good + "0", good[:22], strings.ToUpper(good), "../" + good[3:], good[:23] + "/", good[:23] + "\n"} {
		if ValidKey(k) {
			t.Errorf("%q accepted", k)
		}
	}
}

func TestWriteAtomic(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "a.json")
	if err := WriteAtomic(p, []byte("one"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := WriteAtomic(p, []byte("two"), 0o600); err != nil {
		t.Fatal(err)
	}
	if raw, _ := os.ReadFile(p); string(raw) != "two" {
		t.Errorf("got %q", raw)
	}
	if st, _ := os.Stat(p); st.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", st.Mode())
	}
	// A rename that fails (target is a non-empty directory) leaves no temp file.
	d := filepath.Join(dir, "d")
	if err := os.MkdirAll(filepath.Join(d, "x"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := WriteAtomic(d, []byte("x"), 0o600); err == nil {
		t.Fatal("wrote over a directory")
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.Contains(e.Name(), TempMark) {
			t.Errorf("temp left behind: %s", e.Name())
		}
	}
}

// The file is fsynced BEFORE the rename (a crash after the rename must not
// leave a manifest or take sidecar of zero length) and the directory AFTER it
// (so the rename itself survives). A sync failure fails the write, names the
// path and leaves the old file and no temp file (#149.1).
// Mutation: files.go WriteAtomic, delete the syncFile call -> RED.
// Mutation: files.go WriteAtomic, move syncFile after os.Rename -> RED.
// Mutation: files.go WriteAtomic, delete the syncDir call -> RED.
func TestWriteAtomicSyncsFileBeforeAndDirAfterRename(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "a.json")
	if err := os.WriteFile(p, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	var events []string
	origFile, origDir := syncFile, syncDir
	t.Cleanup(func() { syncFile, syncDir = origFile, origDir })
	syncFile = func(f *os.File) error {
		raw, _ := os.ReadFile(f.Name())
		cur, _ := os.ReadFile(p)
		events = append(events, "file:"+string(raw)+"/target:"+string(cur))
		return nil
	}
	syncDir = func(d string) error {
		cur, _ := os.ReadFile(p)
		events = append(events, "dir:"+d+"/target:"+string(cur))
		return nil
	}
	if err := WriteAtomic(p, []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	want := []string{"file:new/target:old", "dir:" + dir + "/target:new"}
	if strings.Join(events, "|") != strings.Join(want, "|") {
		t.Fatalf("durability order\n got %v\nwant %v", events, want)
	}

	syncFile = func(*os.File) error { return errors.New("disk on fire") }
	err := WriteAtomic(p, []byte("newer"), 0o600)
	if err == nil || !strings.Contains(err.Error(), p) {
		t.Fatalf("a failed fsync must fail the write and name the path: %v", err)
	}
	if raw, _ := os.ReadFile(p); string(raw) != "new" {
		t.Errorf("a failed write replaced the file: %q", raw)
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.Contains(e.Name(), TempMark) {
			t.Errorf("temp left behind: %s", e.Name())
		}
	}
}

// Every WriteAtomic error names the full path it was writing.
// Mutation: files.go WriteAtomic, the CreateTemp error returned bare -> RED.
func TestWriteAtomicErrorsNameThePath(t *testing.T) {
	p := filepath.Join(t.TempDir(), "missing", "a.json")
	if err := WriteAtomic(p, []byte("x"), 0o600); err == nil || !strings.Contains(err.Error(), p) {
		t.Fatalf("error does not name %s: %v", p, err)
	}
}
