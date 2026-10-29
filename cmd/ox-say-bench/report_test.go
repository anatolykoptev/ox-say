package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The environment note lands in a committed report. An OX_SAY_* variable can
// carry a URL with userinfo (OX_SAY_GET_URL) or a path with a user name, so only
// its name may be printed; GGML_* tuning values are what the note exists to show.
func TestEnvNoteHidesOxSayValues(t *testing.T) {
	var r report
	r.envNoteFrom([]string{
		"PATH=/usr/bin",
		"OX_SAY_GET_URL=https://user:s3cret@example.com/x",
		"OX_SAY_JOBS=4",
		"GGML_METAL_N_CB=2",
	})
	if len(r.notes) != 1 {
		t.Fatalf("notes = %q, want exactly one", r.notes)
	}
	n := r.notes[0]
	for _, leak := range []string{"s3cret", "user:", "https://", "JOBS=4"} {
		if strings.Contains(n, leak) {
			t.Errorf("note leaks %q: %s", leak, n)
		}
	}
	for _, want := range []string{"OX_SAY_GET_URL", "OX_SAY_JOBS", "GGML_METAL_N_CB=2"} {
		if !strings.Contains(n, want) {
			t.Errorf("note lacks %q: %s", want, n)
		}
	}
	if strings.Contains(n, "PATH") {
		t.Errorf("note lists an unrelated variable: %s", n)
	}
}

func TestEnvNoteNoneSet(t *testing.T) {
	var r report
	r.envNoteFrom([]string{"PATH=/usr/bin"})
	if len(r.notes) != 1 || !strings.Contains(r.notes[0], "no GGML_* or OX_SAY_* variables set") {
		t.Fatalf("notes = %q", r.notes)
	}
}

// #115: the single-run footnote names the number of runs, not the flag.
// Mutation: report.go markdown, print "-runs" again instead of r.runs -> RED.
func TestSingleRunFootnoteNamesTheCount(t *testing.T) {
	r := report{runs: 5}
	r.single("x")
	md := r.markdown()
	if !strings.Contains(md, "median of 5 warm runs") || strings.Contains(md, "-runs") {
		t.Fatalf("footnote: %s", md)
	}
}

// #115: an Intel Mac has no performance levels; the line gives the plain core
// count instead of "8 performance +  efficiency".
// Mutation: report.go coresLine, drop the perflevel0 check -> RED.
func TestCoresLineOnIntel(t *testing.T) {
	intel := func(name string, args ...string) string {
		if strings.Contains(strings.Join(args, " "), "perflevel") {
			return "?"
		}
		return "8"
	}
	if got := coresLine(intel); got != "Cores: 8" {
		t.Fatalf("Intel: %q", got)
	}
	arm := func(name string, args ...string) string {
		switch {
		case strings.Contains(strings.Join(args, " "), "perflevel0"):
			return "4"
		case strings.Contains(strings.Join(args, " "), "perflevel1"):
			return "6"
		}
		return "10"
	}
	if got := coresLine(arm); got != "Cores: 4 performance + 6 efficiency" {
		t.Fatalf("Apple Silicon: %q", got)
	}
}

// #115: the pins come from a stamp next to the binaries (engine/build.sh writes
// out/pins.env), not from whatever checkout the bench happens to run in. With
// no stamp the report says so; it never prints the checkout's pins as if they
// were the binaries'.
// Mutation: report.go pinsFrom, read filepath.Join("engine", "pins.env") again
// -> RED on both cases (it finds the checkout's file, here a different cwd).
func TestPinsComeFromTheStampNextToTheBinaries(t *testing.T) {
	t.Chdir(t.TempDir())
	if err := os.MkdirAll("engine", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join("engine", "pins.env"), []byte("QWENTTS_COMMIT=ccccccccccccccc\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out := t.TempDir()
	if got := pinsFrom(out); strings.Contains(got, "ccccccc") || !strings.Contains(got, "no pins.env") {
		t.Fatalf("no stamp: %q, want a plain statement that there is none", got)
	}
	stamp := "QWENTTS_REPO=https://example.invalid/x\nQWENTTS_COMMIT=aaaaaaaaaaaaaaa\nWHISPER_COMMIT=bbbbbbbbbbbbbbb\n"
	if err := os.WriteFile(filepath.Join(out, "pins.env"), []byte(stamp), 0o644); err != nil {
		t.Fatal(err)
	}
	got := pinsFrom(out)
	if got != "QWENTTS_COMMIT=aaaaaaa, WHISPER_COMMIT=bbbbbbb" {
		t.Fatalf("stamp: %q", got)
	}
}
