package voices

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
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
		if _, err := s.Add(context.Background(), name, src, ""); err == nil {
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

	v, err := s.Add(context.Background(), "ben", src, "hello there")
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

// A missing ffmpeg binary (or any other daemon-side failure) is NOT caller
// input: it must not surface as *InputError — the HTTP layer maps those to
// 500, and only *InputError earns a 400.
// Mutation: return *InputError for exec failures -> RED.
func TestAddFFmpegMissingIsNotInputError(t *testing.T) {
	dir := t.TempDir()
	s, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}
	s.ffmpeg = "definitely-not-ffmpeg-oxsay"
	src := testutil.WriteTinyWAV(t, dir, "src.wav")
	_, err = s.Add(context.Background(), "ben", src, "")
	if err == nil {
		t.Fatal("Add succeeded with a nonexistent ffmpeg")
	}
	var iErr *InputError
	if errors.As(err, &iErr) {
		t.Fatalf("missing ffmpeg classified as input error: %v", err)
	}
	// Bad clips ffmpeg CAN decode-refuse are still input errors.
	s.ffmpeg = "ffmpeg"
	garbage := testutil.WriteTinyWAV(t, dir, "ok.wav")
	if err := os.WriteFile(garbage, []byte("not audio at all"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Add(context.Background(), "ben", garbage, ""); err == nil {
		t.Fatal("undecodable clip accepted")
	} else if !errors.As(err, &iErr) {
		t.Fatalf("undecodable clip error = %v, want *InputError", err)
	}
}

// Re-adding an existing voice whose metadata write fails (disk full) must
// leave the old voice intact: its clip and metadata still there.
// Mutation: in Pending.Commit, restore the pre-fix order (rename the clip
// into place, then write the metadata, removing the clip if that fails) -> RED.
func TestReAddWithFailedMetadataKeepsVoice(t *testing.T) {
	dir := t.TempDir()
	s, err := New(filepath.Join(dir, "voices"))
	if err != nil {
		t.Fatal(err)
	}
	src := testutil.WriteTinyWAV(t, dir, "a.wav")
	if _, err := s.Add(context.Background(), "ben", src, "first"); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(s.WAVPath("ben"))
	if err != nil {
		t.Fatal(err)
	}
	s.writeFile = func(string, []byte, os.FileMode) error { return errors.New("disk full") }
	// a different clip, so a replaced clip shows up as changed bytes
	other := testutil.WriteTinyWAV(t, dir, "b.wav")
	raw, err := os.ReadFile(other)
	if err != nil {
		t.Fatal(err)
	}
	for i := 44; i < len(raw); i += 2 {
		raw[i] ^= 0x55
	}
	if err := os.WriteFile(other, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Add(context.Background(), "ben", other, "second"); err == nil {
		t.Fatal("re-add with a failing metadata write succeeded")
	}
	v, err := s.Get("ben")
	if err != nil || v.RefText != "first" {
		t.Fatalf("old voice metadata lost: %v %+v", err, v)
	}
	after, err := os.ReadFile(s.WAVPath("ben"))
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("old voice clip changed or lost: %v", err)
	}
}

// Leftovers of a daemon killed mid-normalization are removed by SweepTemp.
func TestSweepTemp(t *testing.T) {
	dir := t.TempDir()
	s, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}
	left := filepath.Join(dir, ".normalize-ben-123.wav")
	if err := os.WriteFile(left, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := s.SweepTemp(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(left); !os.IsNotExist(err) {
		t.Fatalf("leftover still present: %v", err)
	}
}
