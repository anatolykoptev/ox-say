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
// seen). The broader generated set is pinned by TestSameWordGeneratedSetIsPinned.
// "then"/"than" are one edit apart at four letters: SameWord calls them the same word on purpose. The tail check
// asks whether the words the reference ends in are in the audio; an ASR that heard "than" for "then" heard the
// word, and a reference that ran PAST the audio ends in words that are nowhere near the audio's, so the pair cannot
// hide an overrun (#280.4).
// Mutation: internal/voices/tail.go SameWord `max(1, n/5)` -> `max(1, n/4)` -> RED (the abcdefgh row and the
// fingerprint tests).
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

// #320.3: the fingerprint in the verdict cache key also covers sameWordGenerated, a machine-built set of word
// pairs over every length and edit count, so a rule change that the eleven hand-picked probes do not show still
// moves the key. The golden below is the fingerprint of today's SameWord over that set: a change of any verdict
// fails this test and says the key moved on purpose (update the golden in the same commit). The variants prove the
// set can see the usual ways the rule might change.
// Mutation: tail.go SameWord `max(1, n/5)` -> `max(1, n/6)` -> RED here (golden). Mutation:
// tail.go sameWordFingerprint, hash only sameWordProbes -> TestSameWordFingerprintCoversGeneratedSet RED.
func TestSameWordGeneratedSetIsPinned(t *testing.T) {
	const golden = "9c08ee45"
	if n := len(sameWordGenerated()); n < 300 {
		t.Fatalf("generated set shrank to %d pairs", n)
	}
	if got := sameWordFingerprint(SameWord); got != golden {
		t.Errorf("SameWord changed a verdict on the generated set: fingerprint %s, pinned %s", got, golden)
	}
}

func TestSameWordFingerprintCoversGeneratedSet(t *testing.T) {
	base := sameWordFingerprint(SameWord)
	variants := map[string]func(a, b string) bool{
		"tolerance n/4":    func(a, b string) bool { return sameWithRule(a, b, 4, 4, 1) },
		"tolerance n/6":    func(a, b string) bool { return sameWithRule(a, b, 4, 6, 1) },
		"no minimum of 1":  func(a, b string) bool { return sameWithRule(a, b, 4, 5, 0) },
		"short limit 3":    func(a, b string) bool { return sameWithRule(a, b, 3, 5, 1) },
		"short limit 5":    func(a, b string) bool { return sameWithRule(a, b, 5, 5, 1) },
		"minimum of 2":     func(a, b string) bool { return sameWithRule(a, b, 4, 5, 2) },
		"equality only":    func(a, b string) bool { return a == b },
		"always different": func(a, b string) bool { return false },
	}
	for name, same := range variants {
		if sameWordFingerprint(same) == base {
			t.Errorf("variant %q leaves the fingerprint unchanged: the generated set does not see it", name)
		}
	}
	// A change visible ONLY on a generated pair (agreeing with SameWord on every hand-picked probe) must move the key.
	probe := map[[2]string]bool{}
	for _, p := range sameWordProbes {
		probe[p] = true
	}
	var target [2]string
	for _, p := range sameWordGenerated() {
		if !probe[p] {
			target = p
			break
		}
	}
	generatedOnly := func(a, b string) bool {
		if [2]string{a, b} == target {
			return !SameWord(a, b)
		}
		return SameWord(a, b)
	}
	if sameWordFingerprint(generatedOnly) == base {
		t.Error("a verdict change on a generated-only pair leaves the fingerprint unchanged")
	}
	// And each variant differs from SameWord on a pair of the generated set itself, not only on a probe.
	for name, same := range variants {
		diff := false
		for _, p := range sameWordGenerated() {
			if same(p[0], p[1]) != SameWord(p[0], p[1]) {
				diff = true
				break
			}
		}
		if !diff {
			t.Errorf("variant %q agrees with SameWord on every generated pair", name)
		}
	}
}

// sameWithRule is SameWord with its three numbers exposed: the shortest word that may differ, the divisor of the
// tolerance and its floor.
func sameWithRule(a, b string, shortLimit, divisor, floor int) bool {
	if a == b {
		return true
	}
	ra, rb := []rune(a), []rune(b)
	n := max(len(ra), len(rb))
	if n < shortLimit {
		return false
	}
	return editDistance(ra, rb) <= max(floor, n/divisor)
}
