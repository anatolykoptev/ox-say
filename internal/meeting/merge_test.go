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
	got, _ := DropEcho(MergeTurns(append(echo, own...), them))
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
	got, _ := DropEcho(MergeTurns(me, them))
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
	got, _ := DropEcho(MergeTurns(echo, them))
	if len(got) != 1 || got[0].Speaker != SpeakerThem {
		t.Fatalf("turns = %+v, want only the far side's turn", got)
	}
}

func TestDropEchoIgnoresDistantSpeech(t *testing.T) {
	them := words(10, farSide)
	me := words(60, farSide) // the owner repeats it a minute later
	if got, _ := DropEcho(MergeTurns(me, them)); len(got) != 2 {
		t.Fatalf("turns = %+v, want both kept", got)
	}
}

// spaced builds one word per token, step seconds apart, each filling its slot.
func spaced(start, step float64, text string) []stt.Word {
	var out []stt.Word
	for i, tok := range strings.Fields(text) {
		s := start + float64(i)*step
		out = append(out, stt.Word{W: tok, S: s, E: s + step, P: 0.9})
	}
	return out
}

// The owner confirming what the far side just said is real speech: the words
// repeat, but they come AFTER the far side finished. 4 of the 5 words are in
// the them turn, so a flat "±3 s" window judges it an echo.
// Mutation: internal/meeting/merge.go, set echoLatency to 3.0 -> RED.
func TestDropEchoKeepsAConfirmationAfterTheFarSide(t *testing.T) {
	them := spaced(0, 0.5, "давайте тогда отправим предложение в пятницу до обеда") // 0-4 s
	me := spaced(4.5, 0.3, "да в пятницу до обеда")                                 // 4.5-6 s
	got, dropped := DropEcho(MergeTurns(me, them))
	if len(got) != 2 || dropped != 0 {
		t.Fatalf("turns = %+v, dropped = %d; the confirmation must be kept", got, dropped)
	}
}

// An acoustic echo is simultaneous with the far side: it starts a fraction of
// a second late and overlaps it.
// Mutation: internal/meeting/merge.go isEcho, change `>= echoShare` to `>= 2`
// -> RED.
func TestDropEchoRemovesAnEchoThatOverlapsTheFarSide(t *testing.T) {
	text := "давайте тогда отправим предложение в пятницу до обеда"
	them := spaced(0, 0.5, text)
	echo := spaced(0.2, 0.5, text)
	got, dropped := DropEcho(MergeTurns(echo, them))
	if len(got) != 1 || got[0].Speaker != SpeakerThem || dropped != 1 {
		t.Fatalf("turns = %+v, dropped = %d; want only the far side, 1 dropped", got, dropped)
	}
}

// A "me" turn that overlaps the far side (71% of its duration), but whose words are
// the far side's EARLIER words, repeats nothing that is happening alongside
// it: kept. The words it repeats lie outside the window around its own span.
// Mutation: internal/meeting/merge.go isEcho, make the near-word test accept
// every them word (drop the `lo`/`hi` window) -> RED.
func TestDropEchoKeepsATurnWhoseWordsMatchAnEarlierPart(t *testing.T) {
	them := spaced(0, 0.4, "we should ship the release on friday after the review is done") // 0-4.8 s
	me := spaced(3.6, 0.3, "we should ship the release on friday okay")                     // 3.6-6.0 s, 71% inside the far side + margin
	got, dropped := DropEcho(MergeTurns(me, them))
	if len(got) != 2 || dropped != 0 {
		t.Fatalf("turns = %+v, dropped = %d; want both kept", got, dropped)
	}
}

// Words that fall inside the latency margin but are not spoken alongside the
// turn do not make an echo: the far side finished just before the owner began.
// Mutation: internal/meeting/merge.go isEcho, drop the `overlap <
// echoOverlap*dur` check -> RED.
func TestDropEchoNeedsRealOverlapNotJustAMargin(t *testing.T) {
	them := spaced(1.6, 0.13, "send the proposal friday")
	me := spaced(2.2, 0.5, "send the proposal friday") // starts 0.1 s after them ends
	got, dropped := DropEcho(MergeTurns(me, them))
	if len(got) != 2 || dropped != 0 {
		t.Fatalf("turns = %+v, dropped = %d; want both kept", got, dropped)
	}
}

// The count lets the caller record WarnEchoDropped.
// Mutation: internal/meeting/merge.go DropEcho, delete `dropped++` -> RED.
func TestDropEchoCountsWhatItDrops(t *testing.T) {
	text := "so the plan is to ship the release on friday"
	them := append(spaced(0, 0.4, text), spaced(20, 0.4, text)...)
	me := append(spaced(0.2, 0.4, text), spaced(20.2, 0.4, text)...)
	me = append(me, spaced(40, 0.4, "I will prepare the changelog")...)
	got, dropped := DropEcho(MergeTurns(me, them))
	if dropped != 2 || len(got) != 3 {
		t.Fatalf("kept %d turns, dropped %d; want 3 kept (2 far side + own), 2 dropped", len(got), dropped)
	}
}
