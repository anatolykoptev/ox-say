package meeting

import (
	"math"
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
	// Words keeps the timing DropEcho needs; it is not written to the
	// transcript. A turn without words is never judged an echo.
	Words []stt.Word `json:"-"`
}

const (
	// turnGap: silence inside one channel longer than this ends a turn.
	turnGap = 1.2
	// echoLatency: how far outside a "me" turn's own span a "them" word may
	// lie and still count as the sound it re-captured. The speakers-to-mic
	// delay is ~0.05-0.3 s and word timestamps jitter by about as much, so
	// 0.5 s covers both; a larger margin starts matching the owner's reply
	// that follows the far side's sentence (a confirmation is sequential).
	echoLatency = 0.5
	// echoOverlap: the far side, each turn widened by echoLatency, must cover
	// at least this share of the "me" turn's duration. An echo is
	// simultaneous with its source.
	echoOverlap = 0.5
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
	var curW []stt.Word
	var s, e float64
	flush := func() {
		if len(cur) > 0 {
			out = append(out, Turn{Speaker: speaker, S: s, E: e, Text: strings.Join(cur, " "), Words: curW})
			cur, curW = nil, nil
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
		curW = append(curW, w)
		e = w.E
	}
	flush()
	return out
}

// DropEcho removes "me" turns that repeat the "them" speech around them: on
// speakers the microphone re-captures the far side, and the recognizer then
// writes the other person's words twice, once under each name. It returns the
// turns that remain and how many it dropped, so the caller can record
// WarnEchoDropped: a dropped turn is otherwise invisible in the transcript.
func DropEcho(turns []Turn) ([]Turn, int) {
	out := make([]Turn, 0, len(turns))
	dropped := 0
	for _, t := range turns {
		if t.Speaker == SpeakerMe && isEcho(t, turns) {
			dropped++
			continue
		}
		out = append(out, t)
	}
	return out, dropped
}

// isEcho: a "me" turn of at least echoMinWords words is an echo when
//  1. at least echoShare of its words are among the "them" words spoken inside
//     [t.S-echoLatency, t.E+echoLatency] (a word counts by its midpoint), and
//  2. "them" turns, each widened by echoLatency on both sides, cover at least
//     echoOverlap of t's own duration. (Widened turns stay disjoint: turns in
//     a channel are more than turnGap > 2*echoLatency apart.)
//
// Both together mean the far side was talking AT THE SAME TIME as t, which is
// what an acoustic echo is. The owner repeating or confirming what the other
// person just finished ("да, в пятницу до обеда") matches the words but fails
// the time test and is kept.
func isEcho(t Turn, all []Turn) bool {
	dur := t.E - t.S
	if len(strings.Fields(t.Text)) < echoMinWords || dur <= 0 {
		return false
	}
	lo, hi := t.S-echoLatency, t.E+echoLatency
	var near strings.Builder
	var overlap float64
	for _, u := range all {
		if u.Speaker != SpeakerThem {
			continue
		}
		for _, w := range u.Words {
			if mid := (w.S + w.E) / 2; mid >= lo && mid <= hi {
				near.WriteString(w.W)
				near.WriteByte(' ')
			}
		}
		overlap += math.Max(0, math.Min(u.E+echoLatency, t.E)-math.Max(u.S-echoLatency, t.S))
	}
	if overlap < echoOverlap*dur {
		return false
	}
	return voices.WordShare(t.Text, near.String()) >= echoShare
}
