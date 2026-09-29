package voices

import (
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// T6 — voice names are file names: anything outside ^[a-z0-9][a-z0-9_-]{0,31}$
// must be rejected before the filesystem is touched.
// Mutation: make ValidateName return nil unconditionally -> RED.
func TestVoiceNameValidation(t *testing.T) {
	dir := t.TempDir()
	s, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}
	src := testutil.WriteTinyWAV(t, dir, "src.wav")
	bad := []string{"../x", "A", "a/b", "", strings.Repeat("a", 33), "-lead", "has space", "dot.wav"}
	for _, name := range bad {
		if _, err := s.Add(name, src, ""); err == nil {
			t.Fatalf("Add(%q): expected rejection, got nil error", name)
		}
		if _, err := s.Get(name); err == nil {
			t.Fatalf("Get(%q): expected rejection, got nil error", name)
		}
		if err := s.Remove(name); err == nil {
			t.Fatalf("Remove(%q): expected rejection, got nil error", name)
		}
	}
	// Nothing may have been written.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if e.Name() != "src.wav" {
			t.Fatalf("unexpected file created for rejected name: %s", e.Name())
		}
	}
}

func TestAddListRemove(t *testing.T) {
	dir := t.TempDir()
	s, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}
	src := testutil.WriteTinyWAV(t, dir, "src.wav")

	v, err := s.Add("ben", src, "hello there")
	if err != nil {
		t.Fatal(err)
	}
	if v.Name != "ben" || v.RefText != "hello there" {
		t.Fatalf("voice = %+v", v)
	}
	if _, err := os.Stat(s.WAVPath("ben")); err != nil {
		t.Fatalf("normalized wav missing: %v", err)
	}
	list, err := s.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].Name != "ben" {
		t.Fatalf("list = %+v", list)
	}
	if err := s.Remove("ben"); err != nil {
		t.Fatal(err)
	}
	if err := s.Remove("ben"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second remove: %v, want ErrNotFound", err)
	}
}
