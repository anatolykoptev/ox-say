package glossary

import (
	"fmt"
	"testing"
)

// A small deterministic simulation of an agent mining the glossary from dictated sentences, with synthetic
// terms and sentences only. It uses the public API (Add, Active, Apply), so the same file runs against an
// earlier revision of the package for a before number.
//
// An agent files a pair every time it understands a garbled term: the recogniser writes a made-up term a
// different way almost every time, in the case the sentence needs. The simulation files a fixed stream of such
// pairs, then replays held-out sentences (every filed spelling in five cases) and counts how many the post-pass
// repairs (recall), and replays ordinary sentences (a few use words an agent filed by mistake, and some are
// near-misses of a filed word) and counts how many it changes (false matches).

type simTerm struct {
	meant string
	forms []simForm
}

// simForm is one heard spelling and the number of different sentences the agent filed it from.
type simForm struct {
	heard string
	n     int
}

var simTerms = []simTerm{
	{"Quantex", []simForm{{"квантекс", 2}, {"кантекс", 1}, {"квантэкс", 1}, {"кваньтекс", 1}}},
	{"Zorvin", []simForm{{"зорвин", 2}, {"зарвин", 1}, {"зорвен", 1}}}, // «зорвен» ends like a verb: Snowball does not strip it as a noun
	{"Brenvik", []simForm{{"бренвик", 1}, {"бренвек", 1}, {"брэнвик", 1}}},
	{"Bervol", []simForm{{"бервол", 2}}}, // one spelling, two sentences: the length threshold alone
	{"PlenkArc", []simForm{{"пленк арк", 2}, {"пленкарк", 1}}},
	{"Rux", []simForm{{"рукс", 3}, {"рукз", 1}}}, // short: three sentences
	{"Tavron", []simForm{{"таврон", 3}}},
}

// simMistakes are ordinary words an agent filed by mistake, with the sentences it filed them from.
var simMistakes = []struct {
	heard, meant string
	n            int
}{
	{"машина", "Machine", 2},
	{"вол", "Vol", 3},
}

var simFrames = []string{
	"позвони про %s завтра утром", "открой %s и покажи что там", "мы говорили о %s на встрече", "добавь %s в список дел",
	"спроси у команды про %s", "запиши что %s готов", "перенеси %s на пятницу", "почему опять %s не работает",
}

var simHeldOut = "напомни мне про %s в пятницу"

var simCases = []string{"", "а", "у", "е", "ом"}

// inflect puts a case ending on the last word of a heard form.
func inflect(heard, ending string) string { return heard + ending }

// simOrdinary: ordinary sentences. The first group uses the words an agent filed by mistake (and should stay as
// they are, but cannot once the pair is active); the second group are near-misses of those words that no
// sensible post-pass touches.
var simOrdinary = struct{ plain, nearMiss []string }{
	plain: []string{
		"машина стоит у дома", "у входа нет машины", "я приехал на машине", "он купил машину вчера", "рядом с машиной ждала собака",
		"вол тянул тяжёлую телегу", "старый вол устал",
	},
	nearMiss: []string{
		"это машинный перевод текста", "машинка для стрижки сломалась", "машинист остановил поезд", "машинально он кивнул",
		"воля к победе важнее силы", "по своей воле он ушёл", "у вола сильные ноги", "в школе была большая перемена",
		"на столе лежит яблоко и хлеб", "мы идём гулять в парк", "погода сегодня хорошая", "расскажи мне про море",
		"квантовая физика сложна", "зорька встаёт над рекой", "хор поёт в большом зале", "таверна стоит у дороги",
		"пленка закончилась в камере", "рука болит после тренировки", "арка над входом старая",
	},
}

// simResult runs the stream against a fresh store and returns recall and false-match counts.
func simResult(t *testing.T) (hit, total, falsePlain, nPlain, falseNear, nNear int) {
	t.Helper()
	s := newTestStore(t)
	frame := 0
	file := func(heard, meant string, n int) {
		for i := 0; i < n; i++ {
			ctx := fmt.Sprintf(simFrames[frame%len(simFrames)], heard) + fmt.Sprintf(" %d", frame/len(simFrames))
			frame++
			if _, err := s.Add(heard, meant, ctx); err != nil {
				t.Fatalf("Add(%q): %v", heard, err)
			}
		}
	}
	// one pass over the stream per round, so the spellings are interleaved the way a day of dictation would
	for round := 0; round < 3; round++ {
		for _, tm := range simTerms {
			for _, f := range tm.forms {
				if round < f.n {
					file(f.heard, tm.meant, 1)
				}
			}
		}
		for _, m := range simMistakes {
			if round < m.n {
				file(m.heard, m.meant, 1)
			}
		}
	}
	pairs, err := s.Active()
	if err != nil {
		t.Fatal(err)
	}
	for _, tm := range simTerms {
		for _, f := range tm.forms {
			for _, c := range simCases {
				total++
				in := fmt.Sprintf(simHeldOut, inflect(f.heard, c))
				if got, _ := Apply(in, pairs); got == fmt.Sprintf(simHeldOut, tm.meant) {
					hit++
				}
			}
		}
	}
	for _, in := range simOrdinary.plain {
		nPlain++
		if got, _ := Apply(in, pairs); got != in {
			falsePlain++
		}
	}
	for _, in := range simOrdinary.nearMiss {
		nNear++
		if got, _ := Apply(in, pairs); got != in {
			falseNear++
		}
	}
	return
}

// The numbers of the simulation. Before this change (per-spelling counting, no stemming, three sentences for every
// single word) recall was 3/80 and 2/7 of the sentences with a mistakenly filed word were changed (only «вол»,
// filed from three sentences, was active); after it recall is 64/80. Taking one change away from the final code:
// per-spelling counting 22/80, no stemming 16/80, a threshold of three for every single word 59/80. The mistaken
// «машина» pair, now active from two sentences, changes its five sentences too (7/7): that is the price of the
// lower threshold, which the owner's approval of a candidate (and the Rejected tombstone) is there to catch. The
// near-misses (a derivation, a short stem) stay untouched before and after. The 16 misses are the
// cases of a spelling Snowball strips as a verb («зорвен»), of «арк» (a stem under five letters) and of the
// four-letter «рукс» and «рукз».
// Mutation: store.go Add, `promote(pairs, meant)` -> the old per-pair line -> RED (recall 22/80).
// Mutation: store.go needed, `n >= 5` -> `n >= 99` -> RED (recall 59/80).
// Mutation: stem.go sameWord, `nominalStem(w) == hs` -> `russian.Stem(w, false) == hs` -> RED («машинный» is changed).
func TestMiningSimulation(t *testing.T) {
	hit, total, falsePlain, nPlain, falseNear, nNear := simResult(t)
	t.Logf("recall %d/%d (%.1f%%); ordinary sentences with a mistakenly filed word changed %d/%d; near-misses changed %d/%d",
		hit, total, 100*float64(hit)/float64(total), falsePlain, nPlain, falseNear, nNear)
	if min := 64; hit < min {
		t.Errorf("recall %d/%d, want at least %d", hit, total, min)
	}
	if falseNear != 0 {
		t.Errorf("%d near-miss sentences were changed, want 0", falseNear)
	}
}
