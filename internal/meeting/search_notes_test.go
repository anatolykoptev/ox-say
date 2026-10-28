package meeting

import (
	"strings"
	"testing"
)

func firstNotesSnippet(t *testing.T, notes, q string) string {
	t.Helper()
	hits := notesHits(notes, foldRunes(q), 5)
	if len(hits) != 1 {
		t.Fatalf("%q in %q: %d hits, want 1", q, notes, len(hits))
	}
	return hits[0].Snippet
}

// A notes snippet shows the text the way the reader sees it: no emphasis, code, list, task or quote syntax (#272.3).
// Escapes written by the notes renderer are read back, and a marker the renderer escaped stays a literal character.
// Mutation: internal/meeting/search.go notesHits, stripMarkdown(body.String()) -> unescapeMarkdown(body.String()) -> RED.
func TestNotesSnippetHasNoMarkdownSyntax(t *testing.T) {
	cases := []struct{ name, notes, q, want string }{
		{"bold", "Это **важное** решение\n", "важное", "Это важное решение"},
		{"task box", "- [ ] Анна — отправить смету — пятница\n", "смету", "Анна — отправить смету — пятница"},
		{"done box", "- [x] Done the thing\n", "thing", "Done the thing"},
		{"bullet", "- first point\n* second point\n+ third point\n", "second", "first point second point third point"},
		{"ordered", "1. one\n2) two\n", "two", "one two"},
		{"quote", "> quoted words\n", "quoted", "quoted words"},
		{"italic and code", "_Partial: chunk 2_ and `code`\n", "chunk", "Partial: chunk 2 and code"},
		{"strike", "this ~~old~~ plan\n", "old", "this old plan"},
		{"escaped star stays", `price 5 \* 3 and \[x\]` + "\n", "5 *", "price 5 * 3 and [x]"},
		{"snake_case stays", "see foo_bar_baz now\n", "foo_bar", "see foo_bar_baz now"},
		{"hashtag and date stay", "- #42 fix on 2026-10-20\n", "#42", "#42 fix on 2026-10-20"},
	}
	for _, c := range cases {
		if got := firstNotesSnippet(t, c.notes, c.q); got != c.want {
			t.Errorf("%s: snippet = %q, want %q", c.name, got, c.want)
		}
	}
}

// The window is cut from the stripped text, so a match deep in a text full of markers is still centred and whole, in
// Cyrillic and in Latin (the rune indices, not bytes).
// Mutation: internal/meeting/search.go notesHits, hay := foldRunes(text) -> foldRunes(body.String()) (offsets from
// the text before stripping) -> RED.
func TestNotesSnippetOffsetsFollowTheStrippedText(t *testing.T) {
	for _, c := range []struct{ name, filler, needle string }{
		{"cyrillic", "**щ** ", "ИСКОМОЕ слово"},
		{"latin", "**x** ", "TARGET words"},
	} {
		notes := strings.Repeat(c.filler, 120) + c.needle + strings.Repeat(" "+c.filler, 120)
		got := firstNotesSnippet(t, notes, strings.ToLower(c.needle))
		if strings.Contains(got, "*") {
			t.Errorf("%s: markers left in %q", c.name, got)
		}
		if !strings.Contains(got, c.needle) {
			t.Errorf("%s: the match is not in the window: %q", c.name, got)
		}
		i := strings.Index(got, c.needle)
		if i < 0 {
			continue
		}
		before := len([]rune(got[:i]))
		after := len([]rune(got[i+len(c.needle):]))
		if before < 30 || after < 30 {
			t.Errorf("%s: the match is not centred (%d runes before, %d after): %q", c.name, before, after, got)
		}
	}
}

// #320.1: "*" and "_" go only as emphasis delimiters at a word edge (CommonMark flanking); text that merely
// contains them keeps every character, so a snippet never shows words the notes do not have and "a__b" does not
// match "ab".
// Mutation: internal/meeting/search.go stripInline, mark every cell of every run dropped (right after
// `run.n = i - run.start`) -> the keep cases go RED. Mutation: matchDelims, `if true || !(k == 2 ...` (the
// isDunderName guard off) -> "__init__" loses its underscores -> RED. Mutation: stripInline, the "_" rule
// `canOpen = left; canClose = right` (no intra-word exception) -> "snake_case" loses its underscores -> RED.
func TestStripMarkdownKeepsLiteralDelimiters(t *testing.T) {
	for _, c := range []struct{ name, in, want string }{
		{"star between digits", "2*3=6", "2*3=6"},
		{"dunder name", "__init__", "__init__"},
		{"dunder in a sentence", "call __main__ first", "call __main__ first"},
		{"doubled underscore in a word", "a__b", "a__b"},
		{"snake_case", "foo_bar_baz", "foo_bar_baz"},
		{"spaced stars", "5 * 3 * 2", "5 * 3 * 2"},
		{"lone opening star", "*star", "*star"},
		{"lone closing underscore", "end_", "end_"},
		{"bold", "**bold** text", "bold text"},
		{"italic star", "an *em* word", "an em word"},
		{"italic underscore", "an _em_ word", "an em word"},
		{"strong underscore", "__Important__ note", "Important note"},
		{"bold italic", "***both***", "both"},
		{"nested", "**bold *nested* more**", "bold nested more"},
		{"strong around a dunder", "**__init__**", "__init__"},
		{"cyrillic", "**Решение**: да", "Решение: да"},
		{"emphasis spans a line break", "**bold\ncontinues** here", "bold\ncontinues here"},
		{"emphasis stops at a list item", "- *a\n- b*", "*a\nb*"},
		{"emphasis stops at a blank line", "*a\n\nb*", "*a\n\nb*"},
		{"punctuation before the closer", "(**done**)", "(done)"},
		{"escaped stars", `\*not em\*`, "*not em*"},
	} {
		if got := stripMarkdown(c.in); got != c.want {
			t.Errorf("%s: stripMarkdown(%q) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

// #320.2: a combining mark is part of the word it follows and an emoji or symbol next to a delimiter is CommonMark
// punctuation (0.31: the P and S categories), so decomposed and precomposed text give the same answer and
// "🎉_great_" is emphasis.
// Mutation: internal/meeting/search.go isMDPunct, back to `unicode.IsPunct(r) || (r < utf8.RuneSelf && unicode.IsSymbol(r))`
// -> the emoji and currency rows keep their underscores -> RED.
func TestStripMarkdownMarksAndSymbolsNextToDelimiters(t *testing.T) {
	for _, c := range []struct{ name, in, want string }{
		{"emoji before emphasis", "🎉_great_ news", "🎉great news"},
		{"emoji after emphasis", "a _great_🎉", "a great🎉"},
		{"emoji before a star", "🎉**done**", "🎉done"},
		{"currency before emphasis", "€_net_", "€net"},
		{"decomposed accent is a word letter", "_e\u0301_", "e\u0301"},
		{"decomposed accent inside snake_case", "cafe\u0301_au_lait", "cafe\u0301_au_lait"},
		{"precomposed accent inside snake_case", "caf\u00e9_au_lait", "caf\u00e9_au_lait"},
		{"mark after the closer stays a word", "_x_\u0301", "_x_\u0301"},
	} {
		if got := stripMarkdown(c.in); got != c.want {
			t.Errorf("%s: stripMarkdown(%q) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

// The search sees what the snippet shows: "a__b" is not "ab".
func TestNotesSearchDoesNotMatchAcrossLiteralDelimiters(t *testing.T) {
	if hits := notesHits("rename a__b today\n", foldRunes("ab"), 5); len(hits) != 0 {
		t.Errorf("%q matched \"ab\": %+v", "a__b", hits)
	}
	if got := firstNotesSnippet(t, "the product 2*3=6 here\n", "2*3"); got != "the product 2*3=6 here" {
		t.Errorf("snippet = %q", got)
	}
}
