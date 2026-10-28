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
// Mutation: internal/meeting/echo_match.go echoMatchAt, change the final
// `return lcs(...) == common || sharesBigram(...)` to `return false` -> RED
// (the echo stays in the transcript).
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
// Mutation: internal/meeting/echo_match.go echoMatchAt, change the final
// `return lcs(...) == common || sharesBigram(...)` to `return false` -> RED.
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

// #229: the owner talking OVER the far side with short, common words must not
// be judged an echo just because those words also occur in the far side's
// sentence. Realistic talk-over turns, en and ru.
// Mutation F1: internal/meeting/merge.go isEcho, replace the echoMatch call
// with `voices.WordShare(t.Text, near.String()) >= 0.7` -> RED.
func TestDropEchoKeepsTalkOverMadeOfCommonWords(t *testing.T) {
	cases := []struct{ name, them, me string }{
		{"en", "and that is why I do not think it is the right time to hire",
			"I do and that is the"},
		{"ru", "и поэтому я не думаю что это сейчас правильное время для найма",
			"и вот я не что это"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			them := spaced(0, 0.4, c.them)
			me := spaced(0.2, 0.4, c.me)
			got, dropped := DropEcho(MergeTurns(me, them))
			if len(got) != 2 || dropped != 0 {
				t.Fatalf("turns = %+v, dropped = %d; the owner's own turn must be kept", got, dropped)
			}
		})
	}
}

// Content words alone are not enough: the same words in another order, with no
// shared pair, are the owner listing items back, not a re-capture.
// Mutation F2: internal/meeting/merge.go isEcho, make echoMatch skip the
// order/bigram check (return the content-word share alone) -> RED.
func TestDropEchoKeepsContentWordsInAnotherOrder(t *testing.T) {
	cases := []struct{ name, them, me string }{
		{"en", "so the budget hiring timeline approval",
			"approval timeline hiring budget"},
		{"ru", "итак бюджет найм срок согласование",
			"согласование срок найм бюджет"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			them := spaced(0, 0.25, c.them)
			me := spaced(0.1, 0.25, c.me)
			got, dropped := DropEcho(MergeTurns(me, them))
			if len(got) != 2 || dropped != 0 {
				t.Fatalf("turns = %+v, dropped = %d; both must be kept", got, dropped)
			}
		})
	}
}

// A read-back of exactly three words (two of them content words) is still an
// echo; the gate must not demand four.
// Mutation F4: internal/meeting/merge.go, set echoMinWords to 4 -> RED.
func TestDropEchoRemovesAThreeWordReadBack(t *testing.T) {
	them := spaced(0, 0.4, "send the proposal")
	echo := spaced(0.2, 0.4, "send the proposal")
	got, dropped := DropEcho(MergeTurns(echo, them))
	if len(got) != 1 || got[0].Speaker != SpeakerThem || dropped != 1 {
		t.Fatalf("turns = %+v, dropped = %d; want only the far side, 1 dropped", got, dropped)
	}
}

// Merging relies on turns of one channel being more than 2*echoLatency apart,
// so the widened far-side turns in isEcho stay disjoint and overlap is not
// double-counted.
// Mutation F3: internal/meeting/merge.go, set echoLatency to 0.7 -> RED.
func TestTurnGapExceedsTwiceTheEchoLatency(t *testing.T) {
	gap, lat := turnGap, echoLatency
	if gap <= 2*lat {
		t.Fatalf("turnGap = %v must exceed 2*echoLatency = %v", gap, 2*lat)
	}
}

// Languages without a stopword list: common-word talk-over must still be kept,
// because the meeting's own frequent words count like stopwords. The meeting
// needs at least fnMinTurns turns to derive anything; fillerMeeting builds one
// from sentences of the language, far apart in time from the turn under test.
func fillerMeeting(sentences []string) (me, them []stt.Word) {
	at := 100.0
	for i, s := range sentences {
		if i%2 == 0 {
			them = append(them, spaced(at, 0.4, s)...)
		} else {
			me = append(me, spaced(at, 0.4, s)...)
		}
		at += 20
	}
	return
}

var langCases = []struct {
	name, far, talkOver, echo string
	filler                    []string
}{
	{"de", "das ist ja nicht so einfach wie ich es mir vorgestellt habe ich weiss es nicht",
		"ja ja das ist so ich weiss es", "wir müssen den termin auf ende nächsten monats verschieben",
		[]string{"das ist ja so ich weiss es nicht", "ich weiss das ist so schwierig", "ja das ist wirklich ein problem",
			"ich weiss es nicht das ist ja so", "es ist ja so wie es ist", "ja ich denke das ist so",
			"das ist so ich weiss", "ja es ist so", "ich weiss ja das ist es", "das ist ja nicht so", "ja ich weiss das ist es", "ist das so ja"}},
	{"es", "es que no lo se pero creo que de verdad podemos terminar el viernes",
		"si si es que no lo se de verdad", "tenemos que mover la fecha al final del próximo mes",
		[]string{"es que no lo se de verdad", "si es que no lo se", "no lo se es que de verdad", "si creo que es de verdad",
			"es que si no lo se", "no es que lo se de verdad", "si es de verdad que no", "es que no lo se si",
			"de verdad que no lo se", "si no lo se es que", "es que de verdad no lo se", "no se si es que de verdad"}},
	{"fr", "c'est pas ça que je voulais dire je sais bien que ce n'est pas simple",
		"oui oui c'est ça je sais bien", "nous devons repousser la date à la fin du mois prochain",
		[]string{"oui c'est ça je sais bien", "je sais bien que c'est ça", "oui je sais c'est bien ça", "c'est ça oui je sais",
			"bien sûr je sais c'est ça", "oui c'est bien ça je sais", "je sais bien oui c'est ça", "c'est bien ça je sais oui",
			"oui je sais bien c'est ça", "ça c'est bien je sais oui", "c'est oui je sais bien ça", "je sais c'est ça bien oui"}},
}

// Mutation: internal/meeting/merge.go DropEcho, pass `nil` instead of
// `frequentWords(turns)` to isEcho -> RED.
func TestDropEchoKeepsTalkOverInLanguagesWithoutAStopwordList(t *testing.T) {
	for _, c := range langCases {
		t.Run(c.name, func(t *testing.T) {
			fme, fthem := fillerMeeting(c.filler)
			them := append(spaced(0, 0.4, c.far), fthem...)
			me := append(spaced(0.2, 0.4, c.talkOver), fme...)
			got, dropped := DropEcho(MergeTurns(me, them))
			if dropped != 0 {
				t.Fatalf("dropped = %d, the owner's talk-over %q must be kept: %+v", dropped, c.talkOver, got)
			}
		})
	}
}

func TestDropEchoStillRemovesEchoInLanguagesWithoutAStopwordList(t *testing.T) {
	far := map[string]string{
		"de": "wir müssen den termin auf das ende des nächsten monats verschieben weil der lieferant spät ist",
		"es": "tenemos que mover la fecha límite al final del próximo mes porque el proveedor se retrasa",
		"fr": "nous devons repousser la date limite à la fin du mois prochain parce que le fournisseur est en retard",
	}
	for _, c := range langCases {
		t.Run(c.name, func(t *testing.T) {
			fme, fthem := fillerMeeting(c.filler)
			them := append(spaced(0, 0.4, far[c.name]), fthem...)
			me := append(spaced(0.2, 0.4, c.echo), fme...)
			got, dropped := DropEcho(MergeTurns(me, them))
			if dropped != 1 {
				t.Fatalf("dropped = %d, want the echo %q dropped: %+v", dropped, c.echo, got)
			}
		})
	}
}

// A meeting shorter than fnMinTurns derives no function words: with no list
// for its language the talk-over is judged on order alone. Pinned so the
// limit stays visible.
func TestFrequentWordsNeedsAMeetingOfMinimumSize(t *testing.T) {
	short := []Turn{{Text: "das ist so"}, {Text: "das ist ja"}, {Text: "das ist es"}}
	if got := frequentWords(short); got != nil {
		t.Fatalf("frequentWords of %d turns = %v, want nil", len(short), got)
	}
	long := make([]Turn, fnMinTurns)
	for i := range long {
		long[i] = Turn{Text: "das ist so"}
	}
	if !frequentWords(long)["das"] {
		t.Fatalf("a word in every turn of a %d-turn meeting must be frequent", fnMinTurns)
	}
}

// "ее" is how recognizers often spell "её".
// Mutation: internal/meeting/echo_match.go stopwords, remove "ее" -> RED.
func TestRussianStopwordsKnowTheYoSpelling(t *testing.T) {
	if got := contentTokens("её ее", nil); len(got) != 0 {
		t.Fatalf("contentTokens = %v, want none", got)
	}
}
