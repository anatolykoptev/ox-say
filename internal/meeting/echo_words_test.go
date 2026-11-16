package meeting

import (
	"slices"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// meTexts is the text of every "me" turn, in order.
func meTexts(turns []Turn) []string {
	var out []string
	for _, t := range turns {
		if t.Speaker == SpeakerMe {
			out = append(out, t.Text)
		}
	}
	return out
}

func cat(parts ...[]stt.Word) []stt.Word {
	var out []stt.Word
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

// Echo is removed per word: the owner's words survive next to it, a turn that
// is nothing but echo disappears, and what the owner says after, or over, the
// far side is kept.
//
// Mutation (test 1 must go RED): internal/meeting/merge.go DropEcho, delete
// `out = append(out, rest...)` so a turn that held echo is dropped whole, as
// before the word-level gate -> "echo and a short answer" loses the answer.
func TestDropEchoWorksOnWords(t *testing.T) {
	question := "so is everything good with the new release"
	cases := []struct {
		name        string
		them, me    []stt.Word
		wantMe      []string
		wantChanged int
	}{
		{
			// The microphone hears the question 0.2 s late; the owner answers
			// right after it, within turnGap, so the recognizer writes all of
			// it as one "me" turn. "good" is in the question too, but at
			// another time.
			name:        "echo and a short answer",
			them:        spaced(10, 0.4, question),
			me:          cat(spaced(10.2, 0.4, question), spaced(14.0, 0.4, "I'm good yeah")),
			wantMe:      []string{"I'm good yeah"},
			wantChanged: 1,
		},
		{
			name:        "pure echo",
			them:        spaced(10, 0.4, question),
			me:          spaced(10.2, 0.4, question),
			wantMe:      nil,
			wantChanged: 1,
		},
		{
			// The owner says the sentence AFTER the far side finished.
			name:        "repeat after the far side finished",
			them:        spaced(0, 0.5, "давайте тогда отправим предложение в пятницу до обеда"),
			me:          spaced(4.5, 0.3, "да в пятницу до обеда"),
			wantMe:      []string{"да в пятницу до обеда"},
			wantChanged: 0,
		},
		{
			name:        "talk-over with different words",
			them:        spaced(10, 0.4, question),
			me:          spaced(10.6, 0.4, "wait I need to check the budget first"),
			wantMe:      []string{"wait I need to check the budget first"},
			wantChanged: 0,
		},
		{
			// The owner talks, the far side's sentence leaks in the middle,
			// the owner goes on.
			name:        "echo in the middle of the owner's sentence",
			them:        spaced(10, 0.4, "we should move the launch to next friday afternoon"),
			me:          cat(spaced(8, 0.4, "okay so let me think"), spaced(10.2, 0.4, "we should move the launch to next friday afternoon"), spaced(14.2, 0.4, "that works for me")),
			wantMe:      []string{"okay so let me think", "that works for me"},
			wantChanged: 1,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, changed := DropEcho(MergeTurns(c.me, c.them))
			if me := meTexts(got); !slices.Equal(me, c.wantMe) || changed != c.wantChanged {
				t.Fatalf("me turns = %q, changed = %d; want %q, %d\nall: %+v", me, changed, c.wantMe, c.wantChanged, got)
			}
			far := 0
			for _, tu := range got {
				if tu.Speaker == SpeakerThem {
					far++
				}
			}
			if far != 1 {
				t.Fatalf("the far side's turn must survive untouched: %+v", got)
			}
			if !slices.IsSortedFunc(got, func(a, b Turn) int {
				switch {
				case a.S < b.S:
					return -1
				case a.S > b.S:
					return 1
				}
				return 0
			}) {
				t.Fatalf("turns are not in time order: %+v", got)
			}
		})
	}
}
