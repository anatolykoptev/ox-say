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
// Mutations (each RED):
//   - internal/meeting/merge.go DropEcho, replace `out = append(out, rest...)`
//     with `_ = rest` (a turn that held echo is dropped whole, as before) ->
//     "echo and a short answer";
//   - internal/meeting/echo_words.go alignedWords, drop `&& together(me[i],
//     far[j])` from pair -> "owner words that also occur in the question, said
//     later";
//   - internal/meeting/echo_words.go echoWords, make garbled return true ->
//     the backchannel and "owner word(s) inside the echo" rows;
//   - the same, returning false -> "garbled last echo word".
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
		{
			// The recognizer misspelled the last echo word; it is a near-match
			// of the far-side word spoken then, so it goes with the echo.
			name:        "garbled last echo word",
			them:        spaced(10, 0.4, question),
			me:          spaced(10.2, 0.4, "so is everything good with the new relese"),
			wantMe:      nil,
			wantChanged: 1,
		},
		// The owner's backchannel next to an echo is the owner's, even while
		// the far side is still talking: only a word that is evidence of an
		// echo of a specific far-side word goes.
		{
			name:        "backchannel before the echo",
			them:        spaced(10, 0.4, question),
			me:          cat(spaced(10, 0.4, "yeah"), spaced(10.8, 0.4, "everything good with the new release")),
			wantMe:      []string{"yeah"},
			wantChanged: 1,
		},
		{
			name:        "backchannel after the echo while the far side goes on",
			them:        spaced(10, 0.4, question+" and then we can ship"),
			me:          cat(spaced(10.2, 0.4, question), spaced(13.4, 0.3, "right")),
			wantMe:      []string{"right"},
			wantChanged: 1,
		},
		{
			name:        "backchannel before the echo, ru",
			them:        spaced(10, 0.4, "давайте тогда отправим предложение в пятницу до обеда"),
			me:          cat(spaced(10, 0.3, "да"), spaced(10.9, 0.4, "отправим предложение в пятницу до обеда")),
			wantMe:      []string{"да"},
			wantChanged: 1,
		},
		{
			// "good" is in the question, but 1 s earlier than the owner says
			// it: not an echo of it.
			name: "owner words that also occur in the question, said later",
			them: spaced(10, 0.4, question),
			me: cat(spaced(10.2, 0.4, "so is everything"), []stt.Word{
				{W: "yeah", S: 12.0, E: 12.2, P: 0.9}, {W: "good", S: 12.3, E: 12.6, P: 0.9}, {W: "ok", S: 12.7, E: 13.0, P: 0.9}}),
			wantMe:      []string{"yeah good ok"},
			wantChanged: 1,
		},
		{
			name:        "owner word inside the echo",
			them:        spaced(10, 0.4, question),
			me:          cat(spaced(10.2, 0.4, "so is everything"), spaced(11.4, 0.4, "yeah"), spaced(11.8, 0.4, "with the new release")),
			wantMe:      []string{"yeah"},
			wantChanged: 1,
		},
		{
			name:        "owner words inside the echo, two of them",
			them:        spaced(10, 0.4, question),
			me:          cat(spaced(10.2, 0.4, "so is everything"), spaced(11.4, 0.2, "no wait"), spaced(11.8, 0.4, "with the new release")),
			wantMe:      []string{"no wait"},
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
