package glossary

import (
	"bufio"
	"compress/gzip"
	"errors"
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
// Mutation: apply.go match, `!sameWord(h, c.stems[k], fold(toks[j].s))` -> `fold(toks[j].s) != h` -> RED (no inflected form is replaced).
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
// Mutation: apply.go match, `[]bool{true, false}` -> `[]bool{false}` (and in matchWords) -> RED.
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

// A meant form that holds the heard word in another case would be matched again on the next pass and grow.
// Mutation: store.go validate, containsForm -> containsSeq -> RED (the pair is filed and Apply twice doubles «Смит»).
func TestMeantHoldingAnotherCaseOfHeardIsRefused(t *testing.T) {
	s := newTestStore(t)
	if _, err := s.Add("дэвин", "Дэвина Смит", ""); !errors.Is(err, ErrInvalid) {
		t.Fatalf("Add: err = %v, want ErrInvalid", err)
	}
	p, err := s.Add("дэвин", "Devin", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Edit(p.ID, "Дэвина Смит"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("Edit: err = %v, want ErrInvalid", err)
	}
	once, _ := Apply("спроси у дэвина", []Pair{{Heard: "дэвин", Meant: "Devin Smith", Status: Active}})
	twice, _ := Apply(once, []Pair{{Heard: "дэвин", Meant: "Devin Smith", Status: Active}})
	if once != twice {
		t.Fatalf("Apply is not idempotent: %q then %q", once, twice)
	}
}

// The word-list path matches like the text path: an inflected word, and a multi-word form whose last word is inflected.
// Mutation: apply.go matchWords, `!sameWord(h, c.stems[k], key(w))` -> `key(w) != h` -> RED.
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
