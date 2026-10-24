package meeting

import (
	"sort"
	"strings"

	"github.com/anatolykoptev/ox-say/internal/stt"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

// Speakers of a Turn.
const (
	SpeakerMe   = "me"
	SpeakerThem = "them"
)

// Turn is one stretch of one person talking.
type Turn struct {
	Speaker string  `json:"speaker"`
	S       float64 `json:"s"`
	E       float64 `json:"e"`
	Text    string  `json:"text"`
}

const (
	// turnGap: silence inside one channel longer than this ends a turn.
	turnGap = 1.2
	// echoWindow: a "them" turn within this many seconds of a "me" turn can be
	// its echo (the speakers' sound reaching the microphone, slightly late).
	echoWindow = 3.0
	// echoMinWords: a shorter "me" turn ("yes", "okay, sure") is never judged
	// an echo — it is too short to tell from an answer.
	echoMinWords = 3
	// echoShare: this share of a "me" turn's words also present in the nearby
	// "them" speech makes it an echo.
	echoShare = 0.7
)

// MergeTurns groups each channel's words into turns and orders all turns by
// start time. A pause longer than turnGap inside a channel starts a new turn.
func MergeTurns(me, them []stt.Word) []Turn {
	turns := append(group(me, SpeakerMe), group(them, SpeakerThem)...)
	sort.SliceStable(turns, func(i, j int) bool { return turns[i].S < turns[j].S })
	return turns
}

func group(words []stt.Word, speaker string) []Turn {
	var out []Turn
	var cur []string
	var s, e float64
	flush := func() {
		if len(cur) > 0 {
			out = append(out, Turn{Speaker: speaker, S: s, E: e, Text: strings.Join(cur, " ")})
			cur = nil
		}
	}
	for _, w := range words {
		text := strings.TrimSpace(w.W)
		if text == "" {
			continue
		}
		if len(cur) > 0 && w.S-e > turnGap {
			flush()
		}
		if len(cur) == 0 {
			s = w.S
		}
		cur = append(cur, text)
		e = w.E
	}
	flush()
	return out
}

// DropEcho removes "me" turns that repeat the "them" speech around them: on
// speakers the microphone re-captures the far side, and the recognizer then
// writes the other person's words twice, once under each name.
func DropEcho(turns []Turn) []Turn {
	out := make([]Turn, 0, len(turns))
	for _, t := range turns {
		if t.Speaker == SpeakerMe && isEcho(t, turns) {
			continue
		}
		out = append(out, t)
	}
	return out
}

func isEcho(t Turn, all []Turn) bool {
	if len(strings.Fields(t.Text)) < echoMinWords {
		return false
	}
	var near strings.Builder
	for _, u := range all {
		if u.Speaker == SpeakerThem && u.E >= t.S-echoWindow && u.S <= t.E+echoWindow {
			near.WriteString(u.Text)
			near.WriteByte(' ')
		}
	}
	return voices.WordShare(t.Text, near.String()) >= echoShare
}
