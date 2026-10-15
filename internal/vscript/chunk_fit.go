package vscript

import (
	"strings"
	"unicode"
)

// fitted is a chunk's text and whether its numbers stay digits (plain): a chunk
// whose Spoken would exceed the engine cap and that has no safe place to split.
type fitted struct {
	text  string
	plain bool
}

func (p fitted) spoken() string {
	if p.plain {
		return spokenPlain(p.text)
	}
	return Spoken(p.text)
}

// fitSpoken splits every chunk whose Spoken text exceeds MaxSpokenChars (numbers
// written as words are several times longer than their digits) until each
// fits. Where it cannot split safely, the chunk is kept whole with its numbers
// left as digits (plain), which is at most MaxChars runes and so under the cap.
func fitSpoken(chunks []string, o Options) []fitted {
	var out []fitted
	for _, c := range chunks {
		if o.MaxSpokenChars <= 0 {
			out = append(out, fitted{text: c})
			continue
		}
		out = append(out, split(c, o.MaxSpokenChars)...)
	}
	return out
}

func split(text string, limit int) []fitted {
	if runes(Spoken(text)) <= limit {
		return []fitted{{text: text}}
	}
	cut := safeCut([]rune(text))
	if cut < 0 {
		return []fitted{{text: text, plain: true}}
	}
	rs := []rune(text)
	return append(split(strings.TrimSpace(string(rs[:cut])), limit), split(strings.TrimSpace(string(rs[cut:])), limit)...)
}

const (
	clauseEnds = ",;:—–"
	signs      = "%₽$€£°"
	quoteOpen  = '«'
	quoteClose = '»'
)

// cutKind ranks a cut: a clause boundary outside «quotes» is best.
type cutKind int

const (
	cutNone cutKind = iota
	cutSpaceInQuote
	cutSpace
	cutClauseInQuote
	cutClause
)

// safeCut is the index of the space to split rs at, nearest the middle among
// the best-ranked safe cuts, or -1. Order: after clause punctuation (, ; : —)
// outside quotes, the same inside quotes, any other space outside quotes, any
// other space. A cut after punctuation is exempt from the digit rule ("789, |
// 321" splits no number); any other cut is refused when the word on either
// side holds a digit or a sign, is a preposition, or is a month name — those
// words belong with their neighbour ("до | 5 минут", "50 | %", "к 12 | апреля").
func safeCut(rs []rune) int {
	best, bestKind, mid, depth := -1, cutNone, len(rs)/2, 0
	for i := 1; i < len(rs)-1; i++ {
		switch rs[i] {
		case quoteOpen:
			depth++
		case quoteClose:
			depth = max(depth-1, 0)
		}
		if rs[i] != ' ' {
			continue
		}
		k := rankCut(rs, i, depth > 0)
		if k == cutNone || k < bestKind || (k == bestKind && abs(i-mid) >= abs(best-mid)) {
			continue
		}
		best, bestKind = i, k
	}
	return best
}

func rankCut(rs []rune, i int, inQuote bool) cutKind {
	left, right := wordLeft(rs, i), wordRight(rs, i)
	if left == "" || right == "" {
		return cutNone
	}
	clause := strings.ContainsRune(clauseEnds, []rune(left)[len([]rune(left))-1]) || strings.ContainsRune("—–", []rune(right)[0])
	if clause {
		if strings.ContainsRune(signs, []rune(right)[0]) || months[bare(right)] {
			return cutNone
		}
		return pick(inQuote, cutClause, cutClauseInQuote)
	}
	for _, w := range []string{left, right} {
		if strings.ContainsFunc(w, unicode.IsDigit) || strings.ContainsAny(w, signs) || prepositions[bare(w)] || months[bare(w)] {
			return cutNone
		}
	}
	return pick(inQuote, cutSpace, cutSpaceInQuote)
}

func pick(inQuote bool, outside, inside cutKind) cutKind {
	if inQuote {
		return inside
	}
	return outside
}

func wordLeft(rs []rune, i int) string {
	j := i
	for j > 0 && rs[j-1] != ' ' {
		j--
	}
	return string(rs[j:i])
}

func wordRight(rs []rune, i int) string {
	j := i + 1
	for j < len(rs) && rs[j] != ' ' {
		j++
	}
	return string(rs[i+1 : j])
}

// bare is w lower-cased without surrounding punctuation and quotes.
func bare(w string) string {
	return strings.ToLower(strings.TrimFunc(w, func(r rune) bool { return !unicode.IsLetter(r) && r != '-' }))
}
