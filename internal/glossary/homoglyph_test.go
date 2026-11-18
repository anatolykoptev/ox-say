package glossary

import (
	"testing"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

var startWithPair = []Pair{{Heard: "startс with", Meant: "startswith", Status: Active, Pack: true}}

// A pack pair's heard form matches a token that mixes Latin letters with Cyrillic ones standing for
// the same sounds — «Startс» for "starts" — and any other mix that transliterates the same, not only
// the spelling on file.
func TestPackPairMatchesMixedScriptToken(t *testing.T) {
	for in, want := range map[string]string{
		"call Startс with care":  "call startswith care",
		"call Stаrts with care":  "call startswith care", // а is Cyrillic
		"call Stаrtс with care":  "call startswith care", // both
		"Startс with the check.": "startswith the check.",
	} {
		if out, _ := Apply(in, startWithPair); out != want {
			t.Errorf("%q -> %q, want %q", in, out, want)
		}
	}
}

// The fold never touches pure-Latin or pure-Cyrillic words — "starts" is not «startс» — and a
// different Cyrillic letter transliterates differently: «Ѕtаrtѕ» reads "ztartz", not "starts".
// Mutation: same() without the mixedScript gate -> RED, the English sentences rewrite to
// "startswith".
func TestPureScriptsBypassHomoglyph(t *testing.T) {
	for _, prose := range []string{
		"the show starts with a bang",
		"the function starts with a check",
		"call Ѕtаrtѕ with care", // dze, not es
		"стартс виз проверку",   // pure Cyrillic: not the alias, stays
	} {
		if out, _ := Apply(prose, startWithPair); out != prose {
			t.Errorf("prose %q rewritten to %q", prose, out)
		}
	}
}

// An owner pair never carries the pack flag: the exact spelling still matches, a different
// script mix does not — owner matching is unchanged.
func TestOwnerPairIsNotLatinized(t *testing.T) {
	owner := []Pair{{Heard: "startс with", Meant: "startswith", Status: Active}}
	if out, _ := Apply("Startс with care", owner); out != "startswith care" {
		t.Errorf("identical spelling must match: %q", out)
	}
	if out, _ := Apply("call Stаrts with care", owner); out != "call Stаrts with care" {
		t.Errorf("owner pair transliterated a mixed token: %q", out)
	}
}

// The word path follows the same gate.
func TestPackPairMixedScriptApplyWords(t *testing.T) {
	ws := []stt.Word{{W: "use"}, {W: " Startс"}, {W: " with"}}
	got := ApplyWords(append([]stt.Word{}, ws...), startWithPair)
	if len(got) != 2 || got[0].W != "use" || got[1].W != " startswith" {
		t.Fatalf("got %+v", got)
	}
	ws = []stt.Word{{W: "it"}, {W: " starts"}, {W: " with"}}
	got = ApplyWords(append([]stt.Word{}, ws...), startWithPair)
	if len(got) != 3 {
		t.Fatalf("pure-Latin prose rewritten: %+v", got)
	}
}

// Text that no alias matched is left byte-identical, mixed script included.
func TestUnmatchedMixedTextUntouched(t *testing.T) {
	in := "the Ѕtаrtѕ button blinks"
	if out, _ := Apply(in, startWithPair); out != in {
		t.Errorf("unmatched mixed text rewritten: %q", out)
	}
}
