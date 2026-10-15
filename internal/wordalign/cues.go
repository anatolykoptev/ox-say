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
// punctuation, or before the next word would pass MaxCueChars or
// MaxCueSeconds; a cue over MaxCueLine wraps at the space nearest its middle.
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
		if len(cur) > 0 && (utf8.RuneCountInString(strings.Join(cur, " "))+1+utf8.RuneCountInString(w.W) > MaxCueChars || w.E-s > MaxCueSeconds) {
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

func wrap(s string) string {
	rs := []rune(s)
	if len(rs) <= MaxCueLine {
		return s
	}
	mid, best := len(rs)/2, -1
	for i, r := range rs {
		if r == ' ' && (best < 0 || absInt(i-mid) < absInt(best-mid)) {
			best = i
		}
	}
	if best < 0 {
		return s
	}
	return string(rs[:best]) + "\n" + string(rs[best+1:])
}

func absInt(x int) int {
	if x < 0 {
		return -x
	}
	return x
}
