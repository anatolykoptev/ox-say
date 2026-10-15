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
