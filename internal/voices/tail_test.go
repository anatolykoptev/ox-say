package voices

import (
	"encoding/json"
	"os"
	"strings"
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

// The verdict cache key carries a fingerprint of SameWord over fixed pairs (#280.2). The expected verdicts are
// written out here, independent of SameWord: a change of SameWord for any pair fails its row (so the change is
// seen), and the fingerprint over those expected verdicts must equal the one the key uses (so the key moves with it).
// "then"/"than" are one edit apart at four letters: SameWord calls them the same word on purpose. The tail check
// asks whether the words the reference ends in are in the audio; an ASR that heard "than" for "then" heard the
// word, and a reference that ran PAST the audio ends in words that are nowhere near the audio's, so the pair cannot
// hide an overrun (#280.4).
// Mutation: internal/voices/tail.go SameWord `max(1, n/5)` -> `max(1, n/4)` -> RED (the abcdefgh row and the
// fingerprint equality).
func TestSameWordProbes(t *testing.T) {
	want := map[[2]string]bool{
		{"hello", "hello"}: true, {"cat", "cut"}: false, {"then", "than"}: true, {"stol", "slon"}: false,
		{"hello", "hallo"}: true, {"hello", "hxllx"}: false, {"abcdefghij", "abcdefghxx"}: true,
		{"abcdefghij", "abcdefgxxx"}: false, {"abcdefgh", "abcdefxx"}: false, {"сохранит", "сохранить"}: true, {"тридцать", "двадцать"}: false,
	}
	if len(want) != len(sameWordProbes) {
		t.Fatalf("%d expected verdicts for %d probe pairs", len(want), len(sameWordProbes))
	}
	for _, p := range sameWordProbes {
		exp, ok := want[p]
		if !ok {
			t.Fatalf("probe pair %q has no expected verdict here", p)
		}
		if got := SameWord(p[0], p[1]); got != exp {
			t.Errorf("SameWord(%q, %q) = %v, want %v", p[0], p[1], got, exp)
		}
	}
	oracle := func(a, b string) bool { return want[[2]string{a, b}] }
	if got, exp := sameWordFingerprint(SameWord), sameWordFingerprint(oracle); got != exp {
		t.Errorf("fingerprint of SameWord = %s, of the expected verdicts = %s", got, exp)
	}
	// One flipped verdict moves the fingerprint, and the key built from tailParams carries the fingerprint.
	flipped := func(a, b string) bool {
		if a == "then" {
			return !SameWord(a, b)
		}
		return SameWord(a, b)
	}
	if sameWordFingerprint(flipped) == sameWordFingerprint(SameWord) {
		t.Error("flipping one pair's verdict did not change the fingerprint")
	}
	if !strings.Contains(tailParams(), ",sw"+sameWordFingerprint(SameWord)) {
		t.Errorf("tailParams %q does not carry the SameWord fingerprint", tailParams())
	}
}
