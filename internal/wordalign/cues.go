package wordalign

import (
	"strings"
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
	for _, w := range words {
		if len(cur) > 0 && (utf8.RuneCountInString(strings.Join(cur, " "))+1+utf8.RuneCountInString(w.W) > MaxCueChars ||
			!fits(strings.Join(cur, " ")+" "+w.W) || w.E-s > MaxCueSeconds) {
			flush()
		}
		if len(cur) == 0 {
			s = w.S
		}
		cur, e = append(cur, w.W), w.E
		if t := []rune(strings.TrimRight(w.W, "»\"”')")); len(t) > 0 && strings.ContainsRune(".!?…", t[len(t)-1]) {
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
