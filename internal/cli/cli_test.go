package cli

import (
	"reflect"
	"testing"
)

// pullFlags must find flags in ANY position: Go's flag package stops at the
// first positional, which made `voice add <name> <audio> --ref-text t` (the
// documented form) unreachable and silently swallowed `say text -v ben` into
// the spoken text.
func TestPullFlags(t *testing.T) {
	cases := []struct {
		name  string
		args  []string
		names []string
		vals  map[string]string
		pos   []string
	}{
		{
			name:  "flags after positionals (documented voice add form)",
			args:  []string{"ben", "./clip.wav", "--ref-text", "hello there"},
			names: []string{"ref-text"},
			vals:  map[string]string{"ref-text": "hello there"},
			pos:   []string{"ben", "./clip.wav"},
		},
		{
			name:  "flags first also work",
			args:  []string{"--ref-text=hi", "ben", "clip.wav"},
			names: []string{"ref-text"},
			vals:  map[string]string{"ref-text": "hi"},
			pos:   []string{"ben", "clip.wav"},
		},
		{
			name:  "say: trailing -v not swallowed into text",
			args:  []string{"hello", "-v", "ben"},
			names: []string{"v"},
			vals:  map[string]string{"v": "ben"},
			pos:   []string{"hello"},
		},
		{
			name:  "double dash ends flag parsing",
			args:  []string{"-v", "ben", "--", "-o", "not-a-flag"},
			names: []string{"v", "o"},
			vals:  map[string]string{"v": "ben"},
			pos:   []string{"-o", "not-a-flag"},
		},
		{
			name:  "unknown dashes stay positional",
			args:  []string{"-1", "degrees"},
			names: []string{"v"},
			vals:  map[string]string{},
			pos:   []string{"-1", "degrees"},
		},
		{
			name:  "single-dash equals form",
			args:  []string{"-f=mp3", "hi"},
			names: []string{"f"},
			vals:  map[string]string{"f": "mp3"},
			pos:   []string{"hi"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			vals, pos, err := pullFlags(tc.args, tc.names...)
			if err != nil {
				t.Fatalf("pullFlags: %v", err)
			}
			if !reflect.DeepEqual(vals, tc.vals) {
				t.Fatalf("vals = %v, want %v", vals, tc.vals)
			}
			if !reflect.DeepEqual(pos, tc.pos) {
				t.Fatalf("pos = %v, want %v", pos, tc.pos)
			}
		})
	}
}

func TestPullFlagsMissingValue(t *testing.T) {
	if _, _, err := pullFlags([]string{"hi", "-v"}, "v"); err == nil {
		t.Fatal("expected error for a flag with no value")
	}
}
