package meeting

import (
	"strings"
	"testing"
)

// Model strings stay inline text: no heading, quote, image or link, no
// newline that starts a new block.
func TestNotesMarkdownKeepsModelTextInline(t *testing.T) {
	n := Notes{ChunkNotes: ChunkNotes{
		Summary:       "# Injected heading\nline two\n\n> quote\n![img](http://evil/x.png) and [a link](http://evil/y)",
		Decisions:     []string{"ok\n\n## Fake section\n- nested", "[click](http://evil/z) to pay"},
		ActionItems:   []ActionItem{{Who: "Bob\n# H", What: "!\n[x](http://evil/w)\n> q", When: "# soon"}},
		OpenQuestions: []string{">quoted"},
		Numbers:       []string{"![i](u)"},
	}}
	md := NotesMarkdown(Manifest{Title: "T"}, n, "en")
	for _, bad := range []string{"](http", "\n# Injected", "\n## Fake", "\n> quote", "\n![", "- # ", "- [click]", "- >", "- !["} {
		if strings.Contains(md, bad) {
			t.Errorf("notes contain %q:\n%s", bad, md)
		}
	}
	for _, line := range strings.Split(md, "\n") {
		if strings.HasPrefix(line, "#") && !strings.HasPrefix(line, "# T") && !strings.HasPrefix(line, "## ") {
			t.Errorf("a model line became a heading: %q", line)
		}
	}
	if strings.Count(md, "\n## ") != 5 { // summary, decisions, actions, questions, numbers
		t.Errorf("the model added or removed sections:\n%s", md)
	}
	if !strings.Contains(md, `- \[click] to pay`) {
		t.Errorf("link text must survive, escaped:\n%s", md)
	}
}
