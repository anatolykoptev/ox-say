package vproject

import (
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
