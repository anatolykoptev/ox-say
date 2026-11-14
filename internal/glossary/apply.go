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

// isWordRune: letters, digits, combining marks (a decomposed й), apostrophes,
// the hyphen and the underscore (foo_bar is one word). Keep the apostrophe
// set in step with wordalign.normalise (internal/wordalign/wer.go).
func isWordRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r) || unicode.Is(unicode.Mn, r) ||
		r == '\'' || r == '’' || r == 'ʼ' || r == '-' || r == '_'
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
	// mkey is the folded meant minus its non-word edges; lead and trail are
	// those edges folded (the "[" and "]" of "[foo]", the "++" of "C++") — a
	// meant that is only words and whitespace has neither.
	mkey  string
	lead  string
	trail string
}

// compile keeps the active pairs, longest heard form first.
func compile(pairs []Pair) []compiled {
	var cs []compiled
	for _, p := range pairs {
		if p.Status != Active {
			continue
		}
		if h := words(p.Heard); len(h) > 0 {
			c := compiled{heard: h, meant: p.Meant}
			mt := tokenize(p.Meant)
			if len(mt) > 0 && !mt[0].word {
				c.lead = fold(mt[0].s)
				mt = mt[1:]
			}
			if len(mt) > 0 && !mt[len(mt)-1].word {
				c.trail = fold(mt[len(mt)-1].s)
				mt = mt[:len(mt)-1]
			}
			var mid strings.Builder
			for _, t := range mt {
				mid.WriteString(t.s)
			}
			c.mkey = fold(mid.String())
			cs = append(cs, c)
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
				if alreadyMeant(toks, i, end, c) {
					for _, t := range toks[i:end] {
						b.WriteString(t.s)
					}
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

// alreadyMeant reports whether the source at toks[i:end] already reads as
// the full meant — its word part plus the non-word edges it carries — so a
// replacement would double the decoration: C → C++ on "C++" would write
// "C+++", foo → [foo] on "[foo]" "[[foo]]". A meant of plain words compares
// the span verbatim (github → GitHub still corrects the case).
func alreadyMeant(toks []token, i, end int, c compiled) bool {
	var span strings.Builder
	for _, t := range toks[i:end] {
		span.WriteString(t.s)
	}
	if c.lead == "" && c.trail == "" {
		return span.String() == c.meant
	}
	if fold(span.String()) != c.mkey {
		return false
	}
	left, right := "", ""
	if i > 0 {
		left = fold(toks[i-1].s)
	}
	if end < len(toks) {
		right = fold(toks[end].s)
	}
	return strings.HasSuffix(left, c.lead) && strings.HasPrefix(right, c.trail)
}

// match tries each pair at toks[i]; the words of a multi-word form may be
// separated by whitespace only, and a newline ends the match — the two
// sides are different lines of a subtitle. It returns the index after the
// match.
func match(toks []token, i int, cs []compiled) (compiled, int, bool) {
	for _, c := range cs {
		j, ok := i, true
		for k, h := range c.heard {
			if k > 0 {
				if j >= len(toks) || toks[j].word || strings.TrimSpace(toks[j].s) != "" ||
					strings.IndexByte(toks[j].s, '\n') >= 0 {
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
		if alreadyMeantWords(ws, i, n, c) {
			out = append(out, ws[i:i+n]...)
			i += n
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

// alreadyMeantWords is alreadyMeant for a word list: the meant's edges may
// live inside the matched words (" [foo]") or in the words next to them
// (" C" + "++"), so the check reads the previous word's post and the next
// one's pre.
func alreadyMeantWords(ws []stt.Word, i, n int, c compiled) bool {
	if c.lead == "" && c.trail == "" {
		return false
	}
	left, span, right := "", "", ""
	if i > 0 {
		_, post := edges(ws[i-1].W)
		left = post
	}
	for k := 0; k < n; k++ {
		w := ws[i+k].W
		pre, post := edges(w)
		if k == 0 {
			left += pre
		} else {
			span += pre
		}
		span += w[len(pre) : len(w)-len(post)]
		if k == n-1 {
			right = post
		}
	}
	if i+n < len(ws) {
		pre, _ := edges(ws[i+n].W)
		right += pre
	}
	return fold(span) == c.mkey &&
		strings.HasSuffix(fold(left), c.lead) &&
		strings.HasPrefix(fold(right), c.trail)
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
			if key(w) != h || (k < n-1 && post != "") ||
				(k > 0 && (strings.TrimSpace(pre) != "" || strings.IndexByte(pre, '\n') >= 0)) {
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
// text and the words. Segments are corrected against the joined stream, not
// one by one, so a multi-word match that a segment cut splits is still
// rewritten — Text, Words, SRT and VTT agree. It returns the replacements
// counted in the text.
func ApplyResult(res *stt.Result, pairs []Pair) int {
	if res == nil {
		return 0
	}
	cs := compile(pairs)
	text, n := Apply(res.Text, pairs)
	res.Text = text
	res.Segments = applySegments(res.Segments, cs)
	res.Words = ApplyWords(res.Words, pairs)
	return n
}

// segTok is one token's place in a segment's token list.
type segTok struct{ seg, tok int }

// applySegments rewrites segment texts against the same token stream the
// whole text matches on: all segments' tokens in order, with a whitespace
// token inserted where a segment cut falls between two words (recognisers
// cut on pauses, never mid-word) and adjacent non-word runs at the cut
// merged. A match puts the meant in the segment its first word begins in,
// removes the matched tokens from every spanned segment and drops a segment
// that becomes empty; retained segments keep their timings.
func applySegments(segs []stt.Segment, cs []compiled) []stt.Segment {
	if len(segs) == 0 || len(cs) == 0 {
		return segs
	}
	toks := make([][]token, len(segs))
	var flat []token
	var parts [][]segTok
	for k, s := range segs {
		toks[k] = tokenize(s.Text)
		for j, t := range toks[k] {
			if len(flat) > 0 {
				last := len(flat) - 1
				switch {
				case flat[last].word && t.word:
					flat = append(flat, token{s: " ", word: false})
					parts = append(parts, nil)
				case !flat[last].word && !t.word:
					flat[last].s += t.s
					parts[last] = append(parts[last], segTok{seg: k, tok: j})
					continue
				}
			}
			flat = append(flat, t)
			parts = append(parts, []segTok{{seg: k, tok: j}})
		}
	}
	covered := make([][]bool, len(segs))
	insert := make([][]string, len(segs))
	for k := range segs {
		covered[k] = make([]bool, len(toks[k]))
		insert[k] = make([]string, len(toks[k]))
	}
	matched := false
	for i := 0; i < len(flat); {
		if flat[i].word {
			if c, end, ok := match(flat, i, cs); ok {
				if !alreadyMeant(flat, i, end, c) {
					for fi := i; fi < end; fi++ {
						for _, st := range parts[fi] {
							covered[st.seg][st.tok] = true
						}
					}
					first := parts[i][0]
					insert[first.seg][first.tok] = c.meant
					matched = true
				}
				i = end
				continue
			}
		}
		i++
	}
	if !matched {
		return segs
	}
	out := make([]stt.Segment, 0, len(segs))
	for k, s := range segs {
		var b strings.Builder
		for j, t := range toks[k] {
			if insert[k][j] != "" {
				b.WriteString(insert[k][j])
			}
			if !covered[k][j] {
				b.WriteString(t.s)
			}
		}
		if b.Len() == 0 && len(toks[k]) > 0 {
			continue
		}
		s.Text = b.String()
		out = append(out, s)
	}
	return out
}
