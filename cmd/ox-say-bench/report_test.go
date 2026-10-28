package main

import (
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
