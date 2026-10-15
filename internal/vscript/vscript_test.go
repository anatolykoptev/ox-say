package vscript

import (
	"errors"
	"os"
	"strconv"
	"strings"
	"testing"
)

var testOpts = Options{TargetChars: 250, MaxChars: 400, MinChars: 80, MaxScriptChars: 40000, ChunkPause: 0.3, ParagraphPause: 0.7}

// unescapeTSV reads the fixtures' field escaping (F1-0 Step 6): `\n` is a
// newline, `\\` a backslash.
var unescapeTSV = strings.NewReplacer(`\\`, `\`, `\n`, "\n")

// Primary oracle: hand-checked cases "input<TAB>s1|s2|..." written by the
// controller (F1-0 Step 6c), never edited by the implementer.
// Mutation: delete the abbreviation branch in joins (sentences.go) -> "т.е." splits -> RED.
func TestSentencesHardCases(t *testing.T) {
	raw, err := os.ReadFile("testdata/hard_cases.tsv")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(lines) < 80 {
		t.Fatalf("%d hard cases, want >= 80", len(lines))
	}
	for _, line := range lines {
		in, exp, ok := strings.Cut(line, "\t")
		if !ok {
			t.Fatalf("malformed fixture line %q", line)
		}
		in, exp = unescapeTSV.Replace(in), unescapeTSV.Replace(exp)
		if got := strings.Join(Sentences(in), "|"); got != exp {
			t.Errorf("%q\n got %q\nwant %q", in, got, exp)
		}
	}
}

// Secondary oracle (razdel): chunk edges Parse produces at Target 120 fall
// on razdel sentence ends for >= 98 % of edges. The fixture's header records
// how many edges the same chunking yields on razdel's own sentences; this
// run must see at least that many, minus the same 2 % (both counts come from
// sentence splits that may differ by the 2 % the agreement rule allows).
// Mutation: delete rule 1 (the no-space join), rule 2 (lower case on the
// right) or rule 6 (initials) in joins -> sentences split inside "т.е.",
// mid-sentence or after "А." -> edges off razdel boundaries -> RED. Rules 3-5
// (delimiter, dash+lower, abbreviation) move no chunk edge on this corpus;
// TestSentencesHardCases is their gate.
func TestChunkEdgesAgreeWithRazdel(t *testing.T) {
	raw, err := os.ReadFile("testdata/razdel_edges.tsv")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	tag, num, _ := strings.Cut(lines[0], "\t")
	want, err := strconv.Atoi(num)
	if tag != "#edges" || err != nil || want < 40 {
		t.Fatalf("fixture header %q: want \"#edges<TAB>N\" with N >= 40", lines[0])
	}
	opts := Options{TargetChars: 120, MaxChars: 400, MinChars: 40, MaxScriptChars: 40000}
	edges, agree := 0, 0
	for _, line := range lines[1:] {
		para, offs, _ := strings.Cut(line, "\t")
		para = unescapeTSV.Replace(para)
		ends := map[int]bool{}
		for _, o := range strings.Split(offs, ",") {
			n, _ := strconv.Atoi(o)
			ends[n] = true
		}
		chunks, err := Parse(para, opts)
		if err != nil {
			t.Fatal(err)
		}
		pos := 0
		for _, c := range chunks[:len(chunks)-1] {
			i := strings.Index(para[pos:], c.Text)
			if i < 0 {
				t.Fatalf("chunk %q is not verbatim in its fixture paragraph: the fixture must have single ASCII spaces and no directives (F1-0 Step 6a)", c.Text)
			}
			pos += i + len(c.Text)
			edges++
			if ends[len([]rune(para[:pos]))] {
				agree++
			}
		}
	}
	if floor := want * 98 / 100; edges < floor {
		t.Fatalf("only %d chunk edges, the fixture records %d (floor %d)", edges, want, floor)
	}
	if float64(agree) < 0.98*float64(edges) {
		t.Fatalf("chunk edges on razdel boundaries: %d/%d", agree, edges)
	}
}

// Markup: pauses split and set the gap exactly; style is paragraph-scoped;
// the last chunk has no gap; unknown tags fail with the line.
// Mutation: make style sticky (keep it across paragraphs) -> chunk 3 -> RED.
func TestParseMarkup(t *testing.T) {
	src := "Первое предложение. Второе.\n\n[style: excited, fast]\nТретье! [pause 1.2s] Четвёртое.\n\nПятое."
	got, err := Parse(src, testOpts)
	if err != nil {
		t.Fatal(err)
	}
	type row struct {
		text, style string
		gap         float64
	}
	want := []row{
		{"Первое предложение. Второе.", "", 0.7},
		{"Третье!", "excited, fast", 1.2},
		{"Четвёртое.", "excited, fast", 0.7},
		{"Пятое.", "", 0},
	}
	if len(got) != len(want) {
		t.Fatalf("chunks %+v", got)
	}
	for i, w := range want {
		if got[i].Text != w.text || got[i].Style != w.style || got[i].PauseAfter != w.gap || got[i].Index != i {
			t.Errorf("chunk %d = %+v, want %+v", i, got[i], w)
		}
	}
	for _, bad := range []string{"Текст [music] дальше.", "Текст.\n[style: calm]", "[pause 99s] Текст.", "[style: ]\nТекст."} {
		var le *LineError
		if _, err := Parse(bad, testOpts); !errors.As(err, &le) || le.Line < 1 {
			t.Errorf("%q: want a LineError, got %v", bad, err)
		}
	}
}

// Sizes: <= MaxChars; a short tail joins its predecessor; paragraphs kept.
// Arithmetic: "Короткое предложение номер один." is 32 runes; 7 of them
// joined by spaces = 7*32+6 = 230 <= 250, an 8th would make 263 > 250, so
// 14 sentences give two chunks of 230. The 23-rune tail "Хвост из пары слов
// тут." does not fit greedily (230+1+23 = 254 > 250), so it starts a chunk
// of 23 < MinChars 80; the merge joins it (254 <= MaxChars 400).
// Mutation: drop the MinChars merge in chunkParagraph -> the last
// paragraph-0 chunk is the 23-rune tail -> RED.
func TestChunkSizes(t *testing.T) {
	long := strings.Repeat("Это довольно длинное предложение о погоде и о жизни, ", 9) + "конец."
	src := strings.Repeat("Короткое предложение номер один. ", 14) + "Хвост из пары слов тут.\n\n" + long
	got, err := Parse(src, testOpts)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range got {
		if n := len([]rune(c.Text)); n > testOpts.MaxChars {
			t.Errorf("chunk %d has %d runes", c.Index, n)
		}
	}
	last, para0 := -1, 0
	for _, c := range got {
		if c.Paragraph == 0 {
			last = c.Index
			para0++
		}
	}
	if para0 != 2 || len([]rune(got[last].Text)) < testOpts.MinChars || !strings.HasSuffix(got[last].Text, "один. Хвост из пары слов тут.") {
		t.Errorf("paragraph 0 has %d chunks; last %q (%d runes): the tail was not merged",
			para0, got[last].Text, len([]rune(got[last].Text)))
	}
	if got[len(got)-1].Paragraph != 1 {
		t.Fatalf("paragraphs %+v", got)
	}
}

// The only spoken rewrite: a leading "(x)" (the engine's tag parser,
// session.cpp:99-117). Mutation: return text unchanged -> RED.
func TestSpoken(t *testing.T) {
	for in, want := range map[string]string{
		"(Шёпотом) Тише.":        "Шёпотом — Тише.",
		"(без закрывающей Тише":  "без закрывающей Тише",
		"Это (в скобках) текст.": "Это (в скобках) текст.",
		"Это *важно*.":           "Это *важно*.",
	} {
		if got := Spoken(in); got != want {
			t.Errorf("Spoken(%q) = %q, want %q", in, got, want)
		}
	}
}

// #143.5: format characters and bracket lookalikes cannot survive.
// Mutation: drop the unicode.Cf case in CleanStyle -> RED.
func TestCleanStyle(t *testing.T) {
	for in, want := range map[string]string{
		"calm (and) warm": "calm and warm",
		"\u200b":          "",
		"a\u202eb\ufeffc": "abc",
		"\uFE59x\uFE5A \u207Dy\u207E \u208Dz\u208E \uFF08w\uFF09": "x y z w",
		"one\ntwo\tthree": "one two three",
	} {
		if got := CleanStyle(in); got != want {
			t.Errorf("CleanStyle(%q) = %q, want %q", in, got, want)
		}
	}
}
