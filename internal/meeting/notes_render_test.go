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

// A speaker's name may hold markup (checkName allows it) and the notes name the speaker in the action items: the
// label is escaped there as in transcript.md (#256, #262). What the model wrote as the owner, which is not one of
// the labels, is left as the model wrote it: it is not escaped twice.
// Mutation: internal/meeting/notes_render.go ownerText, replace `return escapeMarkdown(line)` with `return line` -> RED.
func TestNotesMarkdownEscapesSpeakerLabels(t *testing.T) {
	m := Manifest{Title: "T", Labels: Labels{Me: "Me <i>", Them: "Other"}}
	n := Notes{
		ChunkNotes: ChunkNotes{ActionItems: []ActionItem{
			{Who: "*x*", What: "a", When: "b"},
			{Who: "<b>Ivan</b>", What: "c", When: "d"},
			{Who: "Me <i>", What: "e", When: "f"},
			{Who: "*model*", What: "g", When: "h"},
		}},
		Labels: map[string]string{"them:1": "*x*", "them:2": "<b>Ivan</b>"},
	}
	md := NotesMarkdown(m, n, "en")
	for _, want := range []string{`- [ ] \*x\* — a — b`, `- [ ] \<b\>Ivan\</b\> — c — d`, `- [ ] Me \<i\> — e — f`, `- [ ] *model* — g — h`} {
		if !strings.Contains(md, want) {
			t.Errorf("notes lack %q:\n%s", want, md)
		}
	}
}

// A rendering viewer fetches <img src=...> and <http://...> by itself, so no < from the model or the title
// reaches notes.md unescaped, in any section (#235).
// Mutations: notes_render.go cleanLine, remove the `<` escape -> RED (F4); NotesMarkdown, heading(m) without
// cleanLine -> RED (F5).
func TestNotesMarkdownEscapesAngleBrackets(t *testing.T) {
	img := "<img src=http://example.invalid/x.png>"
	auto := "<http://example.invalid/a>"
	n := Notes{ChunkNotes: ChunkNotes{
		Summary:       img,
		Decisions:     []string{auto},
		ActionItems:   []ActionItem{{Who: img, What: auto, When: img}},
		OpenQuestions: []string{img},
		Numbers:       []string{auto},
	}}
	md := NotesMarkdown(Manifest{Title: img}, n, "en")
	short := ShortNotesMarkdown(Manifest{Title: img}, "en")
	assertAnglesEscaped(t, "notes", md)
	assertAnglesEscaped(t, "short", short)
	if strings.Count(md, `\<`) < 8 {
		t.Errorf("want every writer escaped (title, summary, decision, owner, what, when, question, number):\n%s", md)
	}
}

// assertAnglesEscaped: every < is preceded by an ODD run of backslashes (CommonMark: an even run is literal
// backslashes and the < is live).
func assertAnglesEscaped(t *testing.T, name, out string) {
	t.Helper()
	for i, c := range out {
		if c != '<' {
			continue
		}
		n := 0
		for j := i - 1; j >= 0 && out[j] == '\\'; j-- {
			n++
		}
		if n%2 == 0 {
			t.Errorf("%s: live < at byte %d (%d backslashes before it):\n%s", name, i, n, out)
			return
		}
	}
}

// A backslash in the input must not cancel the escape: \<img> would become \\<img>, a literal backslash and live HTML.
// Mutation: transcript.go escapeAngle, drop the `\` -> `\\` step -> RED.
func TestEscapeAngleSurvivesInputBackslashes(t *testing.T) {
	for _, in := range []string{`\<img src=http://example.invalid/x>`, `\\<img src=http://example.invalid/x>`, `\\\<b>`, `a<b`} {
		n := Notes{ChunkNotes: ChunkNotes{Summary: in, Decisions: []string{in}}}
		assertAnglesEscaped(t, "notes", NotesMarkdown(Manifest{Title: in}, n, "en"))
		assertAnglesEscaped(t, "transcript", TranscriptMarkdown(Manifest{Title: in, Started: t0, Labels: Labels{Me: "A"}}, []Turn{{Speaker: SpeakerMe, S: 1, Text: in}}))
	}
}

// The title renders as typed: link syntax in it is escaped, not deleted.
func TestHeadingKeepsTheTitleAsTyped(t *testing.T) {
	m := Manifest{Title: "Q3 [plan](v2) <b>", Started: t0}
	want := `# Q3 \[plan\](v2) \<b\> — `
	for name, out := range map[string]string{"notes": NotesMarkdown(m, Notes{}, "en"), "short": ShortNotesMarkdown(m, "en"), "transcript": TranscriptMarkdown(m, nil)} {
		if !strings.HasPrefix(out, want) {
			t.Errorf("%s heading = %q, want prefix %q", name, strings.SplitN(out, "\n", 2)[0], want)
		}
	}
}

// Turn text is third-party speech: markdown image and link syntax in it is not live.
// Mutation: transcript.go TranscriptMarkdown, turn text raw -> RED.
func TestTranscriptTurnTextHasNoLiveMarkdown(t *testing.T) {
	md := TranscriptMarkdown(Manifest{Started: t0, Labels: Labels{Me: "A"}}, []Turn{{Speaker: SpeakerMe, S: 1, Text: "![x](http://example.invalid/p.png) and [l](http://example.invalid/q)"}})
	for _, bad := range []string{"![", "[l]", "[x]"} {
		if strings.Contains(md, bad) {
			t.Errorf("transcript holds live %q:\n%s", bad, md)
		}
	}
	if !strings.Contains(md, `!\[x\](http://example.invalid/p.png)`) {
		t.Errorf("transcript lacks the escaped image text:\n%s", md)
	}
}

// Search reads notes.md; the snippet and the match are on the text as the user sees it, not on the escapes.
func TestNotesHitsUndoTheEscape(t *testing.T) {
	notes := NotesMarkdown(Manifest{Title: "T", Started: t0}, Notes{ChunkNotes: ChunkNotes{Summary: `see <img src=x> and C:\dir and [a]`}}, "en")
	hits := notesHits(notes, foldRunes("<img src"), 3)
	if len(hits) != 1 || !strings.Contains(hits[0].Snippet, "<img src=x>") || strings.Contains(hits[0].Snippet, `\<`) {
		t.Fatalf("hits = %+v", hits)
	}
	if h := notesHits(notes, foldRunes(`c:\dir and [a]`), 3); len(h) != 1 {
		t.Fatalf("a query with a backslash and brackets did not match: %+v", h)
	}
}
