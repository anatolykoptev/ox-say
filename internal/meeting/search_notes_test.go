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
		{"escaped star stays", `price 5 \* 3 and \[x\]`+"\n", "5 *", "price 5 * 3 and [x]"},
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
