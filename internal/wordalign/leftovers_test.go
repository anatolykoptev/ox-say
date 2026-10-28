package wordalign

import (
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// #146 item 1: the filler «и» is free only between two numeral words.
// Mutation: numerals.go spanCost treats every "и" as a numeral again -> RED.
func TestWERFillerIOnlyBetweenNumerals(t *testing.T) {
	for _, c := range []struct {
		ref, hyp string
		errs     int
	}{
		{"Нас 10 человек.", "нас и и и и человек", 4},
		{"Нас 10 человек.", "нас и десять человек", 1},
		{"Нас 10 человек.", "нас десять и человек", 1},
		{"Тут 2 001 дом.", "тут две тысячи и один дом", 0},
		{"Нас 10 человек.", "нас десять человек", 0},
	} {
		if e, _ := WER(c.ref, c.hyp); e != c.errs {
			t.Errorf("WER(%q, %q) errors = %d, want %d", c.ref, c.hyp, e, c.errs)
		}
	}
}

// #146 item 2: words that no number is ever spoken as stay costly.
// Mutation: numerals.go notNumerals emptied -> RED.
func TestWERLexiconRejectsNonNumbers(t *testing.T) {
	for _, w := range []string{"трио", "пята", "шест", "перва", "сота", "соты"} {
		if isNumeral(w) {
			t.Errorf("isNumeral(%q) = true", w)
		}
	}
	for _, w := range []string{"три", "пять", "шесть", "первая", "сотый", "сорока", "треть", "нуль"} {
		if !isNumeral(w) {
			t.Errorf("isNumeral(%q) = false", w)
		}
	}
}

// #146 item 3: a count followed by a three-digit number is not one number.
// Mutation: wer.go joinDigitGroups joins every run -> "3 100" is "3100" -> RED.
func TestJoinDigitGroupsPlainSpace(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"в 3 100 домах", "в 3 100 домах"},
		{"1 000 000", "1000000"},
		{"2 500 000 рублей", "2500000 рублей"},
		{"1 000 рублей", "1000 рублей"},
		{"3 100 домов", "3100 домов"},
		{"3 100 домов", "3100 домов"},
	} {
		if got := joinDigitGroups(c.in); got != c.want {
			t.Errorf("joinDigitGroups(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// #146 item 4: an abbreviation's dot does not end a cue unless a new sentence
// starts after it.
// Mutation: cues.go abbreviation check removed -> "Мр." is a cue -> RED.
func TestCuesAbbreviationDoesNotEndCue(t *testing.T) {
	mk := func(s string) []voices.Word {
		var ws []voices.Word
		for i, w := range strings.Fields(s) {
			ws = append(ws, voices.Word{W: w, S: float64(i) * 0.4, E: float64(i)*0.4 + 0.3})
		}
		return ws
	}
	for _, c := range []struct {
		in   string
		want []string
	}{
		{"Мр. Смит пришёл вовремя.", []string{"Мр. Смит пришёл вовремя."}},
		{"Это важно, т.е. очень срочно.", []string{"Это важно, т.е. очень срочно."}},
		{"Яблоки, груши и т.д. Потом уехали.", []string{"Яблоки, груши и т.д.", "Потом уехали."}},
		{"Конец и т.д.", []string{"Конец и т.д."}},
		// #313.4: an initial is not a sentence end; "г." as "year" still is.
		{"Ivan G. Petrov arrived.", []string{"Ivan G. Petrov arrived."}},
		{"Иван Г. Петров пришёл.", []string{"Иван Г. Петров пришёл."}},
		{"Mr. J. R. R. Tolkien wrote.", []string{"Mr. J. R. R. Tolkien wrote."}},
		{"Это было в 2026 г. Потом уехали.", []string{"Это было в 2026 г.", "Потом уехали."}},
		{"Это было в 2026 г. и потом.", []string{"Это было в 2026 г. и потом."}},
		{"Вариант Б. потом", []string{"Вариант Б.", "потом"}},
	} {
		var got []string
		for _, cue := range Cues(mk(c.in)) {
			got = append(got, strings.ReplaceAll(cue.Text, "\n", " "))
		}
		if strings.Join(got, "|") != strings.Join(c.want, "|") {
			t.Errorf("Cues(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// #146 item 5: a word's end never passes the next word's start.
// Mutation: align.go settle drops the end clamp -> RED.
func TestSettleEndsNotPastNextStart(t *testing.T) {
	got := settle([]voices.Word{{W: "а", S: 0, E: 1.5}, {W: "б", S: 1.0, E: 2}, {W: "в", S: 1.8, E: 3}}, 3)
	for i := 0; i+1 < len(got); i++ {
		if got[i].E > got[i+1].S {
			t.Errorf("word %d end %.2f passes next start %.2f", i, got[i].E, got[i+1].S)
		}
	}
}
