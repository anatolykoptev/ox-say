package voices

import (
	"encoding/json"
	"os"
	"testing"
)

// The real at-cap voices of the old Mac (ref_text as stored, stt as the
// resident parakeet heard the same WAV) and the verdict each must get. The
// first four run past their audio and bleed the tail into every request;
// the rest are correct.
// Mutation: internal/voices/repair.go plan — call TextsMatch instead of
// TranscriptMatches (the overall ratio) -> RED for en-deniro, en-william,
// en-daniel.
func TestTranscriptMatchesRealVoices(t *testing.T) {
	raw, err := os.ReadFile("testdata/real_voices.json")
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
	healthy := map[string]bool{"en-emma": true, "en-freeman": true, "ru-fleurs-f": true}
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
