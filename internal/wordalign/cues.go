package wordalign

import (
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// Subtitle limits: two lines of 42 characters, at most 6 s on screen.
const (
	MaxCueChars   = 84
	MaxCueLine    = 42
	MaxCueSeconds = 6.0
)

// Cue is one subtitle.
type Cue struct {
	S, E float64
	Text string
}

// Cues groups timed written words: a cue ends after a word with terminal
// punctuation, or before the next word would pass MaxCueChars, two lines of
// MaxCueLine or MaxCueSeconds; a cue over MaxCueLine wraps greedily.
func Cues(words []voices.Word) []Cue {
	var out []Cue
	var cur []string
	var s, e float64
	flush := func() {
		if len(cur) > 0 {
			out = append(out, Cue{s, e, wrap(strings.Join(cur, " "))})
			cur = nil
		}
	}
	for wi, w := range words {
		if len(cur) > 0 && (utf8.RuneCountInString(strings.Join(cur, " "))+1+utf8.RuneCountInString(w.W) > MaxCueChars ||
			!fits(strings.Join(cur, " ")+" "+w.W) || w.E-s > MaxCueSeconds) {
			flush()
		}
		if len(cur) == 0 {
			s = w.S
		}
		cur, e = append(cur, w.W), w.E
		if t := []rune(strings.TrimRight(w.W, "»\"”')")); len(t) > 0 && strings.ContainsRune(".!?…", t[len(t)-1]) {
			if wi+1 < len(words) && continuesAfterAbbrev(w.W, words[wi+1].W) {
				continue
			}
			flush()
		}
	}
	flush()
	return out
}

// wrapLines fills lines greedily up to MaxCueLine characters; a word longer
// than the limit gets a line of its own.
func wrapLines(s string) []string {
	var lines []string
	line, n := "", 0
	for _, w := range strings.Fields(s) {
		wn := utf8.RuneCountInString(w)
		if n > 0 && n+1+wn > MaxCueLine {
			lines = append(lines, line)
			line, n = "", 0
		}
		if n > 0 {
			line, n = line+" ", n+1
		}
		line, n = line+w, n+wn
	}
	if n > 0 {
		lines = append(lines, line)
	}
	return lines
}

// fits reports whether s shows as at most two lines; greedy lines never pass
// MaxCueLine except a single word longer than a line.
func fits(s string) bool { return len(wrapLines(s)) <= 2 }

func wrap(s string) string { return strings.Join(wrapLines(s), "\n") }

// neverEnd are abbreviations whose dot never closes a sentence; mayEnd ones
// close it only when the next word starts a sentence (capital letter).
var (
	neverEnd = map[string]bool{"мр.": true, "мрс.": true, "г-н.": true, "проф.": true, "акад.": true, "доц.": true, "им.": true, "св.": true,
		"т.е.": true, "т.к.": true, "т.н.": true, "т.ч.": true, "напр.": true, "ул.": true, "пр.": true, "пер.": true, "пл.": true,
		"кв.": true, "корп.": true, "стр.": true, "рис.": true, "см.": true, "ср.": true, "dr.": true, "mr.": true, "mrs.": true, "st.": true, "e.g.": true, "i.e.": true}
	mayEnd = map[string]bool{"т.д.": true, "т.п.": true, "др.": true, "руб.": true, "коп.": true, "тыс.": true, "млн.": true, "млрд.": true,
		"трлн.": true, "etc.": true, "vs.": true, "г.": true, "гг.": true}
)

// continuesAfterAbbrev reports whether the dot ending w is an abbreviation's
// and the cue goes on with next.
func continuesAfterAbbrev(w, next string) bool {
	lw := strings.ToLower(strings.TrimLeft(w, "«\"“(("))
	if neverEnd[lw] {
		return true
	}
	if !mayEnd[lw] {
		return false
	}
	r, _ := utf8.DecodeRuneInString(strings.TrimLeft(next, "«\"“(—–"))
	return !unicode.IsUpper(r)
}
