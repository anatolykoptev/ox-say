package glossary

import (
	"testing"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

func act(heard, meant string) Pair { return Pair{Heard: heard, Meant: meant, Status: Active} }

// Mutation: apply.go match, drop the `strings.TrimSpace(toks[j].s) != ""` check -> RED ("opportunities, code"
// is replaced although a comma separates the words).
func TestApply(t *testing.T) {
	pairs := []Pair{
		act("Воксей", "OxSay"), act("окс сей", "OxSay"), act("opportunities code", "opportunity-scout"),
		act("хормозе", "Hormozi"), act("github", "GitHub"),
		{Heard: "фейбл", Meant: "Fable", Status: Candidate}, {Heard: "сонет", Meant: "Sonnet", Status: Rejected},
	}
	cases := []struct {
		in, want string
		n        int
	}{
		{"Открой Воксей, пожалуйста.", "Открой OxSay, пожалуйста.", 1},
		{"по ХОРМОЗЕ и про окс  сей", "по Hormozi и про OxSay", 2},
		{"запусти opportunities code сейчас", "запусти opportunity-scout сейчас", 1},
		{"opportunities, code", "opportunities, code", 0},
		{"Воксейка не трогаем", "Воксейка не трогаем", 0},
		{"фейбл и сонет не применяются", "фейбл и сонет не применяются", 0},
		{"Окс Сёй", "OxSay", 1},             // ё folds to е
		{"Воксей здесь", "OxSay здесь", 1}, // decomposed й (и + U+0306) matches after NFC
		{"push to github", "push to GitHub", 1},
		{"push to GitHub", "push to GitHub", 0}, // already right: no count
	}
	for _, c := range cases {
		got, n := Apply(c.in, pairs)
		if got != c.want || n != c.n {
			t.Errorf("Apply(%q) = %q, %d; want %q, %d", c.in, got, n, c.want, c.n)
		}
	}
}

// The longest heard form wins, and a second pass changes nothing.
// Mutation: apply.go compile, delete the sort -> RED ("окс" wins over "окс сей").
func TestApplyLongestFirstAndIdempotent(t *testing.T) {
	pairs := []Pair{act("окс", "Ox"), act("окс сей", "OxSay")}
	once, _ := Apply("про окс сей и окс", pairs)
	if once != "про OxSay и Ox" {
		t.Fatalf("once = %q", once)
	}
	if twice, n := Apply(once, pairs); twice != once || n != 0 {
		t.Fatalf("second pass = %q, %d", twice, n)
	}
}

// Words keep timings: a two-word match becomes one word from the first start to the last end, with the lowest
// probability and the punctuation around it; a match across punctuation is refused, as in Apply.
// Mutation: apply.go matchWords, delete the `post != ""` refusal -> RED (" Окс," + " сей" merges).
func TestApplyWords(t *testing.T) {
	pairs := []Pair{act("окс сей", "OxSay")}
	ws := []stt.Word{{W: " про", S: 0, E: 0.3, P: 0.9}, {W: " Окс", S: 0.3, E: 0.6, P: 0.4}, {W: " сей,", S: 0.6, E: 0.9, P: 0.7}, {W: " да", S: 1, E: 1.2, P: 0.9}}
	got := ApplyWords(ws, pairs)
	want := []stt.Word{{W: " про", S: 0, E: 0.3, P: 0.9}, {W: " OxSay,", S: 0.3, E: 0.9, P: 0.4}, {W: " да", S: 1, E: 1.2, P: 0.9}}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("word %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	across := []stt.Word{{W: " Окс,", S: 0, E: 0.3}, {W: " сей", S: 0.3, E: 0.6}}
	if got := ApplyWords(across, pairs); len(got) != 2 || got[0].W != " Окс," {
		t.Fatalf("across punctuation: %+v", got)
	}
}

// "_" is a word character, so "foo_bar" is one word and a heard form can
// name it. A newline is a hard boundary: a multi-word match never spans
// one — the two sides are different lines of a subtitle.
// Mutation: apply.go isWordRune, drop the `r == '_'` case -> RED ("foo_bar" is not one word).
// Mutation: apply.go match, drop the newline check -> RED (the pair applies across a newline).
// Mutation: apply.go matchWords, drop the newline check -> RED.
func TestApplyMatcherEdges(t *testing.T) {
	under := []Pair{act("foo_bar", "Foo-Bar")}
	if got, _ := Apply("use foo_bar daily", under); got != "use Foo-Bar daily" {
		t.Fatalf("underscore = %q", got)
	}
	multi := []Pair{act("foo bar", "FB")}
	if got, n := Apply("foo\nbar baz", multi); got != "foo\nbar baz" || n != 0 {
		t.Fatalf("newline = %q, %d", got, n)
	}
	if got, n := Apply("foo bar baz", multi); got != "FB baz" || n != 1 {
		t.Fatalf("spaces still match = %q, %d", got, n)
	}
	ws := []stt.Word{{W: "foo", S: 0, E: 0.4, P: 0.9}, {W: "\nbar", S: 0.4, E: 0.8, P: 0.9}}
	if got := ApplyWords(ws, multi); len(got) != 2 || got[0].W != "foo" || got[1].W != "\nbar" {
		t.Fatalf("words across newline = %+v", got)
	}
	within := []stt.Word{{W: "foo", S: 0, E: 0.4, P: 0.9}, {W: " bar", S: 0.4, E: 0.8, P: 0.9}}
	if got := ApplyWords(within, multi); len(got) != 1 || got[0].W != "FB" || got[0].S != 0 || got[0].E != 0.8 {
		t.Fatalf("words within a line = %+v", got)
	}
}

// Mutation: apply.go ApplyResult, skip the Segments loop -> RED (subtitles keep the wrong word).
func TestApplyResult(t *testing.T) {
	res := &stt.Result{Text: "открой Воксей", Segments: []stt.Segment{{S: 0, E: 1, Text: "открой Воксей"}}, Words: []stt.Word{{W: "открой"}, {W: " Воксей"}}}
	if n := ApplyResult(res, []Pair{act("Воксей", "OxSay")}); n != 1 {
		t.Fatalf("n = %d", n)
	}
	if res.Text != "открой OxSay" || res.Segments[0].Text != "открой OxSay" || res.Words[1].W != " OxSay" {
		t.Fatalf("res = %+v", res)
	}
	if ApplyResult(nil, nil) != 0 {
		t.Fatal("nil result")
	}
}
