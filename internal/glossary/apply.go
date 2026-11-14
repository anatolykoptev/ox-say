package glossary

import (
	"sort"
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// token is a run of word characters or a run of anything else.
type token struct {
	s    string
	word bool
}

// isWordRune: letters, digits, combining marks (a decomposed й), apostrophes
// and the hyphen. Keep the apostrophe set in step with wordalign.normalise
// (internal/wordalign/wer.go).
func isWordRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r) || unicode.Is(unicode.Mn, r) ||
		r == '\'' || r == '’' || r == 'ʼ' || r == '-'
}

func tokenize(s string) []token {
	var out []token
	var b strings.Builder
	word := false
	for _, r := range norm.NFC.String(s) {
		w := isWordRune(r)
		if b.Len() > 0 && w != word {
			out = append(out, token{b.String(), word})
			b.Reset()
		}
		word = w
		b.WriteRune(r)
	}
	if b.Len() > 0 {
		out = append(out, token{b.String(), word})
	}
	return out
}

var foldReplacer = strings.NewReplacer("ё", "е", "’", "'", "ʼ", "'")

func fold(s string) string { return foldReplacer.Replace(strings.ToLower(norm.NFC.String(s))) }

// words is the folded word tokens of s.
func words(s string) []string {
	var out []string
	for _, t := range tokenize(s) {
		if t.word {
			out = append(out, fold(t.s))
		}
	}
	return out
}

func key(s string) string { return strings.Join(words(s), " ") }

func hasLetter(s string) bool {
	for _, r := range s {
		if unicode.IsLetter(r) {
			return true
		}
	}
	return false
}

// containsSeq reports whether needle occurs in hay as consecutive words.
func containsSeq(hay, needle []string) bool {
	for i := 0; len(needle) > 0 && i+len(needle) <= len(hay); i++ {
		match := true
		for k := range needle {
			if hay[i+k] != needle[k] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

type compiled struct {
	heard []string
	meant string
}

// compile keeps the active pairs, longest heard form first.
func compile(pairs []Pair) []compiled {
	var cs []compiled
	for _, p := range pairs {
		if p.Status != Active {
			continue
		}
		if h := words(p.Heard); len(h) > 0 {
			cs = append(cs, compiled{h, p.Meant})
		}
	}
	sort.SliceStable(cs, func(i, j int) bool { return len(cs[i].heard) > len(cs[j].heard) })
	return cs
}

// Apply replaces every whole-word match of an active pair in text. It returns
// the new text and the number of replacements that changed something; a span
// that already reads as the meant form is left and not counted.
func Apply(text string, pairs []Pair) (string, int) {
	cs := compile(pairs)
	if len(cs) == 0 {
		return text, 0
	}
	toks := tokenize(text)
	var b strings.Builder
	n := 0
	for i := 0; i < len(toks); {
		if toks[i].word {
			if c, end, ok := match(toks, i, cs); ok {
				var span strings.Builder
				for _, t := range toks[i:end] {
					span.WriteString(t.s)
				}
				if span.String() == c.meant {
					b.WriteString(c.meant)
				} else {
					b.WriteString(c.meant)
					n++
				}
				i = end
				continue
			}
		}
		b.WriteString(toks[i].s)
		i++
	}
	if n == 0 {
		return text, 0
	}
	return b.String(), n
}

// match tries each pair at toks[i]; the words of a multi-word form may be
// separated by whitespace only. It returns the index after the match.
func match(toks []token, i int, cs []compiled) (compiled, int, bool) {
	for _, c := range cs {
		j, ok := i, true
		for k, h := range c.heard {
			if k > 0 {
				if j >= len(toks) || toks[j].word || strings.TrimSpace(toks[j].s) != "" {
					ok = false
					break
				}
				j++
			}
			if j >= len(toks) || !toks[j].word || fold(toks[j].s) != h {
				ok = false
				break
			}
			j++
		}
		if ok {
			return c, j, true
		}
	}
	return compiled{}, 0, false
}

// edges returns what surrounds the word characters of one recognised word.
func edges(w string) (pre, post string) {
	toks := tokenize(w)
	first, last := -1, -1
	for i, t := range toks {
		if t.word {
			if first < 0 {
				first = i
			}
			last = i
		}
	}
	if first < 0 {
		return w, ""
	}
	for _, t := range toks[:first] {
		pre += t.s
	}
	for _, t := range toks[last+1:] {
		post += t.s
	}
	return pre, post
}

// ApplyWords replaces matches in a word list. A multi-word match becomes one
// word from the first start to the last end with the lowest probability. Like
// Apply, it never matches across punctuation.
func ApplyWords(ws []stt.Word, pairs []Pair) []stt.Word {
	cs := compile(pairs)
	if len(cs) == 0 {
		return ws
	}
	out := make([]stt.Word, 0, len(ws))
	for i := 0; i < len(ws); {
		c, n, ok := matchWords(ws, i, cs)
		if !ok {
			out = append(out, ws[i])
			i++
			continue
		}
		first, last := ws[i], ws[i+n-1]
		pre, _ := edges(first.W)
		_, post := edges(last.W)
		w := stt.Word{W: pre + c.meant + post, S: first.S, E: last.E, P: first.P}
		for _, x := range ws[i : i+n] {
			w.P = min(w.P, x.P)
		}
		out = append(out, w)
		i += n
	}
	return out
}

func matchWords(ws []stt.Word, i int, cs []compiled) (compiled, int, bool) {
	for _, c := range cs {
		n := len(c.heard)
		if i+n > len(ws) {
			continue
		}
		ok := true
		for k, h := range c.heard {
			w := ws[i+k].W
			pre, post := edges(w)
			if key(w) != h || (k < n-1 && post != "") || (k > 0 && strings.TrimSpace(pre) != "") {
				ok = false
				break
			}
		}
		if ok {
			return c, n, true
		}
	}
	return compiled{}, 0, false
}

// ApplyResult corrects a recognised result in place: the text, each segment's
// text and the words. It returns the replacements counted in the text.
func ApplyResult(res *stt.Result, pairs []Pair) int {
	if res == nil {
		return 0
	}
	text, n := Apply(res.Text, pairs)
	res.Text = text
	for i := range res.Segments {
		res.Segments[i].Text, _ = Apply(res.Segments[i].Text, pairs)
	}
	res.Words = ApplyWords(res.Words, pairs)
	return n
}
