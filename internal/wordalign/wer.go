// Package wordalign compares a script with what speech-to-text heard: word
// error rate, word timings for the script's own words, subtitle cues.
package wordalign

import (
	"regexp"
	"strings"
	"unicode"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

const (
	// maxNumberWords caps how many spoken words one written number may stand
	// for, whatever its digit count.
	maxNumberWords = 8
	// wordsPerDigit is how many spoken words one digit may account for.
	wordsPerDigit = 2
)

var (
	digitGroups = regexp.MustCompile(`[0-9]+(?:[ \x{00a0}\x{202f}][0-9]+)*`)
	digitSuffix = regexp.MustCompile(`([0-9])-(\p{L})`)
	signGap     = regexp.MustCompile(`([0-9])[ \x{00a0}\x{202f}]+([%₽°$€])`)
	signLetter  = regexp.MustCompile(`([%₽°$€])(\p{L})`)
	// breveMark is и + combining breve, which stripping marks would turn into и.
	breveMark = "и\u0306"
)

const (
	groupSize     = 3 // digits in every group after the first of "1 000 000"
	signRunes     = "%₽°$€"
	softHyphen    = '\u00ad'
	rightQuote    = '’'
	maxFirstGroup = 3
)

func isDigit(r rune) bool { return unicode.IsDigit(r) }

// joinDigitGroups turns "1 000 000" (space, NBSP or narrow NBSP between groups
// of exactly three digits after a first group of at most three) into 1000000.
func joinDigitGroups(s string) string {
	return digitGroups.ReplaceAllStringFunc(s, func(run string) string {
		groups := strings.FieldsFunc(run, func(r rune) bool { return !unicode.IsDigit(r) })
		var out []string
		acc, ok := groups[0], len(groups[0]) <= maxFirstGroup
		for _, g := range groups[1:] {
			if ok && len(g) == groupSize {
				acc += g
				continue
			}
			out = append(out, acc)
			acc, ok = g, len(g) <= maxFirstGroup
		}
		return strings.Join(append(out, acc), " ")
	})
}

// normalise lower-cases, folds ё → е and ’ → ', drops combining marks and soft
// hyphens, and glues the pieces of one written number: digit groups, a digit
// with its "-го"/"-х" suffix, and a number with its % ₽ ° $ € sign.
func normalise(text string) string {
	t := strings.ReplaceAll(strings.ToLower(text), breveMark, "й")
	t = strings.Map(func(r rune) rune {
		switch {
		case r == 'ё':
			return 'е'
		case r == rightQuote:
			return '\''
		case r == softHyphen || unicode.Is(unicode.Mn, r):
			return -1
		}
		return r
	}, t)
	t = joinDigitGroups(t)
	t = digitSuffix.ReplaceAllString(t, "$1$2")
	t = signGap.ReplaceAllString(t, "$1$2")
	return signLetter.ReplaceAllString(t, "$1 $2")
}

// Words normalises text for comparison (see normalise) and splits it on every
// rune that is not a letter, digit, apostrophe or sign. A range "10–15" stays
// two numbers.
func Words(text string) []string {
	f := strings.FieldsFunc(normalise(text), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '\'' && !strings.ContainsRune(signRunes, r)
	})
	out := f[:0]
	for _, w := range f {
		if w = strings.Trim(w, "'"); w != "" {
			out = append(out, w)
		}
	}
	return out
}

// numberSpan is how many words a token with digits may match: wordsPerDigit
// per digit, at most maxNumberWords; 0 for a token without digits.
func numberSpan(w string) int {
	d := 0
	for _, r := range w {
		if unicode.IsDigit(r) {
			d++
		}
	}
	return min(maxNumberWords, wordsPerDigit*d)
}

type step struct{ di, dj int8 }

// werDP aligns ref with hyp. Substitution, deletion, insertion cost 1; an
// ASR spelling slip (voices.SameWord) costs 0; a digit token on either side
// matches 1..numberSpan tokens of the other side, free when they are numeral
// words (TTS and STT each write numbers as digits or words; the number itself
// is not checked) and 1 per other word (see spanCost).
func werDP(ref, hyp []string) ([][]int, [][]step) {
	cost := make([][]int, len(ref)+1)
	move := make([][]step, len(ref)+1)
	for i := range cost {
		cost[i] = make([]int, len(hyp)+1)
		move[i] = make([]step, len(hyp)+1)
	}
	for i := 1; i <= len(ref); i++ {
		cost[i][0], move[i][0] = i, step{1, 0}
	}
	for j := 1; j <= len(hyp); j++ {
		cost[0][j], move[0][j] = j, step{0, 1}
	}
	for i := 1; i <= len(ref); i++ {
		for j := 1; j <= len(hyp); j++ {
			cost[i][j], move[i][j] = cell(ref, hyp, cost, i, j)
		}
	}
	return cost, move
}

func cell(ref, hyp []string, cost [][]int, i, j int) (int, step) {
	sub := 1
	if voices.SameWord(ref[i-1], hyp[j-1]) {
		sub = 0
	}
	best, mv := cost[i-1][j-1]+sub, step{1, 1}
	if c := cost[i-1][j] + 1; c < best {
		best, mv = c, step{1, 0}
	}
	if c := cost[i][j-1] + 1; c < best {
		best, mv = c, step{0, 1}
	}
	for k := 1; k <= numberSpan(ref[i-1]) && k <= j; k++ {
		if c := cost[i-1][j-k] + spanCost(ref[i-1], hyp[j-k:j]); c < best {
			best, mv = c, step{1, int8(k)}
		}
	}
	for k := 1; k <= numberSpan(hyp[j-1]) && k <= i; k++ {
		if c := cost[i-k][j-1] + spanCost(hyp[j-1], ref[i-k:i]); c < best {
			best, mv = c, step{int8(k), 1}
		}
	}
	return best, mv
}

// WER returns the word errors of hyp against ref and the reference length.
func WER(ref, hyp string) (errs, n int) {
	r, h := Words(ref), Words(hyp)
	cost, _ := werDP(r, h)
	return cost[len(r)][len(h)], len(r)
}
