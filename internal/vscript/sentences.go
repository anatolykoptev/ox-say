package vscript

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// Sentences splits one paragraph: a candidate boundary after every run of
// terminal punctuation (and the closing quotes/brackets after it), rejoined
// by six of razdel's rules (github.com/natasha/razdel, MIT; NOTICE). A line
// break is a boundary when the line ends without punctuation and the next
// starts upper-case, a digit or a dash (headings, list lines); otherwise a
// space (hard-wrapped text).
func Sentences(paragraph string) []string {
	rs := []rune(strings.TrimSpace(paragraph))
	var out []string
	start := 0
	for i := 0; i < len(rs); i++ {
		switch {
		case rs[i] == '\n':
			if lineBreakSplits(rs, start, i) {
				out = appendSentence(out, rs[start:i])
				start = i + 1
			} else {
				rs[i] = ' '
			}
		case isTerminal(rs[i]):
			end := delimiterEnd(rs, i)
			if end < len(rs) && !joins(rs, i, end) {
				out = appendSentence(out, rs[start:end])
				start = end
			}
			i = end - 1
		}
	}
	return appendSentence(out, rs[start:])
}

func appendSentence(out []string, rs []rune) []string {
	if s := strings.Join(strings.Fields(string(rs)), " "); s != "" {
		out = append(out, s)
	}
	return out
}

func isTerminal(r rune) bool { return strings.ContainsRune(".!?…", r) }
func isClosing(r rune) bool  { return strings.ContainsRune("»\"”')]", r) }
func isDash(r rune) bool     { return strings.ContainsRune("—–-", r) }

func delimiterEnd(rs []rune, i int) int {
	j := i
	for j < len(rs) && isTerminal(rs[j]) {
		j++
	}
	for j < len(rs) && isClosing(rs[j]) {
		j++
	}
	return j
}

// joins applies the six rejoin rules to the candidate boundary rs[i:end].
func joins(rs []rune, i, end int) bool {
	if !unicode.IsSpace(rs[end]) {
		return true // 1 no space after: "0.5", "т.е.", "?!»,"
	}
	j := end
	for j < len(rs) && unicode.IsSpace(rs[j]) {
		j++
	}
	if j >= len(rs) {
		return true
	}
	next := rs[j]
	switch {
	case unicode.IsLower(next):
		return true // 2 lower case on the right
	case strings.ContainsRune(",;:", next) || isTerminal(next):
		return true // 3 a delimiter on the right
	case isDash(next) && lowerAfter(rs, j+1):
		return true // 4 dialogue attribution: «Как же так?!» — воскликнул он.
	}
	if rs[i] != '.' || end-i > 1 {
		return false
	}
	left := leftToken(rs, i)
	if abbreviations[strings.ToLower(left)] || abbreviations[strings.ToLower(spacedPair(rs, i, left))] {
		return true // 5 an abbreviation on the left ("т.е", "г", "ул", spaced "т. е")
	}
	r := []rune(left)
	return len(r) == 1 && unicode.IsUpper(r[0]) // 6 an initial: «А. С. Пушкин»
}

// leftToken is the run of letters, digits and inner dots ending before i.
func leftToken(rs []rune, i int) string {
	j := i
	for j > 0 && (unicode.IsLetter(rs[j-1]) || unicode.IsDigit(rs[j-1]) || rs[j-1] == '.') {
		j--
	}
	return strings.Trim(string(rs[j:i]), ".")
}

// spacedPair rebuilds a pair abbreviation typed with a space after its inner
// dot: a one-letter left "е" after "т. " gives "т.е". "" when no such prefix precedes it.
func spacedPair(rs []rune, i int, left string) string {
	if utf8.RuneCountInString(left) != 1 {
		return ""
	}
	j := i - 1
	k := j
	for k > 0 && unicode.IsSpace(rs[k-1]) {
		k--
	}
	if k == j || k == 0 || rs[k-1] != '.' {
		return ""
	}
	return leftToken(rs, k-1) + "." + left
}

func lowerAfter(rs []rune, k int) bool {
	for k < len(rs) && unicode.IsSpace(rs[k]) {
		k++
	}
	return k < len(rs) && unicode.IsLower(rs[k])
}

func lineBreakSplits(rs []rune, start, nl int) bool {
	line := []rune(strings.TrimSpace(string(rs[start:nl])))
	if len(line) == 0 {
		return false
	}
	if last := line[len(line)-1]; isTerminal(last) || strings.ContainsRune(",;:-–—(", last) {
		return false
	}
	k := nl + 1
	for k < len(rs) && (rs[k] == ' ' || rs[k] == '\t') {
		k++
	}
	return k < len(rs) && (unicode.IsUpper(rs[k]) || unicode.IsDigit(rs[k]) || isDash(rs[k]))
}
