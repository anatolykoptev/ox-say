package meeting

import (
	"bytes"
	"fmt"
	"html"
	"math/rand"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	gmext "github.com/yuin/goldmark/extension"
	gmhtml "github.com/yuin/goldmark/renderer/html"
	"github.com/yuin/goldmark/text"
)

// Model text must never become a link, an image, an autolink or raw HTML in notes.md, whatever it holds: the check
// renders the notes through a CommonMark parser (goldmark, with tables, strikethrough and task lists, a test-only
// dependency) and walks the tree. Deleting one link target must not leave two parts that join into a new one:
// "[a](http://x)(http://evil/p)" loses "(http://x)" and would read "[a](http://evil/p)" again.
// Mutation: internal/meeting/notes_render.go cleanLine, delete the `s = escapeBrackets(s)` line -> RED (links, images
// and the reference-definition bypass render).
func TestModelTextNeverBecomesMarkup(t *testing.T) {
	md := goldmark.New(goldmark.WithExtensions(gmext.Table, gmext.Strikethrough, gmext.TaskList))
	for _, in := range []string{
		"see [a](http://example.invalid/x)(http://example.invalid/p) now",
		"![a](http://example.invalid/x)(http://example.invalid/p.png)",
		"see ![a](http://example.invalid/x)(http://example.invalid/p.png) now",
		// A reference definition inside a list item is written by NotesMarkdown as "- - [r]: ..." (a nested item) and
		// defines [r] for the whole document; the image then comes from another field.
		"- [r]: http://example.invalid/p.png?d=SECRET\nsee ![a][r]",
		"[a](//example.invalid/x)(http://example.invalid/p)",
		"[a](/x)(//example.invalid/p)(http://example.invalid/q)",
		"[a [b](http://example.invalid/x)](http://example.invalid/y)",
		"[[a](http://example.invalid/x)](http://example.invalid/y)",
		"![[a](http://example.invalid/x)](http://example.invalid/y)",
		"x[i](y) and [j](z)",
		"[a][ref]\n[ref]: http://example.invalid/r",
		"[ref]: http://example.invalid/r\n\n![a][ref] [b][ref] [ref]",
		"line\n[ref]: http://example.invalid/r",
		"<http://example.invalid/a> <img src=http://example.invalid/i.png> <b>x</b>",
		"&lt;img src=http://example.invalid/i.png&gt; &#60;img src=x&#62; &amp;",
		`\[a\](http://example.invalid/x)`, `\\[a](http://example.invalid/x)`, `[a]\(http://example.invalid/x)`,
		"[a]( http://example.invalid/x )(http://example.invalid/y)", "[a](<http://example.invalid/x>)",
		"[a](javascript:alert(1))(data:text/html,x)", "] ( http://example.invalid/x )",
	} {
		n := Notes{ChunkNotes: ChunkNotes{
			Summary: in, Decisions: []string{in}, OpenQuestions: []string{in}, Numbers: []string{in},
			ActionItems: []ActionItem{{Who: in, What: in, When: in}},
		}}
		out := NotesMarkdown(Manifest{Title: "T"}, n, "en")
		src := []byte(out)
		root := md.Parser().Parse(text.NewReader(src))
		_ = ast.Walk(root, func(node ast.Node, entering bool) (ast.WalkStatus, error) {
			if !entering {
				return ast.WalkContinue, nil
			}
			switch node.Kind().String() {
			case "Link", "Image", "AutoLink", "RawHTML", "HTMLBlock":
				t.Errorf("model text %q became a %s node in:\n%s", in, node.Kind(), out)
			}
			return ast.WalkContinue, nil
		})
		var html bytes.Buffer
		if err := md.Convert(src, &html); err != nil {
			t.Fatal(err)
		}
		for _, bad := range []string{"<img", "<a ", "<a>", "href="} {
			if strings.Contains(html.String(), bad) {
				t.Errorf("model text %q rendered %q:\n%s", in, bad, html.String())
			}
		}
	}
}

// The same, with the definition in one field and the use in another: a definition anywhere defines the label for the
// whole document, so neither field may hold one.
func TestAReferenceDefinitionInOneFieldDoesNotArmAnother(t *testing.T) {
	def := "- [r]: http://example.invalid/p.png?d=SECRET"
	use := "see ![a][r] and [b][r]"
	for name, n := range map[string]Notes{
		"decision defines, action uses":  {ChunkNotes: ChunkNotes{Decisions: []string{def}, ActionItems: []ActionItem{{Who: "Bob", What: use, When: "Friday"}}}},
		"summary defines, decision uses": {ChunkNotes: ChunkNotes{Summary: "intro\n" + def + "\nmore", Decisions: []string{use}}},
		"question defines, summary uses": {ChunkNotes: ChunkNotes{Summary: use, OpenQuestions: []string{def}}},
		"number defines, owner uses":     {ChunkNotes: ChunkNotes{Numbers: []string{def}, ActionItems: []ActionItem{{Who: use, What: "x", When: "y"}}}},
	} {
		if v := markupViolation(NotesMarkdown(Manifest{Title: "T"}, n, "en")); v != "" {
			t.Errorf("%s: %s", name, v)
		}
	}
}

var (
	renderedImg  = regexp.MustCompile(`<img\b`)
	renderedLink = regexp.MustCompile(`<a href="([^"]*)"[^>]*>(.*?)</a>`)
)

// markupViolation renders md as GFM, with raw HTML allowed (the worst viewer), and reports an image, or a link whose
// visible text is not its own address. A bare URL that a viewer makes clickable shows its address, and is plain text
// the model wrote; it never fetches anything.
func markupViolation(md string) string {
	var b bytes.Buffer
	for _, unsafe := range []bool{false, true} {
		opts := []goldmark.Option{goldmark.WithExtensions(gmext.GFM)}
		if unsafe {
			opts = append(opts, goldmark.WithRendererOptions(gmhtml.WithUnsafe()))
		}
		b.Reset()
		if err := goldmark.New(opts...).Convert([]byte(md), &b); err != nil {
			return err.Error()
		}
		out := b.String()
		if renderedImg.MatchString(out) {
			return "an image rendered from model text:\n" + md
		}
		for _, m := range renderedLink.FindAllStringSubmatch(out, -1) {
			href, text := html.UnescapeString(m[1]), html.UnescapeString(m[2])
			if u, err := url.PathUnescape(href); err == nil {
				href = u
			}
			if text == "" || !strings.Contains(href, text) {
				return "a link rendered from model text: " + m[0] + "\n" + md
			}
		}
	}
	return ""
}

var fuzzTokens = []string{"[", "]", "(", ")", "!", "<", ">", `\`, "a", "http://e.x/p", " ", "*", "_", "#", "\n", "&", ";", "](", ")(",
	"![", "](http://x)", "`", "-", "|", "www.e.x/q", ":", "[r]:", "![a][r]", "- [r]: http://e.x/p", "[r]", "1. ", "> ", "+ "}

// Random model text, through the whole NotesMarkdown (every field, the heading and the list nesting), never renders
// an image or a link of its own. The seed is fixed; OX_FUZZ_N raises the count (150000 was run for the incident).
// Mutation: internal/meeting/notes_render.go cleanLine, delete the `s = escapeBrackets(s)` line -> RED.
func TestRandomModelTextNeverRendersMarkup(t *testing.T) {
	n := 8000
	if v, err := strconv.Atoi(os.Getenv("OX_FUZZ_N")); err == nil && v > 0 {
		n = v
	}
	m := Manifest{ID: "x", Started: time.Date(2026, 10, 28, 10, 0, 0, 0, time.UTC), Labels: Labels{Me: "Me", Them: "Them"}}
	r := rand.New(rand.NewSource(42))
	bad, first := 0, ""
	for i := 0; i < n; i++ {
		var sb strings.Builder
		for j, k := 0, 1+r.Intn(14); j < k; j++ {
			sb.WriteString(fuzzTokens[r.Intn(len(fuzzTokens))])
		}
		p := sb.String()
		md := NotesMarkdown(m, Notes{ChunkNotes: ChunkNotes{Summary: p, Decisions: []string{p}, OpenQuestions: []string{p},
			ActionItems: []ActionItem{{Who: "Bob", What: "x " + p, When: p}}}}, "en")
		if v := markupViolation(md); v != "" {
			if bad++; first == "" {
				first = fmt.Sprintf("input %q: %s", p, v)
			}
		}
	}
	if bad > 0 {
		t.Errorf("%d of %d random inputs rendered markup; first: %s", bad, n, first)
	}
}

// topLevelShape renders md as GFM and lists the kinds of the document's top-level blocks as letters: H heading,
// P paragraph, L list, and the block kind's own name for anything else (a code block, a table, a quote, a rule, raw
// HTML). Model text in the summary may only add paragraphs.
func topLevelShape(md string) string {
	src := []byte(md)
	root := goldmark.New(goldmark.WithExtensions(gmext.GFM), goldmark.WithRendererOptions(gmhtml.WithUnsafe())).
		Parser().Parse(text.NewReader(src))
	var b strings.Builder
	for c := root.FirstChild(); c != nil; c = c.NextSibling() {
		switch c.Kind().String() {
		case "Heading":
			b.WriteString("H")
		case "Paragraph":
			b.WriteString("P")
		case "List":
			b.WriteString("L")
		default:
			b.WriteString("<" + c.Kind().String() + ">")
		}
	}
	return b.String()
}

var summaryShape = regexp.MustCompile(`^HHP+HLHL$`)

// The summary is a model string that spans lines. Whatever its lines start with, it stays paragraphs: a lone fence
// must not swallow Decisions and Action items, "===" or "---" must not turn the line above into a heading, and a
// marker must not make a list, a table, a rule or a quote of its own (#303 R1).
// Mutation: internal/meeting/notes_render.go cleanBlock, replace `escapeBlockStart(cleanLine(l))` with `cleanLine(l)`
// -> RED (the fences, setext lines, lists and tables render as blocks).
func TestSummaryLinesNeverBecomeBlocks(t *testing.T) {
	for _, in := range []string{
		"intro\n```\nmore", "intro\n~~~\nmore", "```go\nx", "intro\n====\nmore", "intro\n---\nmore", "intro\n===",
		"- a\n- b", "* a", "+ a", "1. a\n2. b", "7) a", "123456789. a",
		"| a | b |\n|---|---|\n| 1 | 2 |", "a | b\n--|--\n1 | 2", "a | b\n:-:|:-:\n1 | 2", ":--|--:",
		"***", "___", "- - -", "* * *", "> quote", "# heading", "<div>", "!x",
		"first\n\n```\n\nsecond",
	} {
		n := Notes{ChunkNotes: ChunkNotes{Summary: in, Decisions: []string{"d"}, ActionItems: []ActionItem{{Who: "Bob", What: "x", When: "Friday"}}}}
		md := NotesMarkdown(Manifest{Title: "T"}, n, "en")
		if got := topLevelShape(md); !summaryShape.MatchString(got) {
			t.Errorf("summary %q renders as %s, want headings, paragraphs and the two lists:\n%s", in, got, md)
		}
	}
}

var blockTokens = []string{"```", "~~~", "===", "---", "-", "+", "*", "1.", "2)", "|", "a | b", "--|--", ":-:", "***", "___", "> ", "# ", "\n", "\n\n", " ", "x", "\t", "<", "&"}

// Random summaries, built from block markers, never render anything but paragraphs between the summary heading and
// the next section.
// Mutation: internal/meeting/notes_render.go cleanBlock, as above -> RED.
func TestRandomSummaryNeverRendersBlocks(t *testing.T) {
	n := 4000
	if v, err := strconv.Atoi(os.Getenv("OX_FUZZ_N")); err == nil && v > 0 {
		n = v
	}
	r := rand.New(rand.NewSource(303))
	bad, first := 0, ""
	for i := 0; i < n; i++ {
		var sb strings.Builder
		for j, k := 0, 1+r.Intn(12); j < k; j++ {
			sb.WriteString(blockTokens[r.Intn(len(blockTokens))])
			if r.Intn(3) == 0 {
				sb.WriteString(" ")
			}
		}
		p := sb.String()
		if strings.TrimSpace(p) == "" {
			continue
		}
		md := NotesMarkdown(Manifest{Title: "T"}, Notes{ChunkNotes: ChunkNotes{Summary: p, Decisions: []string{"d"},
			ActionItems: []ActionItem{{Who: "Bob", What: "x", When: "Friday"}}}}, "en")
		if got := topLevelShape(md); !summaryShape.MatchString(got) {
			if bad++; first == "" {
				first = fmt.Sprintf("input %q renders as %s", p, got)
			}
		}
	}
	if bad > 0 {
		t.Errorf("%d of %d random summaries rendered a block; first: %s", bad, n, first)
	}
}

// Action lines are split on " — " by the app, so a model field (or a label) that holds one would shift the parts.
// Mutation: internal/meeting/notes_render.go NotesMarkdown, drop the `inlineDash(...)` calls on the action line
// -> RED.
func TestActionFieldsKeepTheirSeparator(t *testing.T) {
	n := Notes{ChunkNotes: ChunkNotes{ActionItems: []ActionItem{
		{Who: "Ana — CFO", What: "send the plan — today — now", When: "Friday — noon"},
		{Who: "Bob", What: "a — — b", When: "x"},
	}}}
	md := NotesMarkdown(Manifest{Title: "T"}, n, "en")
	for _, line := range strings.Split(md, "\n") {
		if !strings.HasPrefix(line, "- [ ] ") {
			continue
		}
		if parts := strings.Split(strings.TrimPrefix(line, "- [ ] "), " — "); len(parts) != 3 {
			t.Errorf("%q splits into %d parts on the separator, want 3", line, len(parts))
		}
	}
}
