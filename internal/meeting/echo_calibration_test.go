package meeting

import (
	"fmt"
	"math/rand"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// Calibration of echoContentShare (#229). The first gate shared one 0.7
// threshold between all words; with stopwords removed the same threshold is far
// stricter on speaker echo, whose content words the recognizer garbles most.
// This test is the gate for the chosen value, on both sides:
//   - echo: at 10% and 20% content-word error the new gate must drop at least
//     as many re-captured far-side turns as the old gate (WordShare >= 0.7),
//     within calibEchoSlack;
//     slices with fewer than two content words are left out of the count, as
//     such a read-back of common words is by design no longer dropped;
//   - talk-over: the owner's own turns with content words, spoken over the far
//     side, must not be dropped (at most calibMaxFalseDrops of 32).
//
// Echo model: a contiguous slice (>= 3 words) of a far-side sentence, each
// content word replaced by a garbled form with the error probability, each
// stopword with a fifth of it (seed fixed, so deterministic).

const oldGateShare = 0.7 // the pre-#229 WordShare threshold, the baseline

const calibMaxFalseDrops = 1

const calibEchoSlack = 0.01

var calibFarEN = []string{
	"so the plan is to ship the release on friday after the review is done",
	"we need to move the deadline to the end of next month because the vendor is late",
	"can you send me the updated budget for the third quarter before the meeting tomorrow",
	"i think the main problem is that nobody owns the migration and the customers are waiting",
	"the server went down at three in the morning and the pager did not go off",
	"let us schedule a follow up call with the design team on tuesday at ten",
	"there are twenty five people on the list and only twelve of them have confirmed",
	"our revenue grew by fifteen percent compared to last year which is better than expected",
}

var calibFarRU = []string{
	"значит план такой что мы выпускаем релиз в пятницу после того как закончится ревью",
	"нам нужно перенести дедлайн на конец следующего месяца потому что поставщик задерживает",
	"можешь прислать мне обновлённый бюджет на третий квартал до завтрашней встречи",
	"я думаю главная проблема в том что никто не отвечает за миграцию а клиенты ждут",
	"сервер упал в три часа ночи и дежурному никто не позвонил",
	"давай назначим повторный созвон с командой дизайна во вторник в десять утра",
	"в списке двадцать пять человек и только двенадцать из них подтвердили участие",
	"выручка выросла на пятнадцать процентов по сравнению с прошлым годом это лучше чем ожидалось",
}

// talkOver: the far side, and the owner speaking over it. Realistic replies
// that reuse a few of the far side's words; several are partial agreement.
type talkOver struct{ far, me string }

var calibTalkEN = []talkOver{
	{calibFarEN[0], "yes friday works for me"},
	{calibFarEN[0], "okay release on friday sounds good"},
	{calibFarEN[0], "wait is the review done already"},
	{calibFarEN[0], "i can do the review today"},
	{calibFarEN[0], "friday after lunch is better for me"},
	{calibFarEN[1], "right so the vendor is late again"},
	{calibFarEN[1], "next month is fine with me"},
	{calibFarEN[1], "i know the deadline is tight"},
	{calibFarEN[1], "no the end of the quarter is better"},
	{calibFarEN[2], "sure i will send it tonight"},
	{calibFarEN[2], "the budget is already in the folder"},
	{calibFarEN[2], "third quarter numbers look good"},
	{calibFarEN[2], "before the meeting i need the old numbers"},
	{calibFarEN[3], "yes the customers need an answer"},
	{calibFarEN[3], "we should assign an owner this week"},
	{calibFarEN[3], "customers are waiting since monday"},
}

var calibTalkRU = []talkOver{
	{calibFarRU[0], "да в пятницу нормально"},
	{calibFarRU[0], "да релиз в пятницу меня устраивает"},
	{calibFarRU[0], "а ревью уже закончилось"},
	{calibFarRU[0], "ревью закончится завтра утром"},
	{calibFarRU[0], "релиз давайте в четверг"},
	{calibFarRU[1], "ну поставщик опять задерживает"},
	{calibFarRU[1], "конец месяца это слишком поздно"},
	{calibFarRU[1], "дедлайн мы не двигаем"},
	{calibFarRU[1], "я не согласен с дедлайном"},
	{calibFarRU[2], "хорошо пришлю сегодня вечером"},
	{calibFarRU[2], "бюджет на третий квартал уже готов"},
	{calibFarRU[2], "встреча завтра в десять"},
	{calibFarRU[3], "клиенты ждут уже неделю"},
	{calibFarRU[3], "проблема понятна давай решим"},
	{calibFarRU[3], "миграцию начнем в понедельник"},
	{calibFarRU[3], "никто не отвечает потому что нет владельца"},
}

func garble(r *rand.Rand, ws []string, pContent float64) []string {
	out := make([]string, 0, len(ws))
	for _, w := range ws {
		p := pContent
		if stopwords[w] {
			p = pContent / 5
		}
		if r.Float64() < p {
			w += "x"
		}
		out = append(out, w)
	}
	return out
}

// echoDrops counts, over 2000 seeded slices, how many the old gate and the
// gate at share drop.
func echoDrops(src []string, pContent, share float64) (old, now int) {
	r := rand.New(rand.NewSource(2))
	for it := 0; it < 2000; it++ {
		far := src[it%len(src)]
		fw := strings.Fields(far)
		l := 3 + r.Intn(len(fw)-3+1)
		st := r.Intn(len(fw) - l + 1)
		if len(contentTokens(strings.Join(fw[st:st+l], " "), nil)) < 2 {
			continue // a slice of common words only is not a re-capture worth a drop
		}
		me := strings.Join(garble(r, fw[st:st+l], pContent), " ")
		if voices.WordShare(me, far) >= oldGateShare {
			old++
		}
		if echoMatchAt(me, far, nil, share) {
			now++
		}
	}
	return
}

func falseDrops(set []talkOver, share float64) (n int, which []string) {
	for _, c := range set {
		if echoMatchAt(c.me, c.far, nil, share) {
			n++
			which = append(which, c.me)
		}
	}
	return
}

func TestEchoContentShareCalibration(t *testing.T) {
	cands := []float64{0.3, 0.4, 0.5, 0.6, 0.7, 0.8}
	var tb strings.Builder
	fmt.Fprintf(&tb, "\n%-6s", "share")
	for _, e := range []float64{.1, .2, .3} {
		fmt.Fprintf(&tb, " | en/ru drops @%2.0f%% err (old gate)", e*100)
	}
	fmt.Fprintf(&tb, " | false drops en/ru of 16\n")
	for _, c := range cands {
		fmt.Fprintf(&tb, "%-6.2f", c)
		for _, e := range []float64{.1, .2, .3} {
			oe, ne := echoDrops(calibFarEN, e, c)
			or, nr := echoDrops(calibFarRU, e, c)
			fmt.Fprintf(&tb, " | %4d/%4d (%4d/%4d)       ", ne, nr, oe, or)
		}
		fe, _ := falseDrops(calibTalkEN, c)
		fr, _ := falseDrops(calibTalkRU, c)
		fmt.Fprintf(&tb, " | %d/%d\n", fe, fr)
	}
	t.Log(tb.String())

	for _, e := range []float64{.1, .2} {
		for name, src := range map[string][]string{"en": calibFarEN, "ru": calibFarRU} {
			old, now := echoDrops(src, e, echoContentShare)
			// 1% slack: the only echoes lost are turns whose every content word
			// was garbled, which carry no content evidence by design.
			if float64(now) < float64(old)*(1-calibEchoSlack) {
				t.Errorf("%s @%.0f%% error: echoContentShare=%v drops %d echoes, the old gate %d; the new gate must not keep more doubled lines",
					name, e*100, echoContentShare, now, old)
			}
		}
	}
	fe, wenEN := falseDrops(calibTalkEN, echoContentShare)
	fr, wenRU := falseDrops(calibTalkRU, echoContentShare)
	if fe+fr > calibMaxFalseDrops {
		t.Errorf("echoContentShare=%v falsely drops %d of 32 talk-over turns (max %d): %q %q",
			echoContentShare, fe+fr, calibMaxFalseDrops, wenEN, wenRU)
	}
}

// echoContentShare has a floor and a ceiling pinned at its edge (#279): the owner talking over the far side with
// the same small words and a third of the content words is not an echo, two fifths is. The calibration above only
// proves the chosen value on average; lowering it to 0.3 kept the suite green.
// Mutation: internal/meeting/merge.go:65 `echoContentShare = 0.4` -> 0.3 -> RED (the 1/3 rows are dropped);
// -> 0.5 -> RED (the 2/5 row is kept).
func TestEchoContentShareEdges(t *testing.T) {
	far := "can you send me the updated budget for the third quarter before the meeting tomorrow"
	cases := []struct {
		name, me string
		echo     bool
	}{
		// content words send, other, plan: 1 of 3 shared; every small word is the far side's, so echoShare passes
		{"1/3 content shared, in order", "can you send me the other plan for the", false},
		{"1/3 content shared, other words", "can you send me the new plan for the", false},
		// content words send, budget, other, new, plan: 2 of 5 shared, exactly the share
		{"2/5 content shared", "can you send me the budget for the other new plan", true},
	}
	for _, c := range cases {
		if share := voices.WordShare(c.me, far); share < echoShare {
			t.Fatalf("%s: the row is mis-built, the plain share is %.2f, below echoShare", c.name, share)
		}
		if got := echoMatch(c.me, far, nil); got != c.echo {
			t.Errorf("%s: echoMatch(%q) = %v, want %v", c.name, c.me, got, c.echo)
		}
	}
}
