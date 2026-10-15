package wordalign

import (
	"math"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// Digit wildcards (bounded by digit count), ASR slips, order, insertions.
// Mutation: drop the hyp-side digit branch in cell -> "10"/"десять" = 1 -> RED.
// Mutation: compare with == instead of voices.SameWord -> "сохранит" = 1 -> RED.
// Mutation: remove the 2*digits bound -> the "5 и шесть семь восемь" row = 0 -> RED.
// Mutation: drop the ё -> е replacement in Words -> "всё"/"все" = 1 -> RED.
func TestWER(t *testing.T) {
	cases := []struct {
		ref, hyp string
		errs, n  int
	}{
		{"В 1998 году всё изменилось.", "в тысяча девятьсот девяносто восьмом году всё изменилось", 0, 5},
		{"Прошло десять лет.", "прошло 10 лет", 0, 3},
		{"Ёлка стоит.", "елка стоит", 0, 2},
		{"Сохранить видео.", "сохранит видео", 0, 2},
		{"Один два три.", "три два один", 2, 3},
		{"Спасибо за внимание.", "спасибо за внимание а а а а", 4, 3},
		{"Сохраните это видео.", "сохраните видео", 1, 3},
		{"Ровно 5 минут.", "ровно пять и шесть семь восемь минут", 3, 3},
		// ё -> е matters below the slip threshold (words under four letters).
		{"Всё хорошо.", "все хорошо", 0, 2},
	}
	for _, c := range cases {
		if e, n := WER(c.ref, c.hyp); e != c.errs || n != c.n {
			t.Errorf("WER(%q, %q) = %d/%d, want %d/%d", c.ref, c.hyp, e, n, c.errs, c.n)
		}
	}
}

// Oracle not written by us: score.py's WER on the parent Task 1 runs; on
// lines without digits the two agree within 0.02 (score.py has no slip
// tolerance, so ours may only be lower).
func TestWERAgreesWithScorePy(t *testing.T) {
	raw, err := os.ReadFile("testdata/score_py_wer.tsv")
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n")[1:] {
		f := strings.Split(line, "\t")
		if len(f) < 3 || strings.ContainsAny(f[0]+f[1], "0123456789") {
			continue
		}
		want, _ := strconv.ParseFloat(f[2], 64)
		e, words := WER(f[0], f[1])
		got := float64(e) / float64(max(1, words))
		if got > want+0.02 || got < want-0.10 {
			t.Errorf("%q / %q: %.3f vs score.py %.3f", f[0], f[1], got, want)
		}
		n++
	}
	if n < 50 {
		t.Fatalf("only %d comparable lines", n)
	}
}

// Every written word gets a time inside the audio, monotone; a number
// spans its spoken words; an unheard word is interpolated.
// Mutation: skip fillGaps -> the unheard word keeps -1 -> RED.
func TestAlignWords(t *testing.T) {
	heard := []voices.Word{{W: "в", S: 0.1, E: 0.2}, {W: "тысяча", S: 0.2, E: 0.6}, {W: "девятьсот", S: 0.6, E: 1.0},
		{W: "девяносто", S: 1.0, E: 1.4}, {W: "восьмом", S: 1.4, E: 1.8}, {W: "году", S: 1.8, E: 2.1}, {W: "изменилось", S: 2.6, E: 3.2}}
	got := AlignWords("В 1998 году всё изменилось.", heard, 3.5)
	if len(got) != 5 || got[0].W != "В" || got[4].W != "изменилось." {
		t.Fatalf("%+v", got)
	}
	if got[1].S != 0.2 || got[1].E != 1.8 {
		t.Errorf("number span %+v, want 0.2-1.8", got[1])
	}
	if got[3].S < got[2].E || got[3].E > got[4].S || got[3].E <= got[3].S {
		t.Errorf("unheard word not interpolated: %+v", got[3])
	}
	for i := 1; i < len(got); i++ {
		if got[i].S < got[i-1].S {
			t.Errorf("not monotone at %d: %+v", i, got)
		}
	}
}

// Cues end at sentence ends and before 84 chars or 6 s; long cues wrap.
// Mutation: drop the MaxCueSeconds check -> a 7 s cue -> RED.
func TestCues(t *testing.T) {
	var ws []voices.Word
	tm := 0.0
	for _, w := range strings.Fields("Первое короткое. Второе предложение очень длинное и тянется долго, потому что в нём много слов подряд без точки вообще никогда.") {
		ws = append(ws, voices.Word{W: w, S: tm, E: tm + 0.3})
		tm += 0.6
	}
	cues := Cues(ws)
	if cues[0].Text != "Первое короткое." {
		t.Fatalf("first cue %q", cues[0].Text)
	}
	for _, c := range cues {
		if len([]rune(strings.ReplaceAll(c.Text, "\n", " "))) > MaxCueChars || c.E-c.S > MaxCueSeconds+1e-9 {
			t.Errorf("cue too long: %+v", c)
		}
	}
}

// A written word of several tokens spans from its first to its last token; a
// spoken digit token is split evenly across the written words it stands for.
// Mutation: drop the `out[wi].E = tok[ti].E` update in AlignWords -> RED.
// Mutation: drop the `di > 1 && dj == 1` case in tokenTimes -> RED.
func TestAlignWordsMultiToken(t *testing.T) {
	heard := []voices.Word{{W: "кто", S: 0.0, E: 0.4}, {W: "то", S: 0.4, E: 0.8}, {W: "1900", S: 1.0, E: 2.0}, {W: "году", S: 2.0, E: 2.4}}
	got := AlignWords("кто-то тысяча девятьсот году", heard, 2.4)
	if len(got) != 4 {
		t.Fatalf("%+v", got)
	}
	if got[0].S != 0.0 || got[0].E != 0.8 {
		t.Errorf("hyphenated word %+v, want 0-0.8", got[0])
	}
	if got[1].S != 1.0 || got[1].E != 1.5 || got[2].S != 1.5 || got[2].E != 2.0 {
		t.Errorf("split number %+v %+v, want 1-1.5 and 1.5-2", got[1], got[2])
	}
}

// The character limit alone (words too quick for the time limit) ends a cue.
// Two full 42-character lines are 85 characters with their line break counted
// as a space, one over MaxCueChars.
// Mutation: drop the MaxCueChars check -> one cue of 120+ characters -> RED.
func TestCuesCharLimit(t *testing.T) {
	var full []voices.Word
	for i, n := range []int{20, 21, 20, 21} {
		full = append(full, voices.Word{W: strings.Repeat("я", n), S: float64(i) * 0.1, E: float64(i)*0.1 + 0.08})
	}
	if got := Cues(full); len(got) != 2 {
		t.Errorf("%d cues for two 42-character lines, want 2: %+v", len(got), got)
	}
	var ws []voices.Word
	for i := 0; i < 40; i++ {
		ws = append(ws, voices.Word{W: "слово", S: float64(i) * 0.05, E: float64(i)*0.05 + 0.04})
	}
	cues := Cues(ws)
	if len(cues) < 2 {
		t.Fatalf("%d cues, want a split", len(cues))
	}
	for _, c := range cues {
		if n := len([]rune(strings.ReplaceAll(c.Text, "\n", " "))); n > MaxCueChars {
			t.Errorf("cue of %d characters: %q", n, c.Text)
		}
	}
}

// STT (Parakeet) writes a hyphenated word whole; the script's form splits the
// same way under Words, so WER and AlignWords must tokenise both sides alike.
// Mutation: in WER tokenise either side with strings.Fields instead of Words
// -> WER 4/7 or 4/5, RED. The AlignWords side is pinned by
// TestHyphenatedHeardSplitsAcrossWrittenWords.
func TestHyphenatedWordsAgree(t *testing.T) {
	const text = "Кто-то пришёл и сказал по-русски."
	heard := []voices.Word{{W: "Кто-то", S: 0, E: 0.4}, {W: "пришел", S: 0.4, E: 0.8}, {W: "и", S: 0.8, E: 0.88},
		{W: "сказал", S: 0.88, E: 1.28}, {W: "по-русски,", S: 1.28, E: 1.84}}
	var heardText []string
	for _, h := range heard {
		heardText = append(heardText, h.W)
	}
	if e, n := WER(text, strings.Join(heardText, " ")); e != 0 || n != 7 {
		t.Errorf("WER = %d/%d, want 0/7", e, n)
	}
	got := AlignWords(text, heard, 2)
	want := []voices.Word{{W: "Кто-то", S: 0, E: 0.4}, {W: "пришёл", S: 0.4, E: 0.8}, {W: "и", S: 0.8, E: 0.88},
		{W: "сказал", S: 0.88, E: 1.28}, {W: "по-русски.", S: 1.28, E: 1.84}}
	if len(got) != len(want) {
		t.Fatalf("%+v", got)
	}
	for i := range want {
		if got[i].W != want[i].W || math.Abs(got[i].S-want[i].S) > 1e-9 || math.Abs(got[i].E-want[i].E) > 1e-9 {
			t.Errorf("word %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

// The other way round: STT's whole hyphenated word is shared by the written
// words it covers, half its time each.
// Mutation: as above (join the heard tokens) -> the two written words get
// 0-0.8 / interpolated times -> RED.
func TestHyphenatedHeardSplitsAcrossWrittenWords(t *testing.T) {
	heard := []voices.Word{{W: "Кто-то", S: 0, E: 0.8}, {W: "пришел", S: 0.8, E: 1.2}}
	got := AlignWords("Кто то пришёл", heard, 1.2)
	want := [][2]float64{{0, 0.4}, {0.4, 0.8}, {0.8, 1.2}}
	if len(got) != len(want) {
		t.Fatalf("%+v", got)
	}
	for i, w := range want {
		if math.Abs(got[i].S-w[0]) > 1e-9 || math.Abs(got[i].E-w[1]) > 1e-9 {
			t.Errorf("word %d = %+v, want %.1f-%.1f", i, got[i], w[0], w[1])
		}
	}
}

// gateMaxWER mirrors the produce gate's word-error threshold (0.10).
const gateMaxWER = 0.10

// A digit token stands for spoken numerals only: babble it would absorb costs.
// Mutation: wer.go isNumeral returns true for every word -> the babble rows
// score 0 -> RED.
func TestWERNumberWordsMustBeNumerals(t *testing.T) {
	for _, c := range []struct {
		ref, hyp string
		errs     int
	}{
		{"Нас 10 человек.", "нас бла бла бла бла человек", 4},
		{"нас бла бла бла бла человек", "Нас 10 человек.", 4},
		{"Нас 10 человек.", "нас десять человек", 0},
		{"Тут 21 человек.", "тут двадцать один человек", 0},
	} {
		if e, _ := WER(c.ref, c.hyp); e != c.errs {
			t.Errorf("WER(%q, %q) errors = %d, want %d", c.ref, c.hyp, e, c.errs)
		}
	}
	if e, n := WER("Нас 10 человек.", "нас бла бла бла бла человек"); float64(e)/float64(n) <= gateMaxWER {
		t.Errorf("babble inside a number passes the gate: %d/%d", e, n)
	}
}

// Real spoken numbers stay free in both directions; each written form below is
// the TTS/STT variant of its spoken form.
// Mutation: drop the numeralStems entries "тысяч"/"восьм"/"двенадцат"... is
// covered per row; drop signUnits for '%' -> "сорок процентов" row RED.
func TestWERNumberForms(t *testing.T) {
	for _, c := range [][2]string{
		{"Двадцать один год.", "21 год"},
		{"Две целых пять десятых.", "2,5"},
		{"Встреча в 18:30.", "встреча в восемнадцать тридцать"},
		{"Сорок процентов.", "40%"},
		{"Скидка 40 %.", "скидка сорок процентов"},
		{"Цена 500 ₽.", "цена пятьсот рублей"},
		{"Двенадцатого апреля.", "12 апреля"},
		{"В тысяча девятьсот девяносто восьмом.", "в 1998"},
		{"Путь третьего класса.", "путь 3-го класса"},
		{"Путь 3-го класса.", "путь третьего класса"},
		{"Миллион рублей.", "1 000 000 рублей"},
		{"1 000 000 рублей.", "миллион рублей"},
		{"1 000 рублей.", "тысяча рублей"},
		{"В 90-х годах.", "в девяностых годах"},
		{"От 10–15 человек.", "от десяти пятнадцати человек"},
	} {
		if e, _ := WER(c[0], c[1]); e != 0 {
			t.Errorf("WER(%q, %q) = %d errors, want 0", c[0], c[1], e)
		}
	}
	// An en-dash range stays two numbers; a babble word in its place is an error.
	if e, _ := WER("10–15 человек", "бла бла человек"); e != 2 {
		t.Errorf("range vs babble = %d, want 2", e)
	}
}

// Marks and quote styles do not make a different word.
// Mutation: wer.go normalise keeps unicode.Mn -> "сло́во" row RED; keeps
// U+00AD -> "мо­локо" row RED; drops the ’ mapping -> "don’t" row RED.
func TestWERNormalisation(t *testing.T) {
	for _, c := range [][2]string{
		{"сло́во", "слово"},
		{"мо­локо", "молоко"},
		{"don’t stop", "don't stop"},
		{"й ну", "й ну"},
	} {
		if e, _ := WER(c[0], c[1]); e != 0 {
			t.Errorf("WER(%q, %q) = %d, want 0", c[0], c[1], e)
		}
	}
}

// score.py's fixture has no real error rows, so it only guards strictness; this
// guards leniency: genuinely wrong hyps must stay above the gate threshold.
// Mutation: voices/tail.go SameWord tolerance n/5 -> n/2 -> "стол"/"слон" and
// the wrong-word rows fall below the threshold -> RED.
func TestWERLeniency(t *testing.T) {
	const ref = "Сегодня в Петербурге ясная погода, и мы идём гулять по набережной."
	e0, n0 := WER("Он купил большой стол и красный диван.", "он купил большой слон и красный диван")
	if float64(e0)/float64(n0) <= gateMaxWER {
		t.Errorf("a different word (стол/слон) passes the gate: %d/%d", e0, n0)
	}
	for name, hyp := range map[string]string{
		"wrong words":  "сегодня в москве пасмурная погода и мы идем спать по лестнице",
		"dropped part": "сегодня в петербурге ясная погода",
		"babble tail":  ref + " бла бла бла бла бла",
		"babble mid":   "сегодня в петербурге бла бла бла ясная погода и мы идем гулять по набережной",
	} {
		e, n := WER(ref, hyp)
		if got := float64(e) / float64(n); got <= gateMaxWER {
			t.Errorf("%s: %d/%d = %.2f passes the gate", name, e, n, got)
		}
	}
}

// settle: overlapping and overlong heard words keep the times inside the audio
// and the starts non-decreasing.
// Mutation: AlignWords returns out without settle -> RED.
func TestAlignWordsSettled(t *testing.T) {
	heard := []voices.Word{{W: "а", S: 0, E: 1.0}, {W: "б", S: 0.8, E: 1.5}, {W: "в", S: 0.2, E: 9}}
	got := AlignWords("а б в", heard, 2)
	prev := 0.0
	for i, w := range got {
		if w.S < prev || w.S < 0 || w.E > 2 || w.E < w.S {
			t.Errorf("word %d = %+v (prev start %.2f)", i, w, prev)
		}
		prev = w.S
	}
}

// A number written in groups is one written word with the time of its spoken
// words, whichever side writes the groups.
// Mutation: AlignWords uses strings.Fields instead of writtenWords -> RED.
func TestAlignWordsGroupedNumber(t *testing.T) {
	heard := []voices.Word{{W: "миллион", S: 0, E: 0.6}, {W: "рублей", S: 0.6, E: 1.0}}
	got := AlignWords("1 000 000 рублей", heard, 1)
	if len(got) != 2 || got[0].W != "1 000 000" || got[0].S != 0 || got[0].E != 0.6 || got[1].S != 0.6 {
		t.Errorf("%+v", got)
	}
	heard = []voices.Word{{W: "1", S: 0, E: 0.2}, {W: "000", S: 0.2, E: 0.4}, {W: "000", S: 0.4, E: 0.6}, {W: "рублей", S: 0.6, E: 1.0}}
	got = AlignWords("миллион рублей", heard, 1)
	if len(got) != 2 || got[0].S != 0 || got[0].E != 0.6 || got[1].S != 0.6 {
		t.Errorf("joined heard groups: %+v", got)
	}
}

// Lines are filled greedily to MaxCueLine and a cue never needs a third line;
// a word longer than a line stands alone.
// Mutation: fits returns true -> the three-line text is one cue -> RED.
func TestCuesWrapLimits(t *testing.T) {
	long := strings.Repeat("я", MaxCueLine+8)
	if got := wrap(long + " ок"); got != long+"\nок" {
		t.Errorf("long word: %q", got)
	}
	// 3 x 25 characters fit MaxCueChars but not two greedy lines.
	var wide []voices.Word
	for i := 0; i < 3; i++ {
		wide = append(wide, voices.Word{W: strings.Repeat("я", 25), S: float64(i) * 0.1, E: float64(i)*0.1 + 0.08})
	}
	if got := Cues(wide); len(got) != 2 {
		t.Errorf("%d cues for three 25-character words, want 2: %+v", len(got), got)
	}
	var ws []voices.Word
	for i := 0; i < 24; i++ {
		ws = append(ws, voices.Word{W: "слово", S: float64(i) * 0.1, E: float64(i)*0.1 + 0.08})
	}
	cues := Cues(ws)
	if len(cues) < 2 {
		t.Fatalf("one cue for 24 words: %q", cues[0].Text)
	}
	for _, c := range cues {
		lines := strings.Split(c.Text, "\n")
		if len(lines) > 2 {
			t.Errorf("%d lines: %q", len(lines), c.Text)
		}
		for _, l := range lines {
			if n := len([]rune(l)); n > MaxCueLine {
				t.Errorf("line of %d: %q", n, l)
			}
		}
	}
}
