package meeting

import (
	"strings"
	"testing"
)

// A name in two grammatical forms is one name, and two names that merely start alike are two (#235). The forms are
// the Russian case endings of one stem (see inflectedForms); Latin names, which do not inflect, match exactly.
// The pairs are run through MergeChunks: two decisions that differ only by the name must stay two lines unless the
// name is one person's.
// Mutation: internal/meeting/notes.go sameWordForm, replace the `if (ka == bridgeAY && kb == bareStem) || ...` condition with `false`,
// i.e. let the -а/-я ending bridge to the bare word again -> RED (Александр/Александра and the other three).
// Mutation: internal/meeting/notes.go sameWordForm, replace its body with the length rule `short := min(len(ra), len(rb));
// if short < 5 { return false }; common := 0; for common < short && ra[common] == rb[common] { common++ };
// return common >= short-1` (kept in oldLengthRule below) -> RED (Мария/Марина and the rest are merged).
func TestMergeNamesAreOneOnlyWhenOnePersonsForms(t *testing.T) {
	line := func(name string) string {
		return "Pay " + name + " 500 dollars for the shoot in the studio tomorrow morning"
	}
	merged := func(a, b string) bool {
		got := mergeLines(t, ChunkNotes{Decisions: []string{line(a)}}, ChunkNotes{Decisions: []string{line(b)}}).Decisions
		return len(got) == 1
	}
	for _, p := range [][2]string{
		{"Андрей", "Андрею"}, {"Андрею", "Андрея"}, {"Сергей", "Сергею"}, {"Мария", "Марии"},
		{"Иван", "Ивану"}, {"Игорь", "Игорю"}, {"Игорь", "Игоря"}, {"Ольга", "Ольге"}, {"Андрей", "андрей"},
	} {
		if !merged(p[0], p[1]) {
			t.Errorf("%s and %s are one person and stayed two lines", p[0], p[1])
		}
	}
	for _, p := range [][2]string{
		{"Мария", "Марина"}, {"Сергей", "Сергеев"}, {"Ивана", "Иванов"}, {"Maria", "Mario"}, {"Julia", "Julio"},
		{"Daniel", "Daniela"}, {"Robert", "Roberta"}, {"Kristin", "Kristina"}, {"Andrew", "Andrews"},
		{"Виктор", "Виктория"}, {"Никита", "Никитин"}, {"Ann", "Anna"}, {"Alexander", "Alexandra"}, {"Андрей", "Антон"},
		// -а/-я against the bare word: a man's genitive or a woman's nominative, so two people in one meeting
		{"Александр", "Александра"}, {"Евгений", "Евгения"}, {"Валерий", "Валерия"}, {"Иван", "Ивана"}, {"Андрей", "Андрея"},
		{"Анна", "Анне"}, // under four letters of stem: not folded, a miss only costs a duplicate line
	} {
		if merged(p[0], p[1]) {
			t.Errorf("%s and %s are two people and were merged", p[0], p[1])
		}
	}
}

// oldLengthRule is the rule sameWordForm had first, kept for the mutation above.
func oldLengthRule(a, b string) bool {
	if strings.EqualFold(a, b) {
		return true
	}
	ra, rb := []rune(strings.ToLower(a)), []rune(strings.ToLower(b))
	short := min(len(ra), len(rb))
	if short < 5 {
		return false
	}
	common := 0
	for common < short && ra[common] == rb[common] {
		common++
	}
	return common >= short-1
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
