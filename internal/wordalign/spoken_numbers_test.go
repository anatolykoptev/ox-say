package wordalign_test

import (
	"fmt"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/vscript"
	"github.com/anatolykoptev/ox-say/internal/wordalign"
)

// nonNumeralWords are the words ExpandNumbers writes that are not numerals.
var nonNumeralWords = map[string]bool{
	"в": true, "на": true, "году": true, "процент": true, "процента": true, "процентов": true,
}

const maxEnumerated = 3100

// Derived from the speller itself so the gate's numeral lexicon cannot drift:
// every word ExpandNumbers writes for n <= 3100 (cardinals of each gender,
// every ordinal suffix, dates, years, decimals, percents, times) must be
// absorbed by a digit token in the transcript. A word that is not a numeral
// would cost an error whenever the ASR writes the digits.
// Mutation: wordalign/numerals.go numeralStems without "двухтысяч" -> RED.
func TestEveryWordTheSpellerWritesMatchesADigitToken(t *testing.T) {
	var inputs []string
	for n := 0; n <= maxEnumerated; n++ {
		for _, noun := range []string{"раз", "день", "дня", "минута", "минуты", "окно", "окна"} {
			inputs = append(inputs, fmt.Sprintf("%d %s", n, noun))
		}
		for _, suf := range []string{"й", "я", "е", "ю", "го", "му", "х", "ми", "ым", "ые", "ого", "ую", "ая", "ый"} {
			inputs = append(inputs, fmt.Sprintf("%d-%s", n, suf))
		}
		inputs = append(inputs, fmt.Sprintf("в %d-м", n), fmt.Sprintf("в %d году", n), fmt.Sprintf("%d апреля", n),
			fmt.Sprintf("на %d%%", n), fmt.Sprintf("%d,5 раза", n), fmt.Sprintf("%d,25 раза", n), fmt.Sprintf("%d,001 раза", n),
			fmt.Sprintf("%d–%d раз", n, n+7))
	}
	for h := 0; h < 24; h++ {
		inputs = append(inputs, fmt.Sprintf("в %d:%02d", h, h*2%60), fmt.Sprintf("в %d:0%d", h, h%10))
	}
	seen := map[string]bool{}
	for _, in := range inputs {
		out := vscript.ExpandNumbers(in)
		if out == in {
			continue
		}
		for _, w := range wordalign.Words(out) {
			if seen[w] || nonNumeralWords[w] || w == "раз" || w == "раза" || w == "день" || w == "дня" || w == "минута" || w == "минуты" || w == "окно" || w == "окна" || w == "апреля" {
				continue
			}
			seen[w] = true
			if errs, _ := wordalign.WER(w, "1"); errs != 0 {
				t.Errorf("%q (from %q): not matched by a digit token; add its stem to numeralStems", w, in)
			}
		}
	}
	if len(seen) < 100 {
		t.Fatalf("only %d distinct words enumerated: the inputs do not exercise the speller", len(seen))
	}
}

func TestSpokenYearOrdinalsMatchDigits(t *testing.T) {
	for ref, hyp := range map[string]string{
		"в двухтысячном году":                       "в 2000 году",
		"в тысячном году":                           "в 1000 году",
		"на первую страницу":                        "на 1-ю страницу",
		"в третьих и третьими":                      "в 3-х и 3-ми",
		"в две тысячи двадцать шестом году":         "в 2026 году",
		"в тысяча девятьсот девяносто восьмом году": "в 1998 году",
		strings.Repeat("двухтысячном ", 1) + "году": "2000 году",
	} {
		if errs, _ := wordalign.WER(ref, hyp); errs != 0 {
			t.Errorf("WER(%q, %q) = %d", ref, hyp, errs)
		}
	}
}

// #313.1: English scripts keep their digits; STT writes the number in words.
// The lexicon is checked as the Russian side is: a numeral word is free next to
// a digit token, any other word costs 1 (the number's value is not checked).
// Mutation: numerals.go isNumeral, drop the englishNumerals lookup -> RED on
// "I have 25 apples" against "i have twenty five apples".
func TestEnglishSpokenNumbersMatchDigits(t *testing.T) {
	for ref, hyp := range map[string]string{
		"I have 25 apples":            "i have twenty five apples",
		"I have 25 apples!":           "I have twenty-five apples",
		"it is 2026":                  "it is twenty twenty-six",
		"it is 2026 now":              "it is twenty twenty six now",
		"it is 2026!":                 "it is two thousand and twenty six",
		"call 911":                    "call nine hundred eleven",
		"he is 5 feet tall":           "he is five feet tall",
		"the 1st of May":              "the first of may",
		"the 21st century":            "the twenty first century",
		"a 40% rise":                  "a forty percent rise",
		"cost $5":                     "cost five dollars",
		"3.5 miles":                   "three point five miles",
		"in the 1990s":                "in the nineteen nineties",
		"temperature -5":              "temperature minus five",
		"chapter 12":                  "chapter twelve",
		"1 000 000 users":             "one million users",
		"over 300 times":              "over three hundred times",
		"on the 100th day":            "on the hundredth day",
		"the year 2000":               "the year two thousand",
		"the 3rd of may":              "the third of may",
		"he said 13 words":            "he said thirteen words",
		"it takes 30 seconds":         "it takes thirty seconds",
		"it takes 99 seconds":         "it takes ninety nine seconds",
		"it takes 80 seconds":         "it takes eighty seconds",
		"it takes 70 seconds":         "it takes seventy seconds",
		"it takes 60 seconds":         "it takes sixty seconds",
		"it takes 90 seconds":         "it takes ninety seconds",
		"it takes 14 seconds":         "it takes fourteen seconds",
		"it takes 15 seconds":         "it takes fifteen seconds",
		"it takes 16 seconds":         "it takes sixteen seconds",
		"it takes 17 seconds":         "it takes seventeen seconds",
		"it takes 18 seconds":         "it takes eighteen seconds",
		"it takes 19 seconds":         "it takes nineteen seconds",
		"it takes 0 seconds":          "it takes zero seconds",
		"it takes 1 seconds":          "it takes one seconds",
		"it takes 2 seconds":          "it takes two seconds",
		"it takes 4 seconds":          "it takes four seconds",
		"it takes 6 seconds":          "it takes six seconds",
		"it takes 7 seconds":          "it takes seven seconds",
		"it takes 8 seconds":          "it takes eight seconds",
		"it takes 9 seconds":          "it takes nine seconds",
		"it takes 10 seconds":         "it takes ten seconds",
		"it takes 11 seconds":         "it takes eleven seconds",
		"it takes 50 seconds":         "it takes fifty seconds",
		"it takes 40 seconds":         "it takes forty seconds",
		"it takes 20 seconds":         "it takes twenty seconds",
		"it takes 5 billion seconds":  "it takes five billion seconds",
		"it takes 105 seconds":        "it takes one hundred and five seconds",
		"it takes 2 thousand seconds": "it takes two thousand seconds",
	} {
		if errs, _ := wordalign.WER(ref, hyp); errs != 0 {
			t.Errorf("WER(%q, %q) = %d, want 0", ref, hyp, errs)
		}
	}
}

// A wrong word next to a digit token still costs, in English as in Russian.
func TestEnglishDigitTokenStillCostsForOtherWords(t *testing.T) {
	for ref, hyp := range map[string]string{
		"I have 25 apples":  "i have banana apples",
		"I have 25 apples!": "i have twenty five green apples",
		"call 911":          "call me now",
		"it is 2026":        "it is wonderful",
		"the 1st of May":    "the best of may",
		"he is 5 feet":      "he is hand feet",
	} {
		if errs, _ := wordalign.WER(ref, hyp); errs == 0 {
			t.Errorf("WER(%q, %q) = 0, want > 0", ref, hyp)
		}
	}
}
