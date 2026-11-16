package glossary

import (
	"bufio"
	"compress/gzip"
	"os"
	"strings"
	"testing"
	"unicode"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// The stem of a noun is the same in every case; a stem under minStemRunes, a derivation and a verb form are
// not a case of the heard word. The words are ordinary Russian ones.
// Mutation: stem.go minStemRunes = 5 -> 3 -> RED («воля» then keys to «вол»; the dictionary
// test below fails). Mutation: stem.go nominalStem, drop `|| !nounEndings[w[len(st):]]` -> RED («машина» then matches «машинный»).
func TestNominalStemGuard(t *testing.T) {
	for _, c := range []struct{ w, want string }{
		{"гитхаб", "гитхаб"}, {"гитхабе", "гитхаб"}, {"дэвин", "дэвин"}, {"дэвина", "дэвин"}, {"дэвином", "дэвин"},
		{"машина", "машин"}, {"машины", "машин"}, {"машиной", "машин"}, {"хормозов", "хормоз"},
		{"вол", ""}, {"воля", ""}, {"воле", ""}, {"поле", ""}, {"пол", ""}, {"школа", ""}, {"окс", ""}, // a stem under 5 letters
		{"машинный", ""}, {"странный", ""}, {"работать", ""}, {"платить", ""}, // a derivation or a verb form
		{"github", ""}, {"гит-хаб", ""}, {"дэвин2", ""}, // not Russian letters only
	} {
		if got := nominalStem(c.w); got != c.want {
			t.Errorf("nominalStem(%q) = %q, want %q", c.w, got, c.want)
		}
	}
}

// Another case of a heard word is replaced; a different word that shares its first letters, or a short stem, is not.
// Mutation: apply.go matchAt, `sameWord(h, c.stem(k, exact), fold(toks[j].s))` -> `sameWord(h, "", fold(toks[j].s))` -> RED (no inflected form is replaced).
func TestApplyMatchesInflectedForms(t *testing.T) {
	pairs := []Pair{
		{Heard: "дэвин", Meant: "Devin", Status: Active},
		{Heard: "гитхаб", Meant: "GitHub", Status: Active},
		{Heard: "машина", Meant: "Machine", Status: Active}, // an ordinary word, filed by mistake
		{Heard: "вол", Meant: "Vol", Status: Active},
		{Heard: "окс сей", Meant: "OxSay", Status: Active},
	}
	for _, c := range []struct{ in, want string }{
		{"спроси у дэвина", "спроси у Devin"},
		{"выложи в гитхабе", "выложи в GitHub"},
		{"Дэвин и Гитхаб", "Devin и GitHub"},
		{"с дэвином в гитхабу", "с Devin в GitHub"},
		{"машины нет, в машине тоже", "Machine нет, в Machine тоже"},
		{"окс сей", "OxSay"},
		{"окс сеи", "окс сеи"},
		// not another case of the heard word: a derivation, a short stem
		{"машинный машинка машинист машинально", "машинный машинка машинист машинально"},
		{"воля вола воле", "воля вола воле"},
		{"дэвинский", "дэвинский"},
		{"вол", "Vol"},
	} {
		if got, _ := Apply(c.in, pairs); got != c.want {
			t.Errorf("Apply(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// An exact heard form wins over a stem match, whatever the order of the pairs: «дэвина» filed as its own pair is
// not taken by the pair filed as «дэвин».
// Mutation: apply.go firstMatch, `[]bool{true, false}` -> `[]bool{false}` -> RED (matchWords shares it).
func TestExactFormBeatsStemMatch(t *testing.T) {
	a := Pair{Heard: "дэвин", Meant: "Devin", Status: Active}
	b := Pair{Heard: "дэвина", Meant: "Devina", Status: Active}
	for _, pairs := range [][]Pair{{a, b}, {b, a}} {
		if got, _ := Apply("спроси дэвина и дэвин", pairs); got != "спроси Devina и Devin" {
			t.Errorf("Apply = %q, want %q", got, "спроси Devina и Devin")
		}
		ws := ApplyWords([]stt.Word{{W: "дэвина", S: 0, E: 1}, {W: "дэвин", S: 1, E: 2}}, pairs)
		if len(ws) != 2 || ws[0].W != "Devina" || ws[1].W != "Devin" {
			t.Errorf("ApplyWords = %+v", ws)
		}
	}
}

// A longer heard form still beats a shorter exact one: «дэвин робертса» is the pair filed as «дэвин робертс», whatever
// the exact pair «дэвин» says.
// Mutation: apply.go firstMatch, drop the grouping by length (one tier over all pairs) -> RED.
func TestLongerStemMatchBeatsShorterExact(t *testing.T) {
	pairs := []Pair{
		{Heard: "дэвин", Meant: "Devin", Status: Active},
		{Heard: "дэвин робертс", Meant: "Devin Roberts", Status: Active},
	}
	if got, _ := Apply("спроси дэвин робертса", pairs); got != "спроси Devin Roberts" {
		t.Errorf("Apply = %q, want %q", got, "спроси Devin Roberts")
	}
	ws := ApplyWords([]stt.Word{{W: "дэвин", S: 0, E: 1}, {W: "робертса", S: 1, E: 2}}, pairs)
	if len(ws) != 1 || ws[0].W != "Devin Roberts" {
		t.Errorf("ApplyWords = %+v", ws)
	}
}

// A Cyrillic meant is a word in a case of its own: a pair that fixes a Russian word is exact-only, so «Кролика»
// is not rewritten to «Кролик» and the meant cannot grow on a second pass.
// Mutation: apply.go compile, drop the `!hasCyrillic(p.Meant)` condition -> RED.
func TestCyrillicMeantIsExactOnly(t *testing.T) {
	pairs := []Pair{
		{Heard: "масква", Meant: "Москва", Status: Active},
		{Heard: "кролик", Meant: "Кролик", Status: Active},
		{Heard: "дэвин", Meant: "Дэвина Смит", Status: Active},
	}
	for _, c := range []struct{ in, want string }{
		{"в маскве и кролика", "в маскве и кролика"},
		{"масква, кролик", "Москва, Кролик"},
	} {
		if got, _ := Apply(c.in, pairs); got != c.want {
			t.Errorf("Apply(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	once, _ := Apply("спроси дэвин", pairs)
	if twice, _ := Apply(once, pairs); once != "спроси Дэвина Смит" || twice != once {
		t.Errorf("Apply once %q, twice %q", once, twice)
	}
	ws := ApplyWords([]stt.Word{{W: "маскве", S: 0, E: 1}}, pairs)
	if len(ws) != 1 || ws[0].W != "маскве" {
		t.Errorf("ApplyWords = %+v", ws)
	}
}

// The word-list path matches like the text path: an inflected word, and a multi-word form whose last word is inflected.
// Mutation: apply.go matchWordsAt, `sameWord(h, c.stem(k, exact), key(w))` -> `sameWord(h, "", key(w))` -> RED.
func TestApplyWordsMatchesInflectedForms(t *testing.T) {
	pairs := []Pair{
		{Heard: "дэвин", Meant: "Devin", Status: Active},
		{Heard: "окс сейлер", Meant: "OxSay", Status: Active},
	}
	ws := []stt.Word{{W: "спроси", S: 0, E: 1}, {W: "у", S: 1, E: 2}, {W: "дэвина,", S: 2, E: 3}, {W: "окс", S: 3, E: 4}, {W: "сейлере", S: 4, E: 5}}
	got := ApplyWords(ws, pairs)
	if len(got) != 4 || got[2].W != "Devin," || got[3].W != "OxSay" || got[3].S != 3 || got[3].E != 5 {
		t.Fatalf("ApplyWords = %+v", got)
	}
}

// The guard against over-matching, measured on the Russian dictionary the daemon ships (lower-case, flagged
// entries = lemmas): of the entries that may be matched by stem, at most 4% share their stem with another
// entry. It is 2.9% as shipped, 3.5% with a 4-letter minimum stem, 4.2% with 3, and 49% without the
// noun-ending rule.
// Mutation: stem.go minStemRunes = 3 -> RED; nominalStem, drop the nounEndings check -> RED.
func TestStemMatchingIsRareOnOrdinaryWords(t *testing.T) {
	f, err := os.Open("../wordlists/data/ru.dic.gz")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	sc := bufio.NewScanner(zr)
	classes := map[string]map[string]bool{}
	keyed := 0
	for sc.Scan() {
		w, _, ok := strings.Cut(sc.Text(), "/")
		if r, _ := utf8.DecodeRuneInString(w); !ok || !unicode.IsLower(r) || strings.ContainsAny(w, "-.") {
			continue
		}
		w = fold(w)
		st := nominalStem(w)
		if st == "" {
			continue
		}
		if classes[st] == nil {
			classes[st] = map[string]bool{}
		}
		if !classes[st][w] {
			classes[st][w] = true
			keyed++
		}
	}
	shared := 0
	for _, ws := range classes {
		if len(ws) > 1 {
			shared += len(ws)
		}
	}
	if keyed < 20000 {
		t.Fatalf("only %d dictionary entries are matched by stem; the dictionary or the stemmer changed", keyed)
	}
	t.Logf("%d entries matched by stem, %d share a stem with another (%.1f%%)", keyed, shared, 100*float64(shared)/float64(keyed))
	if rate := float64(shared) / float64(keyed); rate > 0.04 {
		t.Errorf("%.1f%% of the entries share a stem with another entry; want at most 4%%", 100*rate)
	}
}
