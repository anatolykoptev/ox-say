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

// tokenize cuts the raw string — no NFC: comparisons fold per token, and
// combining marks are word runes, so normalising here would only rewrite
// bytes the caller then emits verbatim for every unmatched span.
func tokenize(s string) []token {
	rs := []rune(s)
	var out []token
	var b strings.Builder
	word := false
	for i, r := range rs {
		// A "." between word characters is word-internal (x.foo, node.js,
		// v1.2 are one word each); at a space or an edge it stays a
		// sentence boundary.
		w := isWordRune(r) || (r == '.' && i > 0 && i+1 < len(rs) && isWordRune(rs[i-1]) && isWordRune(rs[i+1]))
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

// Key is the folded word identity of s — what a correction matches on:
// lowercased, NFC, punctuation dropped, words joined by one space.
func Key(s string) string { return strings.Join(words(s), " ") }

func key(s string) string { return Key(s) }

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
	// stems[k] is nominalStem(heard[k]): "" when that word matches only itself.
	stems []string
	meant string
	// homoglyph lets the heard form match a text word that mixes Latin and
	// Cyrillic letters — a code-pack pair only (Pair.Pack).
	homoglyph bool
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
			cs = append(cs, compilePair(p, h))
		}
	}
	sort.SliceStable(cs, func(i, j int) bool { return len(cs[i].heard) > len(cs[j].heard) })
	return cs
}

// compilePair builds one pair's matcher: the folded heard words, the stems they
// may match by, and the meant's folded middle and edges.
func compilePair(p Pair, h []string) compiled {
	c := compiled{heard: h, stems: stemsFor(p, h), meant: p.Meant, homoglyph: p.Pack}
	c.mkey, c.lead, c.trail = meantEdges(p.Meant)
	return c
}

// compileBoth splits the pairs into the owner pass and the pack pass: an owner
// correction runs over the whole input before any pack pair may match, so a
// word an owner pair consumed or produced is never offered to a pack pair.
func compileBoth(pairs []Pair) (owner, pack []compiled) {
	var op, pp []Pair
	for _, p := range pairs {
		if p.Pack {
			pp = append(pp, p)
		} else {
			op = append(op, p)
		}
	}
	return compile(op), compile(pp)
}

// stemsFor is the stem each heard word may match by — "" when it matches only
// itself. A Cyrillic meant is a Russian word in a case of its own («Кролик»,
// «Москва»): replacing «в маскве» by stem would write «в Москва», so only a
// meant in Latin letters stands for every case of the heard word. And a pack
// pair never stems at all: its heard form is one spelling of one identifier —
// «стрип» is no reason to rewrite «стрипа» — only an owner's own correction
// matches another case of its word.
func stemsFor(p Pair, h []string) []string {
	stems := make([]string, len(h))
	if p.Pack || hasCyrillic(p.Meant) {
		return stems
	}
	for k, w := range h {
		stems[k] = nominalStem(w)
	}
	return stems
}

// meantEdges splits a meant form into its folded word part and the folded
// non-word edges it may carry: the "[" and "]" of "[foo]", the "++" of "C++".
// A meant of plain words and whitespace has neither edge.
func meantEdges(meant string) (mkey, lead, trail string) {
	mt := tokenize(meant)
	if len(mt) > 0 && !mt[0].word {
		lead = fold(mt[0].s)
		mt = mt[1:]
	}
	if len(mt) > 0 && !mt[len(mt)-1].word {
		trail = fold(mt[len(mt)-1].s)
		mt = mt[:len(mt)-1]
	}
	var mid strings.Builder
	for _, t := range mt {
		mid.WriteString(t.s)
	}
	return fold(mid.String()), lead, trail
}

// Apply replaces every whole-word match of an active pair in text. It returns
// the new text and the number of replacements that changed something; a span
// that already reads as the meant form is left and not counted.
//
// The match runs in two passes: every owner pair over the whole text first,
// then every pack pair over the tokens the owner pass left. A word an owner
// correction consumed — or produced — is never offered to a pack pair.
func Apply(text string, pairs []Pair) (string, int) {
	cs, pcs := compileBoth(pairs)
	if len(cs)+len(pcs) == 0 {
		return text, 0
	}
	toks := tokenize(text)
	taken := make([]bool, len(toks))
	repl := make([]replacement, len(toks))
	n := 0
	for i := 0; i < len(toks); {
		if toks[i].word {
			if c, end, ok := match(toks, i, cs, taken); ok {
				mark(taken, i, end)
				if !alreadyMeant(toks, i, end, c) {
					repl[i] = replacement{end: end, text: c.meant}
					n++
				}
				i = end
				continue
			}
		}
		i++
	}
	for i := 0; i < len(toks); {
		if toks[i].word && !taken[i] {
			if c, end, ok := match(toks, i, pcs, taken); ok {
				mark(taken, i, end)
				if !alreadyMeant(toks, i, end, c) {
					repl[i] = replacement{end: end, text: c.meant}
					n++
				}
				i = end
				continue
			}
		}
		i++
	}
	if n == 0 {
		return text, 0
	}
	var b strings.Builder
	for i := 0; i < len(toks); {
		if r := repl[i]; r.end > 0 {
			b.WriteString(r.text)
			i = r.end
			continue
		}
		b.WriteString(toks[i].s)
		i++
	}
	return b.String(), n
}

// replacement is a pending rewrite of the token span [i, end): the span's
// owner is decided before the text is emitted, so a later pass never sees a
// replacement word.
type replacement struct {
	end  int
	text string
}

// mark claims the token span [i, end) for the pass that matched it.
func mark(taken []bool, i, end int) {
	for ; i < end; i++ {
		taken[i] = true
	}
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
// sides are different lines of a subtitle. No token of the span may already
// be taken by an earlier pass. It returns the index after the match.
func match(toks []token, i int, cs []compiled, taken []bool) (compiled, int, bool) {
	var end int
	c, ok := firstMatch(cs, func(c compiled, exact bool) bool {
		j, ok := matchAt(toks, i, c, exact, taken)
		end = j
		return ok
	})
	return c, end, ok
}

// firstMatch walks the pairs longest heard form first. Among pairs of the same length an exact heard form beats a
// stem match, whatever the order of the pairs: «дэвина» filed as its own pair is not swallowed by the pair filed as
// «дэвин». A longer pair still beats a shorter exact one («дэвин смита» matches «дэвин смит», not «дэвин»).
func firstMatch(cs []compiled, try func(c compiled, exact bool) bool) (compiled, bool) {
	for lo := 0; lo < len(cs); {
		hi := lo
		for hi < len(cs) && len(cs[hi].heard) == len(cs[lo].heard) {
			hi++
		}
		for _, exact := range []bool{true, false} {
			for _, c := range cs[lo:hi] {
				if try(c, exact) {
					return c, true
				}
			}
		}
		lo = hi
	}
	return compiled{}, false
}

func matchAt(toks []token, i int, c compiled, exact bool, taken []bool) (int, bool) {
	j := i
	for k, h := range c.heard {
		if k > 0 {
			if j >= len(toks) || taken[j] || toks[j].word || strings.TrimSpace(toks[j].s) != "" ||
				strings.IndexByte(toks[j].s, '\n') >= 0 {
				return 0, false
			}
			j++
		}
		if j >= len(toks) || taken[j] || !toks[j].word || !same(h, c, k, exact, fold(toks[j].s)) {
			return 0, false
		}
		j++
	}
	return j, true
}

// stem is the stem word k of the heard form may match by; none in an exact-only pass.
func (c compiled) stem(k int, exact bool) string {
	if exact {
		return ""
	}
	return c.stems[k]
}

// same reports whether folded text word w matches heard word h of pair c. A pack pair's
// pure-Latin heard word also matches a mixed-script token that transliterates to it —
// «Quаrgs» meets "quargs" — and nothing else: the fold runs on the token alone, only when
// its Latin letters are the majority, and only towards an alias word that is pure Latin.
// A mostly-Cyrillic token keeps its letters («rёплейс» is not "replace"), while
// Latin-majority «Pиn» latinizes to "pin" and would meet a "pin" alias — short prose forms
// like that stay out of the safe list instead, by the loader rule. A Cyrillic or mixed
// alias word keeps its spelling, so "Stаrts" never meets «startс».
func same(h string, c compiled, k int, exact bool, w string) bool {
	if c.homoglyph && !hasCyrillic(h) && foldable(w) {
		return Latinized(w) == h
	}
	return sameWord(h, c.stem(k, exact), w)
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
// Apply, it never matches across punctuation and it runs the owner pass over
// the whole list before any pack pair may match.
func ApplyWords(ws []stt.Word, pairs []Pair) []stt.Word {
	cs, pcs := compileBoth(pairs)
	if len(cs)+len(pcs) == 0 {
		return ws
	}
	taken := make([]bool, len(ws))
	repl := make([]wordMatch, len(ws))
	for i := 0; i < len(ws); {
		if c, n, ok := matchWords(ws, i, cs, taken); ok {
			mark(taken, i, i+n)
			if !alreadyMeantWords(ws, i, n, c) {
				repl[i] = wordMatch{n: n, c: c}
			}
			i += n
			continue
		}
		i++
	}
	for i := 0; i < len(ws); {
		if !taken[i] {
			if c, n, ok := matchWords(ws, i, pcs, taken); ok {
				mark(taken, i, i+n)
				if !alreadyMeantWords(ws, i, n, c) {
					repl[i] = wordMatch{n: n, c: c}
				}
				i += n
				continue
			}
		}
		i++
	}
	out := make([]stt.Word, 0, len(ws))
	for i := 0; i < len(ws); {
		if r := repl[i]; r.n > 0 {
			first, last := ws[i], ws[i+r.n-1]
			pre, _ := edges(first.W)
			_, post := edges(last.W)
			w := stt.Word{W: pre + r.c.meant + post, S: first.S, E: last.E, P: first.P}
			for _, x := range ws[i : i+r.n] {
				w.P = min(w.P, x.P)
			}
			out = append(out, w)
			i += r.n
			continue
		}
		out = append(out, ws[i])
		i++
	}
	return out
}

// wordMatch is a pending rewrite of the word span [i, i+n).
type wordMatch struct {
	n int
	c compiled
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

func matchWords(ws []stt.Word, i int, cs []compiled, taken []bool) (compiled, int, bool) {
	var n int
	c, ok := firstMatch(cs, func(c compiled, exact bool) bool {
		m, ok := matchWordsAt(ws, i, c, exact, taken)
		n = m
		return ok
	})
	return c, n, ok
}

func matchWordsAt(ws []stt.Word, i int, c compiled, exact bool, taken []bool) (int, bool) {
	n := len(c.heard)
	if i+n > len(ws) {
		return 0, false
	}
	for k, h := range c.heard {
		if taken[i+k] {
			return 0, false
		}
		w := ws[i+k].W
		pre, post := edges(w)
		if !same(h, c, k, exact, key(w)) || (k < n-1 && post != "") ||
			(k > 0 && (strings.TrimSpace(pre) != "" || strings.IndexByte(pre, '\n') >= 0)) {
			return 0, false
		}
	}
	return n, true
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
	cs, pcs := compileBoth(pairs)
	text, n := Apply(res.Text, pairs)
	res.Text = text
	res.Segments = applySegments(res.Segments, cs, pcs)
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
// that becomes empty. The surviving segment takes the whole matched
// interval: it runs to the end of the last spanned segment when that one is
// dropped, or to that segment's start when it keeps words — a segment has no
// word times, so its start cannot move past the removed words and the cues
// stay a partition. Other retained segments keep their timings.
func applySegments(segs []stt.Segment, cs, pcs []compiled) []stt.Segment {
	if len(segs) == 0 || len(cs)+len(pcs) == 0 {
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
	e := segEdits{
		covered: make([][]bool, len(segs)),
		insert:  make([][]string, len(segs)),
		spans:   map[int]int{},
	}
	for k := range segs {
		e.covered[k] = make([]bool, len(toks[k]))
		e.insert[k] = make([]string, len(toks[k]))
	}
	taken := make([]bool, len(flat))
	e.scan(flat, parts, cs, taken)
	e.scan(flat, parts, pcs, taken)
	if !e.matched {
		return segs
	}
	spans := e.spans
	covered := e.covered
	insert := e.insert
	alive := make([]bool, len(segs))
	for k := range segs {
		alive[k] = len(toks[k]) == 0
		for j := range toks[k] {
			if insert[k][j] != "" || !covered[k][j] {
				alive[k] = true
				break
			}
		}
	}
	// grow is the end a surviving segment must take to cover its match.
	grow := map[int]float64{}
	for first, last := range spans {
		e := segs[last].S
		if !alive[last] {
			e = segs[last].E
		}
		if e > grow[first] {
			grow[first] = e
		}
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
		if g, ok := grow[k]; ok && g > s.E {
			s.E = g
		}
		out = append(out, s)
	}
	return out
}

// segEdits collects the rewrites the matching passes want on the segment
// token stream: which tokens they cover, the meant each inserts at the span's
// first token and how far that span's first segment must grow — the segment a
// match starts in maps to the last one it spans.
type segEdits struct {
	covered [][]bool
	insert  [][]string
	spans   map[int]int
	matched bool
}

// scan runs one pass over the flat token stream. A match claims its flat span
// in taken, so a later pass never crosses it; it covers the tokens in every
// segment it touches and queues the meant at the first token of the span.
func (e *segEdits) scan(flat []token, parts [][]segTok, cs []compiled, taken []bool) {
	for i := 0; i < len(flat); {
		if flat[i].word && !taken[i] {
			if c, end, ok := match(flat, i, cs, taken); ok {
				mark(taken, i, end)
				if !alreadyMeant(flat, i, end, c) {
					for fi := i; fi < end; fi++ {
						for _, st := range parts[fi] {
							e.covered[st.seg][st.tok] = true
						}
					}
					first, last := parts[i][0], parts[end-1][len(parts[end-1])-1]
					if last.seg != first.seg && last.seg > e.spans[first.seg] {
						e.spans[first.seg] = last.seg
					}
					e.insert[first.seg][first.tok] = c.meant
					e.matched = true
				}
				i = end
				continue
			}
		}
		i++
	}
}
