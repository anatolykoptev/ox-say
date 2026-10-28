package voices

import (
	"encoding/json"
	"os"
	"testing"
)

// Synthetic at-cap voices (testdata/transcript_tails.json): ref_text as
// stored and the transcript the STT heard for the same clip, built to the
// overrun counts measured on real references (35, 48, 11, 6 and 4 ref words
// past the audio; the last three score 0.84-0.9 on the overall word ratio).
// The first five run past their audio and bleed the tail into every request;
// the rest are correct.
// Mutation: internal/voices/repair.go plan — call TextsMatch instead of
// TranscriptMatches (the overall ratio) -> RED for capped-overrun-11,
// capped-overrun-6 and capped-overrun-4.
func TestTranscriptMatchesTails(t *testing.T) {
	raw, err := os.ReadFile("testdata/transcript_tails.json")
	if err != nil {
		t.Fatal(err)
	}
	var voices []struct {
		Name    string `json:"name"`
		RefText string `json:"ref_text"`
		Stt     string `json:"stt"`
	}
	if err := json.Unmarshal(raw, &voices); err != nil {
		t.Fatal(err)
	}
	healthy := map[string]bool{"fast-reader-healthy": true, "healthy-1": true, "healthy-ru": true}
	if len(voices) != 8 {
		t.Fatalf("fixture has %d voices, want 8", len(voices))
	}
	for _, v := range voices {
		t.Run(v.Name, func(t *testing.T) {
			if got := TranscriptMatches(v.RefText, v.Stt); got != healthy[v.Name] {
				t.Fatalf("TranscriptMatches = %v, want %v (ref %d words, heard %d)",
					got, healthy[v.Name], len(normWords(v.RefText)), len(normWords(v.Stt)))
			}
		})
	}
}

func TestTailAnchoredTolerance(t *testing.T) {
	ref := "alpha beta gamma delta epsilon zeta"
	for name, tc := range map[string]struct {
		heard string
		want  bool
	}{
		"exact":                   {"alpha beta gamma delta epsilon zeta", true},
		"one ASR slip in the end": {"alpha beta gamma delta epsilon zetta", true},
		"last word dropped":       {"alpha beta gamma delta epsilon", true},
		"two end words wrong":     {"alpha beta gamma delta epsxx zexx", false},
		"text runs past audio":    {"alpha beta gamma", false},
	} {
		if got := tailAnchored(normWords(ref), normWords(tc.heard)); got != tc.want {
			t.Errorf("%s: tailAnchored = %v, want %v", name, got, tc.want)
		}
	}
}

// SameWord forgives a spelling slip, not a different word.
// Mutation: tail.go SameWord tolerance n/5 -> n/2 -> "тридцать"/"двадцать" and
// "слон"/"стол" read as the same word -> RED.
func TestSameWordRejectsDifferentWords(t *testing.T) {
	for _, c := range [][2]string{
		{"тридцать", "двадцать"}, {"слон", "стол"}, {"кот", "код"}, {"три", "два"},
	} {
		if SameWord(c[0], c[1]) {
			t.Errorf("SameWord(%q, %q) = true", c[0], c[1])
		}
	}
	for _, c := range [][2]string{{"сохранить", "сохранит"}, {"видео", "видео"}} {
		if !SameWord(c[0], c[1]) {
			t.Errorf("SameWord(%q, %q) = false", c[0], c[1])
		}
	}
}
