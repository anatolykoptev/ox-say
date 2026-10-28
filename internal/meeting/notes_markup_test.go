package meeting

import (
	"bytes"
	"strings"
	"testing"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	gmext "github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/text"
)

// Model text must never become a link, an image, an autolink or raw HTML in notes.md, whatever it holds: the check
// renders the notes through a CommonMark parser (goldmark, with tables, strikethrough and task lists, a test-only
// dependency) and walks the tree. Deleting one link target must not leave two parts that join into a new one:
// "[a](http://x)(http://evil/p)" loses "(http://x)" and would read "[a](http://evil/p)" again.
// Mutation: internal/meeting/notes_render.go cleanLine, replace the neutralizeLinks call with the single pass
// `s = linkTarget.ReplaceAllString(s, "]")` -> RED (the nested-target cases render a link or an image).
func TestModelTextNeverBecomesMarkup(t *testing.T) {
	md := goldmark.New(goldmark.WithExtensions(gmext.Table, gmext.Strikethrough, gmext.TaskList))
	for _, in := range []string{
		"see [a](http://example.invalid/x)(http://example.invalid/p) now",
		"![a](http://example.invalid/x)(http://example.invalid/p.png)",
		"see ![a](http://example.invalid/x)(http://example.invalid/p.png) now",
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
