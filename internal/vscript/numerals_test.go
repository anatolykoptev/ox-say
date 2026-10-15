package vscript

import (
	"os"
	"strings"
	"testing"
	"unicode/utf8"
)

// The ten lines of the F1-0 numerals probe (numerals.txt) with the spoken
// forms they must become. 2-й, 2,5 and 10–15 are the three the engine misread.
// Mutations: numerals_scan.go ordinal branch removed -> "2-й этап" stays;
// range branch removed -> "10–15" stays; the thousands feminine rule dropped
// (numerals.go cardinal, `triple(th, fem)` -> `triple(th, masc)`) -> TestNumbersRound RED.
func TestExpandNumbersProbeLines(t *testing.T) {
	for in, want := range map[string]string{
		"в 1998 году":   "в тысяча девятьсот девяносто восьмом году",
		"21 день":       "двадцать один день",
		"5 минут":       "пять минут",
		"2-й этап":      "второй этап",
		"300 рублей":    "триста рублей",
		"2,5 литра":     "две целых пять десятых литра",
		"10–15 человек": "десять — пятнадцать человек",
		"на 40%":        "на сорок процентов",
		"в 18:30":       "в восемнадцать тридцать",
		"12 апреля":     "двенадцатого апреля",
	} {
		if got := ExpandNumbers(in); got != want {
			t.Errorf("ExpandNumbers(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestNumbersRound(t *testing.T) {
	for in, want := range map[string]string{
		"0 раз":            "ноль раз",
		"11 минут":         "одиннадцать минут",
		"20 шагов":         "двадцать шагов",
		"100 рублей":       "сто рублей",
		"1000 рублей":      "тысяча рублей",
		"2000 рублей":      "две тысячи рублей",
		"1 000 000 рублей": "миллион рублей",
		"21 000 рублей":    "двадцать одна тысяча рублей",
		"22 000 рублей":    "двадцать две тысячи рублей",
		"5 000 рублей":     "пять тысяч рублей",
		"11 000 рублей":    "одиннадцать тысяч рублей",
		"2 500 000 штук":   "два миллиона пятьсот тысяч штук",
		"123 456 рублей":   "сто двадцать три тысячи четыреста пятьдесят шесть рублей",
		"999999999 раз":    "девятьсот девяносто девять миллионов девятьсот девяносто девять тысяч девятьсот девяносто девять раз",
	} {
		if got := ExpandNumbers(in); got != want {
			t.Errorf("ExpandNumbers(%q) = %q, want %q", in, got, want)
		}
	}
}

// A trailing 1 or 2 takes the noun's gender; an unknown noun leaves the digits.
func TestNumbersGender(t *testing.T) {
	for in, want := range map[string]string{
		"1 минута":       "одна минута",
		"2 минуты":       "две минуты",
		"2 дня":          "два дня",
		"1 окно":         "одно окно",
		"31 секунда":     "тридцать одна секунда",
		"1 странность":   "1 странность",
		"Ответ: 2.":      "Ответ: 2.",
		"101 далматинец": "101 далматинец",
	} {
		if got := ExpandNumbers(in); got != want {
			t.Errorf("ExpandNumbers(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestNumbersPercentAndDecimal(t *testing.T) {
	for in, want := range map[string]string{
		"1%":         "один процент",
		"2 %":        "два процента",
		"5%":         "пять процентов",
		"11%":        "одиннадцать процентов",
		"21%":        "двадцать один процент",
		"2,5%":       "две целых пять десятых процента",
		"1,5 раза":   "одна целая пять десятых раза",
		"0,25 литра": "ноль целых двадцать пять сотых литра",
		"3,001 кг":   "три целых одна тысячная кг",
		"2,12 метра": "две целых двенадцать сотых метра",
		"1,2,3":      "1,2,3",
		"1,2345":     "1,2345",
		"2,0 литра":  "2,0 литра",
	} {
		if got := ExpandNumbers(in); got != want {
			t.Errorf("ExpandNumbers(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestNumbersTime(t *testing.T) {
	for in, want := range map[string]string{
		"в 18:30":  "в восемнадцать тридцать",
		"в 9:05":   "в девять ноль пять",
		"в 18:00":  "в восемнадцать ноль ноль",
		"в 0:15":   "в ноль пятнадцать",
		"в 25:30":  "в 25:30",
		"в 12:60":  "в 12:60",
		"12:30:45": "12:30:45",
		"до 18:30": "до 18:30",
	} {
		if got := ExpandNumbers(in); got != want {
			t.Errorf("ExpandNumbers(%q) = %q, want %q", in, got, want)
		}
	}
}

// Ordinals written with a suffix take the case the suffix marks; an
// ambiguous or unknown suffix leaves the token.
func TestNumbersOrdinalSuffix(t *testing.T) {
	for in, want := range map[string]string{
		"2-й этап":       "второй этап",
		"3-го числа":     "третьего числа",
		"5-му":           "пятому",
		"1-я часть":      "первая часть",
		"2-е место":      "второе место",
		"10-х годов":     "десятых годов",
		"в 90-х":         "в девяностых",
		"21-м":           "21-м",
		"в 21-м веке":    "в двадцать первом веке",
		"3-я":            "третья",
		"3-й":            "третий",
		"3-ю":            "третью",
		"40-й":           "сороковой",
		"200-й":          "двухсотый",
		"100-го":         "сотого",
		"2000-й":         "двухтысячный",
		"в 1998-м":       "в тысяча девятьсот девяносто восьмом",
		"4-й":            "четвёртый",
		"2-ой этап":      "2-ой этап",
		"5-минутный":     "5-минутный",
		"3-D":            "3-D",
		"2-ыми":          "вторыми",
		"1-й, 2-й и 3-й": "первый, второй и третий",
		"25-летие":       "25-летие",
	} {
		if got := ExpandNumbers(in); got != want {
			t.Errorf("ExpandNumbers(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestNumbersRange(t *testing.T) {
	for in, want := range map[string]string{
		"10-15 человек":  "десять — пятнадцать человек",
		"10–15 человек":  "десять — пятнадцать человек",
		"1–2 минуты":     "одна — две минуты",
		"2-3 дня":        "два — три дня",
		"1–2 странности": "1–2 странности",
		"5-3":            "5-3",
		"3-3 раза":       "3-3 раза",
		"12–15 апреля":   "12–15 апреля",
		"до 10–15 минут": "до 10–15 минут",
		"1990–2000 годы": "1990–2000 годы",
		"1-2-3":          "1-2-3",
	} {
		if got := ExpandNumbers(in); got != want {
			t.Errorf("ExpandNumbers(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestNumbersYearsAndDates(t *testing.T) {
	for in, want := range map[string]string{
		"в 2026 году":        "в две тысячи двадцать шестом году",
		"в 2000 году":        "в двухтысячном году",
		"в 1905 г.":          "в тысяча девятьсот пятом году.",
		"в 1905 г. он":       "в тысяча девятьсот пятом году он",
		"Это было в 1905 г.": "Это было в тысяча девятьсот пятом году.",
		"с 2026 года":        "с 2026 года",
		"2026 год":           "2026 год",
		"3 года":             "три года",
		"5 лет":              "пять лет",
		"1 мая":              "первого мая",
		"с 12 апреля":        "с двенадцатого апреля",
		"к 12 апреля":        "к двенадцатому апреля",
		"на 3 марта":         "на третье марта",
		"Сегодня 12 апреля":  "Сегодня двенадцатое апреля",
		"32 апреля":          "32 апреля",
	} {
		if got := ExpandNumbers(in); got != want {
			t.Errorf("ExpandNumbers(%q) = %q, want %q", in, got, want)
		}
	}
}

// Case after any other preposition is out of scope: the digits stay.
func TestNumbersLeaveUnsure(t *testing.T) {
	for _, in := range []string{
		"с 5 друзьями", "до 5 минут", "от 10 до 20", "о 3 вещах", "около 40%", "по 2 штуки",
		"v1.2.3", "COVID-19", "5G", "10x", "№5", "$5", "5₽", "300 ₽", "-5", "1/2", "3.14", "007", "1234567890",
		"+7 (999) 123-45-67", "12:30:45", "ГОСТ 12345-2020",
	} {
		if got := ExpandNumbers(in); got != in {
			t.Errorf("ExpandNumbers(%q) = %q, want unchanged", in, got)
		}
	}
}

func TestNumbersNoDigitsUntouched(t *testing.T) {
	in := "Просто текст, без чисел. Т.е. совсем."
	if got := ExpandNumbers(in); got != in {
		t.Errorf("got %q", got)
	}
}

// The spoken text carries the words; the written text (subtitles) keeps the
// digits; abbreviation expansion and numbers compose.
// Mutation: markup.go `Spoken: Spoken(text)` -> `Spoken: text`, or chunk.go
// Spoken applying ExpandNumbers to its input but Parse storing it into Text
// (`Text: ExpandNumbers(text)`) -> RED.
func TestSpokenExpandsNumbersTextKeepsDigits(t *testing.T) {
	src := "Т.е. через 5 минут, в 18:30, 2-й этап: 10–15 человек и 2,5 литра."
	got, err := Parse(src, testOpts)
	if err != nil || len(got) != 1 {
		t.Fatalf("%v %+v", err, got)
	}
	wantSpoken := "То есть через пять минут, в восемнадцать тридцать, второй этап: десять — пятнадцать человек и две целых пять десятых литра."
	if got[0].Spoken != wantSpoken {
		t.Errorf("Spoken = %q, want %q", got[0].Spoken, wantSpoken)
	}
	if got[0].Text != src {
		t.Errorf("Text = %q, want the written digits %q", got[0].Text, src)
	}
	if strings.ContainsAny(got[0].Spoken, "0123456789") {
		t.Errorf("digits left in Spoken: %q", got[0].Spoken)
	}
}

// The probe's own file, when the private kit is present: every line expands to
// a digit-free string (the table above pins the exact forms).
func TestNumeralsFileHasNoDigitsLeft(t *testing.T) {
	b, err := os.ReadFile(os.ExpandEnv("$HOME/deploy/krolik-server/plans/ox-say/voxcpm2-probe/produce/scripts/numerals.txt"))
	if err != nil {
		t.Skip("private numerals.txt not present")
	}
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if got := ExpandNumbers(l); strings.ContainsAny(got, "0123456789") {
			t.Errorf("%q -> %q still has digits", l, got)
		}
	}
}

func checkTable(t *testing.T, table map[string]string) {
	t.Helper()
	for in, want := range table {
		if got := ExpandNumbers(in); got != want {
			t.Errorf("ExpandNumbers(%q) = %q, want %q", in, got, want)
		}
	}
}

// Review F1: "-й" is a masculine nominative or a feminine oblique; after a
// preposition only a listed masculine noun settles it.
// Mutation: numerals_scan.go expandOrdinal `case "й":` branch removed -> RED.
func TestNumbersOrdinalYAmbiguity(t *testing.T) {
	checkTable(t, map[string]string{
		"в 5-й школе":     "в 5-й школе",
		"на 3-й странице": "на 3-й странице",
		"к 5-й":           "к 5-й",
		"из 2-й школы":    "из 2-й школы",
		"на 3-й день":     "на третий день",
		"Это 2-й этап":    "Это второй этап",
		"Занял 5-й.":      "Занял пятый.",
		"2-й школой":      "2-й школой",
		"Дал 5-й школе":   "Дал 5-й школе",
	})
}

// Review F2: a number before an oblique plural noun is not nominative.
// Mutation: numerals_scan.go expandCardinal `|| obliquePlural(next)` removed -> RED.
func TestNumbersObliquePlural(t *testing.T) {
	for _, in := range []string{
		"в 5 домах", "на 5 страницах", "управляет 5 серверами", "дал 3 детям", "помог 5 людям", "за 3 днями",
		"в 2,5 литрах", "по 3–5 домам",
	} {
		if got := ExpandNumbers(in); got != in {
			t.Errorf("ExpandNumbers(%q) = %q, want unchanged", in, got)
		}
	}
	checkTable(t, map[string]string{"в 5 домов": "в пять домов", "за 3 дня": "за три дня"})
}

// Review F3: a dash touching a number is a minus or dangling; digits stay.
// Mutation: numerals_scan.go blockBefore without "–—" -> RED.
func TestNumbersMinusAndDangling(t *testing.T) {
	for _, in := range []string{"–5 градусов", "−5 градусов", "-5 градусов", "—5 минут", "5- и 6-летний", "5–", "от 5– до", "Ответ 5—"} {
		if got := ExpandNumbers(in); got != in {
			t.Errorf("ExpandNumbers(%q) = %q, want unchanged", in, got)
		}
	}
}

// Review F4: clock phrases and a genitive after one keep their digits.
// Mutation: numerals_nouns.go add `ночь/ночи` to the feminine list -> RED.
func TestNumbersClockAndCase(t *testing.T) {
	for _, in := range []string{"в 2 ночи", "в 1 ночи", "1 утра", "2 утра", "1 человека", "21 человека", "1 дня"} {
		if got := ExpandNumbers(in); got != in {
			t.Errorf("ExpandNumbers(%q) = %q, want unchanged", in, got)
		}
	}
	checkTable(t, map[string]string{"1 человек": "один человек", "2 человека": "два человека", "22 дня": "двадцать два дня"})
}

// Review F5: "во/ко/со" cannot be written by us; leave digits.
// Mutation: numerals_scan.go prepMismatch `HasPrefix(first, "вт")` -> `false` -> RED.
func TestNumbersPrepositionAgreement(t *testing.T) {
	for _, in := range []string{"в 2-м классе", "в 2-й раз", "к 2-му", "с 2-го", "с 2 апреля", "к 2 апреля", "об 8-м", "о 11-м"} {
		if got := ExpandNumbers(in); got != in {
			t.Errorf("ExpandNumbers(%q) = %q, want unchanged", in, got)
		}
	}
	checkTable(t, map[string]string{"в 3-м классе": "в третьем классе", "о 8-м": "о восьмом", "об 11-м": "об одиннадцатом", "с 3-го": "с третьего"})
}

// Review F6: year ranges and a bare "в 2026" keep their digits.
// Mutation: numerals_scan.go `(yearLike(a) && yearLike(b))` removed / bareYear `return false` -> RED.
func TestNumbersBareYears(t *testing.T) {
	for _, in := range []string{"1998–2000", "(1998–2000)", "в 2026", "в 2026.", "в 1998–2000 годах", "1998-2000"} {
		if got := ExpandNumbers(in); got != in {
			t.Errorf("ExpandNumbers(%q) = %q, want unchanged", in, got)
		}
	}
	checkTable(t, map[string]string{"в 2000 раз": "в две тысячи раз"})
}

// Review F7: a percent after a range agrees with the second number.
// Mutation: numerals_scan.go expandRange percent branch removed -> RED.
func TestNumbersRangePercent(t *testing.T) {
	checkTable(t, map[string]string{
		"5–10%":        "пять — десять процентов",
		"1–2%":         "один — два процента",
		"10–21 %":      "десять — двадцать один процент",
		"скидка 5–10%": "скидка пять — десять процентов",
	})
}

// Review F8: numbers written as words are longer than their digits; no chunk's
// Spoken may exceed the engine's per-request cap while Text fits MaxChars.
// Mutation: markup.go Parse without fitSpoken (`fitSpoken(x, o)` -> `x`) -> RED.
func TestSpokenFitsEngineCap(t *testing.T) {
	o := testOpts
	o.MaxSpokenChars = 1000
	src := "Выручка по регионам: " + strings.Repeat("123 456 789, ", 28) + "итого."
	got, err := Parse(src, o)
	if err != nil {
		t.Fatal(err)
	}
	var joined []string
	for _, c := range got {
		if n := len([]rune(c.Spoken)); n > o.MaxSpokenChars {
			t.Errorf("chunk %d: Spoken is %d runes (Text %d)", c.Index, n, len([]rune(c.Text)))
		}
		joined = append(joined, c.Text)
	}
	if len(got) < 2 {
		t.Errorf("want the dense chunk split, got %d chunk(s)", len(got))
	}
	if strings.Join(joined, " ") != strings.Join(strings.Fields(src), " ") {
		t.Errorf("the chunks do not rebuild the script")
	}
	// Without a cap the old behaviour: Spoken far over 1000 from a Text that fits.
	got, _ = Parse(src, testOpts)
	over := false
	for _, c := range got {
		over = over || len([]rune(c.Spoken)) > 1000
	}
	if !over {
		t.Errorf("fixture too weak: no chunk exceeds 1000 spoken runes without the cap")
	}
}

// FuzzExpandNumbers: no panic; text without digits is returned unchanged; the
// result of valid UTF-8 is valid UTF-8; non-digit, non-expanded runs survive
// (a result never loses a letter that is not part of a number's expansion is
// not checkable, so only the structural invariants are asserted).
func FuzzExpandNumbers(f *testing.F) {
	for _, s := range []string{"в 5 домах", "–5 градусов", "5–10%", "в 2-м классе", "1998–2000", "12:30:45", "+7 (999) 123-45-67",
		"1 000 000 рублей", "2,5 литра", "12 апреля", "в 2026 году", "123 456 789, ", "5-", "№5", "0,001 раза"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, in string) {
		out := ExpandNumbers(in)
		if !strings.ContainsAny(in, "0123456789") && out != in {
			t.Fatalf("no digits but changed: %q -> %q", in, out)
		}
		if utf8.ValidString(in) && !utf8.ValidString(out) {
			t.Fatalf("invalid UTF-8 from valid input %q: %q", in, out)
		}
	})
}

// Review round 2: "числа" after a number is a date or a quantity: digits.
// Mutation: numerals_scan.go expandCardinal `|| dateWord(next)` removed -> RED.
func TestNumbersChislaStaysDigits(t *testing.T) {
	for _, in := range []string{"5 числа", "15 числа", "2 числа", "было 2 числа", "5–7 числа"} {
		if got := ExpandNumbers(in); got != in {
			t.Errorf("ExpandNumbers(%q) = %q, want unchanged", in, got)
		}
	}
	checkTable(t, map[string]string{"3-го числа": "третьего числа", "12 апреля": "двенадцатого апреля"})
}

// youtubeOpts mirrors the daemon's youtube preset (produce.go presetOpts).
var youtubeOpts = Options{TargetChars: 250, MaxChars: 400, MinChars: 80, MaxScriptChars: 40000, MaxSpokenChars: 1000,
	ChunkPause: 0.30, ParagraphPause: 0.70}

// Review round 2: halving a dense chunk must not cut between a word and the
// words that complete it. The phrase sits at the middle of a comma-separated
// run of figures (so a naive nearest-space cut lands inside it); every padding
// moves it by one rune so some padding puts the naive cut in each space.
// Mutation: chunk_fit.go safeCut `rankCut(rs, i, depth > 0)` -> `cutSpace` -> RED.
func TestHalvingKeepsPhrasesTogether(t *testing.T) {
	for _, phrase := range []string{"до 5 минут", "прирост 50 % за год", "к 12 апреля", "на 30% меньше"} {
		for pad := 0; pad < 6; pad++ {
			unit := strings.Repeat("123 456 789, ", 13)
			src := "Данные" + strings.Repeat("х", pad) + ": " + unit + phrase + ", " + unit + "итого."
			got, err := Parse(src, youtubeOpts)
			if err != nil {
				t.Fatal(err)
			}
			if len(got) < 2 {
				t.Fatalf("%q pad %d: not split (%d chunk)", phrase, pad, len(got))
			}
			together := false
			for _, c := range got {
				if n := len([]rune(c.Spoken)); n > youtubeOpts.MaxSpokenChars {
					t.Errorf("%q pad %d: Spoken %d runes", phrase, pad, n)
				}
				together = together || strings.Contains(c.Text, phrase)
			}
			if !together {
				t.Errorf("%q pad %d: the phrase is cut across chunks: %q", phrase, pad, texts(got))
			}
		}
	}
}

func texts(cs []Chunk) []string {
	var out []string
	for _, c := range cs {
		out = append(out, c.Text)
	}
	return out
}

// No safe place to cut (every space touches a digit): the chunk stays whole and
// its numbers stay digits, so Spoken (= Text here) is under the cap.
// Mutation: chunk_fit.go split `plain: true` -> `plain: false` -> RED.
func TestNoSafeCutKeepsDigits(t *testing.T) {
	src := strings.Repeat("111 222 333 и ", 25) + "444."
	got, err := Parse(src, youtubeOpts)
	if err != nil || len(got) != 1 {
		t.Fatalf("%v %d chunks", err, len(got))
	}
	if n := len([]rune(got[0].Spoken)); n > youtubeOpts.MaxSpokenChars || !strings.Contains(got[0].Spoken, "111 222 333") {
		t.Errorf("Spoken has %d runes, want digits kept and <= cap: %q", n, got[0].Spoken)
	}
}

// Quotes: a cut inside «…» only when no other cut exists.
// Mutation: chunk_fit.go rankCut `pick(inQuote, cutClause, cutClauseInQuote)` -> `cutClause` -> RED.
func TestHalvingAvoidsQuotes(t *testing.T) {
	u := func(n int) string { return strings.Repeat("123 456 789, ", n) }
	src := "Ряд: " + u(6) + "«" + u(3) + "123 456 789» " + u(6) + "итого."
	got, err := Parse(src, youtubeOpts)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) < 2 {
		t.Fatalf("not split: %d chunk", len(got))
	}
	for _, c := range got {
		if strings.Count(c.Text, "«") != strings.Count(c.Text, "»") {
			t.Errorf("a chunk cuts inside the quote: %q", texts(got))
		}
	}
}
