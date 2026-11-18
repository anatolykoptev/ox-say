package glossary

import (
	"testing"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

var startWithPair = []Pair{{Heard: "startс with", Meant: "startswith", Status: Active, Pack: true}}
var endWithPair = []Pair{{Heard: "endс with", Meant: "endswith", Status: Active, Pack: true}}
var quargsPair = []Pair{{Heard: "Quargs", Meant: "kwargs", Status: Active, Pack: true}}

// A pack pair's pure-Latin heard form matches a token Parakeet split across the two scripts when
// the Latin letters are the majority — «Quаrgs» for "Quargs" — and the mixed spelling filed in the
// pack still matches literally.
func TestPackPairMatchesMixedScriptToken(t *testing.T) {
	for in, want := range map[string]string{
		"call Startс with care":  "call startswith care", // the filed mixed spelling, verbatim
		"Startс with the check.": "startswith the check.",
		"pass Quаrgs here":       "pass kwargs here", // а is Cyrillic
		"pass Quаrгs here":       "pass kwargs here", // two Cyrillic letters, still a minority
	} {
		if out, _ := Apply(in, append(append([]Pair{}, startWithPair...), quargsPair...)); out != want {
			t.Errorf("%q -> %q, want %q", in, out, want)
		}
	}
}

// The fold runs only while the token's Latin letters outnumber its Cyrillic ones: a token at
// parity or mostly Cyrillic is Russian text, not a broken identifier.
// Mutation: foldable drops `lat > cyr` -> RED («Qуаrгs» latinizes to "quargs" and rewrites).
func TestPackPairFoldNeedsLatinMajority(t *testing.T) {
	pairs := append(append([]Pair{}, quargsPair...),
		Pair{Heard: "replace", Meant: "putBack", Status: Active, Pack: true})
	for _, prose := range []string{
		"pass Qуаrгs here",  // 3 Latin against 3 Cyrillic — parity is no majority; it latinizes to "quargs"
		"the rёплейс flag",  // one Latin letter: Russian text with a stray r, folds to "repleys" — never "replace"
		"call Quaргс to it", // parity too — it latinizes to "quargs" and would rewrite without the gate
	} {
		if out, _ := Apply(prose, pairs); out != prose {
			t.Errorf("prose %q rewritten to %q", prose, out)
		}
	}
}

// The alias being compared must be pure Latin: a Cyrillic or a mixed-script heard word is only
// ever its own spelling, so «Stаrts» never meets «startс» and «Pиn» never meets «пин».
// Mutation: same() drops `!hasCyrillic(h)` -> RED («Stаrts with» folds to «startс with»).
func TestPackPairFoldNeedsLatinAlias(t *testing.T) {
	pairs := append(append(append([]Pair{}, startWithPair...), endWithPair...),
		Pair{Heard: "пин", Meant: "Pin", Status: Active, Pack: true})
	for _, prose := range []string{
		"call Stаrts with care", // the alias word startс holds Cyrillic: no fold either way
		"call Stаrtс with care",
		"call enдs with care", // predominantly Latin, yet the filed alias endс is not
		"a Pиn here",          // predominantly Latin, but пин is Cyrillic
	} {
		if out, _ := Apply(prose, pairs); out != prose {
			t.Errorf("prose %q rewritten to %q", prose, out)
		}
	}
}

// The fold never touches pure-Latin or pure-Cyrillic words — "starts" is not «startс» — and a
// letter outside the Russian map (Ѕ) transliterates to nothing it should not.
func TestPureScriptsBypassHomoglyph(t *testing.T) {
	pairs := append(append([]Pair{}, startWithPair...), quargsPair...)
	for _, prose := range []string{
		"the show starts with a bang",
		"the function starts with a check",
		"the quarks of physics", // near Quargs, never it
		"call Ѕtаrtѕ with care", // dze, not es — not a Russian letter, never transliterated
		"стартс виз проверку",   // pure Cyrillic: not the alias, stays
	} {
		if out, _ := Apply(prose, pairs); out != prose {
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

// A pack pair's heard form is one spelling, not a lemma: an owner pair keeps matching another
// case of its word, a pack pair never does — «стрипа» is not «стрип».
// Mutation: stemsFor drops `p.Pack` -> RED («стрипа» rewrites to strip).
func TestPackPairMatchesExactOnly(t *testing.T) {
	owner := Pair{Heard: "стрип", Meant: "Strip", Status: Active}
	pack := Pair{Heard: "стрип", Meant: "strip", Status: Active, Pack: true}
	if out, _ := Apply("сделай стрипа", []Pair{owner}); out != "сделай Strip" {
		t.Fatalf("owner pair must still match another case: %q", out)
	}
	if out, _ := Apply("сделай стрипа", []Pair{pack}); out != "сделай стрипа" {
		t.Fatalf("pack pair must not match an inflection: %q", out)
	}
	if out, _ := Apply("сделай стрип", []Pair{pack}); out != "сделай strip" {
		t.Fatalf("the exact spelling must still match: %q", out)
	}
}

// The owner pass claims its spans before a pack pair may look — a word an owner correction
// consumed or produced is never offered to the pack pass.
// Mutation: Apply runs the pack pass first, or both classes in one pass -> RED in every case.
func TestOwnerPassClaimsTokensFirst(t *testing.T) {
	// The pack pair sorts first in the input and would fold «Stаrts» to "starts": only the
	// pass order keeps the owner's win.
	owner := Pair{Heard: "Stаrts", Meant: "MyBrand", Status: Active} // а is Cyrillic
	pack := Pair{Heard: "starts with", Meant: "startswith", Status: Active, Pack: true}
	if out, _ := Apply("Stаrts with care", []Pair{pack, owner}); out != "MyBrand with care" {
		t.Errorf("owner must win: %q", out)
	}
	// A span an owner pair claimed is never crossed by a longer pack phrase.
	ownerB := Pair{Heard: "b c", Meant: "X", Status: Active}
	packB := Pair{Heard: "a b c d", Meant: "Y", Status: Active, Pack: true}
	if out, _ := Apply("a b c d", []Pair{packB, ownerB}); out != "a X d" {
		t.Errorf("pack phrase must not cross a claimed span: %q", out)
	}
	// A word the owner produced is not re-matched either.
	ownerC := Pair{Heard: "dunder", Meant: "Quargs", Status: Active}
	if out, _ := Apply("call dunder", []Pair{quargsPair[0], ownerC}); out != "call Quargs" {
		t.Errorf("an owner-produced word must be off limits to the pack pass: %q", out)
	}
}

// The word path follows the same gates: a folded token meets a Latin alias, the owner pass claims
// its words first.
func TestPackPairMixedScriptApplyWords(t *testing.T) {
	ws := []stt.Word{{W: "use"}, {W: " Startс"}, {W: " with"}}
	got := ApplyWords(append([]stt.Word{}, ws...), startWithPair)
	if len(got) != 2 || got[0].W != "use" || got[1].W != " startswith" {
		t.Fatalf("got %+v", got)
	}
	for _, w := range []string{" starts", " Stаrts", " Quаrгс"} {
		ws = []stt.Word{{W: "it"}, {W: w}, {W: " with"}}
		if got := ApplyWords(append([]stt.Word{}, ws...), append(append([]Pair{}, startWithPair...), quargsPair...)); len(got) != 3 {
			t.Fatalf("prose word %q rewritten: %+v", w, got)
		}
	}
	ws = []stt.Word{{W: " Stаrts"}, {W: " with"}, {W: " care"}}
	pairs := []Pair{
		{Heard: "starts with", Meant: "startswith", Status: Active, Pack: true},
		{Heard: "Stаrts", Meant: "MyBrand", Status: Active},
	}
	if got := ApplyWords(append([]stt.Word{}, ws...), pairs); len(got) != 3 || got[0].W != " MyBrand" {
		t.Fatalf("owner word must win in the word path: %+v", got)
	}
}

// Text that no alias matched is left byte-identical, mixed script included.
func TestUnmatchedMixedTextUntouched(t *testing.T) {
	in := "the Ѕtаrtѕ button blinks"
	if out, _ := Apply(in, startWithPair); out != in {
		t.Errorf("unmatched mixed text rewritten: %q", out)
	}
}
