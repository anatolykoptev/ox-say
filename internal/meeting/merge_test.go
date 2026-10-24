package meeting

import (
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// words builds one word per token, 0.4 s apart from start.
func words(start float64, text string) []stt.Word {
	var out []stt.Word
	for i, tok := range strings.Fields(text) {
		s := start + float64(i)*0.4
		out = append(out, stt.Word{W: tok, S: s, E: s + 0.3, P: 0.9})
	}
	return out
}

func TestMergeTurnsInterleavesByStart(t *testing.T) {
	me := append(words(0, "hello there how are you"), words(10, "fine thanks")...)
	them := words(3, "good morning everyone")
	got := MergeTurns(me, them)
	want := []struct{ who, text string }{
		{SpeakerMe, "hello there how are you"},
		{SpeakerThem, "good morning everyone"},
		{SpeakerMe, "fine thanks"},
	}
	if len(got) != len(want) {
		t.Fatalf("turns = %+v", got)
	}
	for i, w := range want {
		if got[i].Speaker != w.who || got[i].Text != w.text {
			t.Errorf("turn %d = %+v, want %s %q", i, got[i], w.who, w.text)
		}
	}
}

// A pause longer than turnGap inside one channel is a new turn.
// Mutation: internal/meeting/merge.go group, change `w.S-e > turnGap` to
// `w.S-e > 100` -> RED (the two sentences fuse into one turn).
func TestMergeTurnsSplitsOnAPause(t *testing.T) {
	me := append(words(0, "first part"), words(5, "second part")...)
	if got := MergeTurns(me, nil); len(got) != 2 {
		t.Fatalf("turns = %+v, want 2", got)
	}
}

const farSide = "so the plan is to ship the release on friday after the review"

// On speakers the microphone hears the far side a moment late; that echo is
// dropped, the owner's own sentence is kept.
// Mutation: internal/meeting/merge.go isEcho, change `>= echoShare` to
// `>= 2` -> RED (the echo stays in the transcript).
func TestDropEchoRemovesTheFarSideHeardOnTheMic(t *testing.T) {
	them := words(10, farSide)
	echo := words(10.3, "plan is to ship the release on friday after review") // recognizer dropped two words
	own := words(20, "I will prepare the changelog tonight")
	got := DropEcho(MergeTurns(append(echo, own...), them))
	var me []string
	for _, tu := range got {
		if tu.Speaker == SpeakerMe {
			me = append(me, tu.Text)
		}
	}
	if len(me) != 1 || me[0] != "I will prepare the changelog tonight" {
		t.Fatalf("me turns after DropEcho = %q, want only the owner's sentence", me)
	}
	if got[0].Speaker != SpeakerThem {
		t.Fatalf("the far side's turn must survive: %+v", got)
	}
}

// A short answer that happens to repeat what the other side just said is a
// real answer, not an echo. WordShare("by friday", long) is 1, so the minimum
// word count is the only thing keeping this turn.
// Mutation: internal/meeting/merge.go, set echoMinWords to 1 -> RED.
func TestDropEchoKeepsAShortAnswer(t *testing.T) {
	them := words(10, "can you send the proposal by friday")
	me := words(11, "by friday")
	got := DropEcho(MergeTurns(me, them))
	if len(got) != 2 {
		t.Fatalf("turns = %+v, want both kept", got)
	}
}

// The minimum is inclusive: a turn of exactly echoMinWords words that repeats
// the far side is judged, and dropped.
// Mutation: internal/meeting/merge.go isEcho, change `< echoMinWords` to
// `<= echoMinWords` -> RED (a three-word echo stays).
func TestDropEchoJudgesATurnAtTheMinimumLength(t *testing.T) {
	them := words(10, "please send the proposal by friday")
	echo := words(10.3, "send the proposal")
	got := DropEcho(MergeTurns(echo, them))
	if len(got) != 1 || got[0].Speaker != SpeakerThem {
		t.Fatalf("turns = %+v, want only the far side's turn", got)
	}
}

func TestDropEchoIgnoresDistantSpeech(t *testing.T) {
	them := words(10, farSide)
	me := words(60, farSide) // the owner repeats it a minute later
	if got := DropEcho(MergeTurns(me, them)); len(got) != 2 {
		t.Fatalf("turns = %+v, want both kept", got)
	}
}
