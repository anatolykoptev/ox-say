package wordalign

import (
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
// Mutation: drop the MaxCueChars check -> one cue of 120+ characters -> RED.
func TestCuesCharLimit(t *testing.T) {
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
