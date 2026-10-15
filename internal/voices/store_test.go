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

// An in-flight commit's temporaries never show up as voices: List reads
// only visible *.json files.
// Mutation: drop the dotfile check in List -> RED ("temporary listed").
func TestListSkipsTemporaries(t *testing.T) {
	dir := t.TempDir()
	s, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Add(context.Background(), "ben", testutil.WriteTinyWAV(t, t.TempDir(), "a.wav"), ""); err != nil {
		t.Fatal(err)
	}
	// a metadata temporary as a crashed or in-flight commit would leave it
	meta, err := os.ReadFile(filepath.Join(dir, "ben.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".normalize-ben-1.wav.json"), meta, 0o644); err != nil {
		t.Fatal(err)
	}
	list, err := s.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 {
		t.Fatalf("temporary listed: %d voices, want 1", len(list))
	}
}

func TestUpdateAndMetaRoundTrip(t *testing.T) {
	s, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	clip := testutil.WriteSilentWAV(t, t.TempDir(), "c.wav", 3)
	p, err := s.Prepare(context.Background(), "nar", clip, "")
	if err != nil {
		t.Fatal(err)
	}
	p.SetMeta(Meta{Engine: "voxcpm2", DesignedFrom: "a narrator"})
	if _, err := p.Commit(); err != nil {
		t.Fatal(err)
	}
	v, err := s.Update("nar", func(v *Voice) { v.Style = "slow"; v.Name = "other" })
	if err != nil || v.Engine != "voxcpm2" || v.Style != "slow" || v.DesignedFrom != "a narrator" || v.Name != "nar" {
		t.Fatalf("%+v %v", v, err)
	}
	if _, err := s.Update("nope", func(*Voice) {}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown voice: %v", err)
	}
}

// Re-adding a voice (a new clip under an existing name) keeps its engine and
// style unless the new add sets them, and never keeps designed_from, which
// describes the old audio.
// Mutation: internal/voices/store.go inheritedMeta — return p.meta at the top
// -> RED (the second add resets engine and style).
func TestReAddKeepsEnginePreferences(t *testing.T) {
	s, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	clip := testutil.WriteSilentWAV(t, t.TempDir(), "c.wav", 3)
	add := func(m Meta) *Voice {
		t.Helper()
		p, err := s.Prepare(context.Background(), "nar", clip, "")
		if err != nil {
			t.Fatal(err)
		}
		p.SetMeta(m)
		v, err := p.Commit()
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	add(Meta{Engine: "voxcpm2", Style: "slow", DesignedFrom: "old design"})
	if v := add(Meta{}); v.Engine != "voxcpm2" || v.Style != "slow" || v.DesignedFrom != "" {
		t.Fatalf("re-add without metadata: %+v", v.Meta)
	}
	if got, _ := s.Get("nar"); got.Engine != "voxcpm2" || got.Style != "slow" || got.DesignedFrom != "" {
		t.Fatalf("persisted: %+v", got.Meta)
	}
	if v := add(Meta{Engine: "qwen3-tts", DesignedFrom: "new"}); v.Engine != "qwen3-tts" || v.Style != "slow" || v.DesignedFrom != "new" {
		t.Fatalf("re-add with explicit metadata: %+v", v.Meta)
	}
}

// A voice file written before the metadata fields existed loads unchanged and
// is rewritten byte for byte (no new keys appear).
// Mutation: internal/voices/store.go — drop `omitempty` from Meta.Engine -> RED.
func TestOldVoiceFileRoundTripsByteStable(t *testing.T) {
	s, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	const old = `{"name":"old","ref_text":"hello there","created":"2026-10-04T14:28:00Z"}`
	if err := os.WriteFile(s.metaPath("old"), []byte(old), 0o644); err != nil {
		t.Fatal(err)
	}
	v, err := s.Get("old")
	if err != nil || v.Meta != (Meta{}) || v.RefText != "hello there" {
		t.Fatalf("old file: %+v %v", v, err)
	}
	if _, err := s.Update("old", func(*Voice) {}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(s.metaPath("old"))
	if err != nil || string(got) != old {
		t.Fatalf("rewritten = %s (%v), want %s", got, err, old)
	}
}

// A failed metadata write leaves the voice exactly as it was.
func TestUpdateFailedWriteKeepsVoice(t *testing.T) {
	s, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	clip := testutil.WriteSilentWAV(t, t.TempDir(), "c.wav", 3)
	if _, err := s.Add(context.Background(), "nar", clip, ""); err != nil {
		t.Fatal(err)
	}
	s.writeFile = func(string, []byte, os.FileMode) error { return errors.New("disk full") }
	if _, err := s.Update("nar", func(v *Voice) { v.Style = "x" }); err == nil {
		t.Fatal("Update with a failing write succeeded")
	}
	if v, _ := s.Get("nar"); v.Style != "" {
		t.Fatalf("voice changed despite the failed write: %+v", v)
	}
}
