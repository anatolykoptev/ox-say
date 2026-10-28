package meeting

import (
	"strings"
	"testing"
)

// A name in two grammatical forms is one name: "Андрей" and "Андрею" must not keep two copies of one decision apart
// (#235). Names that differ, or differ by one letter, still do: the stem rule is for words of five letters or more.
// Mutation: internal/meeting/notes.go namesMissing, replace the `sameWordForm(w, h)` test in the loop over the
// other line's words with `strings.EqualFold(w, h)` -> RED (the inflected pair stays two lines).
func TestMergeTreatsAnInflectedNameAsTheSameName(t *testing.T) {
	merged := []struct{ a, b string }{
		{"Передать финальный план съёмки Андрею завтра до обеда в студии", "Передать финальный план съёмки Андрей завтра до обеда в студии"},
		{"Андрею передали финальный план съёмки завтра до обеда в студии", "Андрей получил финальный план съёмки завтра до обеда в студии"},
	}
	for _, tc := range merged {
		got := mergeLines(t, ChunkNotes{Decisions: []string{tc.a}}, ChunkNotes{Decisions: []string{tc.b}}).Decisions
		if len(got) != 1 {
			t.Errorf("%q and %q stayed %d lines: %q", tc.a, tc.b, len(got), got)
		}
	}
	apart := []struct{ a, b string }{
		{"Pay Ann 500 dollars for the shoot in the studio tomorrow", "Pay Anna 500 dollars for the shoot in the studio tomorrow"},
		{"Pay Alexander 500 dollars for the shoot in the studio tomorrow", "Pay Alexandra 500 dollars for the shoot in the studio tomorrow"},
		{"Передать финальный план съёмки Андрею завтра до обеда в студии", "Передать финальный план съёмки Антону завтра до обеда в студии"},
	}
	for _, tc := range apart {
		got := mergeLines(t, ChunkNotes{Decisions: []string{tc.a}}, ChunkNotes{Decisions: []string{tc.b}}).Decisions
		if len(got) != 2 {
			t.Errorf("%q and %q were merged: %q", tc.a, tc.b, got)
		}
	}
}

func TestSameWordForm(t *testing.T) {
	for _, tc := range []struct {
		a, b string
		want bool
	}{
		{"андрей", "андрею", true}, {"андрей", "андрея", true}, {"Andrew", "Andrew", true},
		{"ann", "anna", false}, {"анне", "анна", false}, {"alexander", "alexandra", false},
		{"boris", "bobby", false}, {"андрей", "андрюша", false},
	} {
		if got := sameWordForm(tc.a, tc.b); got != tc.want {
			t.Errorf("sameWordForm(%q, %q) = %v, want %v", tc.a, tc.b, got, tc.want)
		}
	}
}

// A model string that holds something link-shaped loses the link, not the text around it (#235): the target of a
// real link (a URL, a path, an anchor) goes, and a bracket pair followed by a parenthesis that is not a target
// ("x[i](y)") keeps every character, written so that it cannot form a link.
// Mutation: internal/meeting/notes_render.go cleanLine, replace the linkTarget.ReplaceAllStringFunc call with
// `s = strings.ReplaceAll(s, "](", "]")` -> RED (the second case loses "(y)").
func TestCleanLineKeepsBracketsThatAreNotALink(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"see [the doc](http://example.invalid/x) now", `see [the doc] now`},
		{"see [the doc](/etc/passwd) now", `see [the doc] now`},
		{"see [top](#top) now", `see [top] now`},
		{"call [me](mailto:a@example.invalid) now", `call [me] now`},
		{"use x[i](y) here", `use x[i]\(y) here`},
		{"the file[1](copy) is there", `the file[1]\(copy) is there`},
	} {
		got := cleanLine(tc.in)
		if got != tc.want {
			t.Errorf("cleanLine(%q) = %q, want %q", tc.in, got, tc.want)
		}
		if strings.Contains(got, "](") {
			t.Errorf("cleanLine(%q) = %q still has a link opener", tc.in, got)
		}
	}
}
