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

// A reference whose tail words also occur earlier in the clip must still end
// where the audio ends: the repeated words are not an anchor.
// Mutation: internal/voices/tail.go tailAnchored — search the last anchorWindow
// heard words for an in-order hit (the old loop) instead of aligning the tail
// -> RED for "tail words repeat earlier, ending cut".
func TestTailAnchoredRepeatedTail(t *testing.T) {
	ref := "alpha beta gamma delta alpha beta gamma"
	for name, tc := range map[string]struct {
		heard string
		want  bool
	}{
		"tail words repeat earlier, ending cut": {"alpha beta gamma delta", false},
		"cut two words short":                   {"alpha beta gamma delta alpha", false},
		"whole clip":                            {"alpha beta gamma delta alpha beta gamma", true},
		"last word dropped by the recognizer":   {"alpha beta gamma delta alpha beta", true},
		"slip in the middle of the anchor":      {"alpha beta gamma delta alpha betta gamma", true},
	} {
		if got := tailAnchored(normWords(ref), normWords(tc.heard)); got != tc.want {
			t.Errorf("%s: tailAnchored = %v, want %v", name, got, tc.want)
		}
	}
}

// The extra words after a matched tail may be the words that FOLLOW an earlier
// occurrence of that phrase in the reference: the real ending was cut off.
// Mutation: internal/voices/tail.go tailAnchoredWithin — drop the
// repeatsEarlier call (accept on `f[n][m-e] <= budget` alone) -> RED.
func TestTailAnchoredRepeatEarlier(t *testing.T) {
	pre := "p0 p1 p2 p3 p4 p5 p6 p7 "
	for name, tc := range map[string]struct {
		ref, heard string
		want       bool
	}{
		"5-word repeat, stops after and":    {pre + "we went to the store today and we went to the store today", pre + "we went to the store today and", false},
		"5-word repeat, stops after and we": {pre + "we went to the store today and we went to the store today", pre + "we went to the store today and we", false},
		"6-word repeat, stops after and":    {pre + "then we went to the store today and then we went to the store today", pre + "then we went to the store today and", false},
		"5-word repeat, whole clip":         {pre + "we went to the store today and we went to the store today", pre + "we went to the store today and we went to the store today", true},
		"whole clip with a trailing thanks": {pre + "we went to the store today and we went to the store today", pre + "we went to the store today and we went to the store today thanks", true},
		"fillers inside the tail are free":  {pre + "we went to the store today", pre + "we went um to the uh store today", true},
		"a content slip beyond the budget":  {pre + "we go to see her now", pre + "we go too sea her now", false},
	} {
		if got := tailAnchored(normWords(tc.ref), normWords(tc.heard)); got != tc.want {
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
