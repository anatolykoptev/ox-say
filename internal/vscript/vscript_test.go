package vscript

import (
	"errors"
	"math/rand"
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

// SpokenInline is the direct-request rewrite: the same abbreviations and
// numbers, but a leading "(…)" — the caller's own style cue for the engine —
// is never folded. Digits inside it still become words.
// Mutation: chunk.go SpokenInline -> Spoken -> the paren rows are RED.
func TestSpokenInlineKeepsLeadingParen(t *testing.T) {
	for in, want := range map[string]string{
		"(Шёпотом) Тише.":        "(Шёпотом) Тише.",
		"(за 5 минут) Привет.":   "(за пять минут) Привет.",
		"(тихо) Мне 25 лет.":     "(тихо) Мне двадцать пять лет.",
		"Это (в скобках) текст.": "Это (в скобках) текст.",
		"В 14:30, т.е. скоро.":   "В четырнадцать тридцать, то есть скоро.",
	} {
		if got := SpokenInline(in); got != want {
			t.Errorf("SpokenInline(%q) = %q, want %q", in, got, want)
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

// lineOf parses src and returns the LineError's line (0 for none).
func lineOf(t *testing.T, src string) int {
	t.Helper()
	_, err := Parse(src, testOpts)
	var le *LineError
	if !errors.As(err, &le) {
		t.Fatalf("%q: want a LineError, got %v", src, err)
	}
	return le.Line
}

// MAJOR 3: the reported line is the line of the offending directive, also
// after a style line, and with CRLF endings.
// Mutation: markup.go leadingStyle, return b.line instead of the counted
// bodyLine -> the style-first rows report line 1 -> RED.
func TestLineErrorNamesTheRightLine(t *testing.T) {
	for name, c := range map[string]struct {
		src  string
		want int
	}{
		"plain":               {"Привет [bad]", 1},
		"second paragraph":    {"Один.\n\nПривет [bad]", 3},
		"second line":         {"Один.\nДва [bad]", 2},
		"style first":         {"[style: calm]\nПривет [bad]", 2},
		"style inline":        {"[style: calm] Привет [bad]", 1},
		"style three lines":   {"[style: calm]\nОдин.\nДва [bad]", 3},
		"crlf":                {"Один.\r\n\r\n[style: calm]\r\nПривет [bad]", 4},
		"bad pause number":    {"Один.\n\nДва [pause 99s]", 3},
		"unknown after style": {"[style: calm]\nОдин.\n[music]", 3},
	} {
		if got := lineOf(t, c.src); got != c.want {
			t.Errorf("%s: %q reports line %d, want %d", name, c.src, got, c.want)
		}
	}
}

// Call-site gates through Parse (each a silent failure if broken).
// Mutations: markup.go `Spoken: Spoken(text)` -> `text`; `min(pending,
// MaxPause)` -> `pending`; script `utf8.RuneCountInString(src)` ->
// `len(src)`; style `utf8.RuneCountInString(style)` -> `len(style)`.
func TestParseCallSites(t *testing.T) {
	t.Run("spoken rewrite reaches the chunk", func(t *testing.T) {
		got, err := Parse("(Шёпотом) Тише.", testOpts)
		if err != nil || got[0].Spoken != "Шёпотом — Тише." || got[0].Text != "(Шёпотом) Тише." {
			t.Fatalf("%+v %v", got, err)
		}
	})
	t.Run("pauses add and cap at 10 s", func(t *testing.T) {
		got, err := Parse("Раз. [pause 6s] [pause 6s] Два.", testOpts)
		if err != nil || got[0].PauseAfter != MaxPause {
			t.Fatalf("%+v %v", got, err)
		}
	})
	t.Run("script limit counts runes", func(t *testing.T) {
		o := testOpts
		o.MaxScriptChars = 10
		if _, err := Parse(strings.Repeat("я", 10), o); err != nil {
			t.Errorf("10 runes (20 bytes) at limit 10: %v", err)
		}
		if _, err := Parse(strings.Repeat("я", 11), o); err == nil {
			t.Error("11 runes accepted at limit 10")
		}
	})
	t.Run("style limit counts runes", func(t *testing.T) {
		ok := "[style: " + strings.Repeat("я", MaxStyleChars) + "]\nТекст."
		if _, err := Parse(ok, testOpts); err != nil {
			t.Errorf("%d-rune style: %v", MaxStyleChars, err)
		}
		if _, err := Parse(strings.Replace(ok, "я]", "яя]", 1), testOpts); err == nil {
			t.Error("over-long style accepted")
		}
	})
}

// MAJOR 2: no input leaves Spoken opening with "(" (the engine would read it
// as a style tag), including hidden leading characters.
// Mutation: chunk.go Spoken, `for strings.HasPrefix` -> `if strings.HasPrefix`
// and drop the bracket stripping -> "((a)) b" stays ( -> RED.
func TestSpokenNeverOpensWithParen(t *testing.T) {
	for in, want := range map[string]string{
		"((a)) b":          "a — b",
		"(( x) y":          "x — y",
		"(((":              "",
		"() (b) c":         "b — c",
		"\u200B(x) y":      "x — y",
		" \uFEFF(x) y":     "x — y",
		"(x)":              "x",
		"(a)(b) c":         "a — (b) c",
		"(без закрывающей": "без закрывающей",
	} {
		got := Spoken(in)
		if got != want || strings.HasPrefix(got, "(") {
			t.Errorf("Spoken(%q) = %q, want %q", in, got, want)
		}
	}
}

// MAJOR 1: every chunk fits MaxChars, nothing is lost, nothing panics.
// Mutation: chunk.go nearest, drop `&& i+1 <= o.MaxChars` -> the far-comma
// cases and the fuzz exceed MaxChars -> RED.
func TestChunksNeverExceedMaxChars(t *testing.T) {
	for _, pos := range []int{300, 500, 900, 1500} {
		var b strings.Builder
		for b.Len() < pos {
			b.WriteString("слово ")
		}
		b.WriteString("слово, ")
		for b.Len() < 2400 {
			b.WriteString("слово ")
		}
		checkChunks(t, b.String(), testOpts)
	}
	alpha := []string{"а", "б", "слово", " ", " ", " ", ",", "; ", ", ", "— ", "- ", ".", ". ", "! ", "?", "\n", "Б", "т. е. ", "«", "»", "(", ")", "…", "é"}
	optSets := []Options{
		testOpts,
		{TargetChars: 120, MaxChars: 400, MinChars: 40, MaxScriptChars: 1 << 20},
		{TargetChars: 120, MaxChars: 150, MinChars: 40, MaxScriptChars: 1 << 20},
		{TargetChars: 50, MaxChars: 60, MinChars: 10, MaxScriptChars: 1 << 20},
	}
	for oi, o := range optSets {
		rng := rand.New(rand.NewSource(int64(oi) + 1))
		for it := 0; it < 1500; it++ {
			var b strings.Builder
			for k, n := 0, rng.Intn(400); k < n; k++ {
				b.WriteString(alpha[rng.Intn(len(alpha))])
			}
			checkChunks(t, b.String(), o)
		}
	}
}

func checkChunks(t *testing.T, src string, o Options) {
	t.Helper()
	cs, err := Parse(src, o)
	if err != nil {
		return // directive-looking noise or empty input
	}
	var got strings.Builder
	for _, c := range cs {
		if n := len([]rune(c.Text)); n > o.MaxChars {
			t.Fatalf("opts %+v: chunk of %d runes > MaxChars from %q", o, n, src)
		}
		if strings.HasPrefix(c.Spoken, "(") {
			t.Fatalf("Spoken %q opens with a paren, from %q", c.Spoken, src)
		}
		got.WriteString(c.Text)
	}
	if a, b := strings.Join(strings.Fields(got.String()), ""), strings.Join(strings.Fields(src), ""); a != b {
		t.Fatalf("opts %+v: text changed\n got %q\nwant %q", o, a, b)
	}
}

// MINOR: BOM, pauses at the script's edges, case-insensitive style, option
// validation, and the style-only-at-paragraph-start message.
// Mutations: markup.go drop TrimPrefix(BOM) -> "\uFEFF[style: x]" is text;
// drop the trailing `pending > 0` block -> last PauseAfter 0; drop the
// `len(out) == 0` pause check -> no error; styleRe without (?i) -> RED;
// drop o.validate() -> RED.
func TestParseEdges(t *testing.T) {
	if cs, err := Parse("\uFEFF[style: calm]\nПривет.", testOpts); err != nil || cs[0].Style != "calm" || strings.HasPrefix(cs[0].Text, "\uFEFF") {
		t.Errorf("BOM: %+v %v", cs, err)
	}
	if got := lineOf(t, "[pause 1s] Привет."); got != 1 {
		t.Errorf("leading pause line %d", got)
	}
	if _, err := Parse("[pause 1s] Привет.", testOpts); err == nil || !strings.Contains(err.Error(), "needs text before") {
		t.Errorf("leading pause: %v", err)
	}
	if cs, err := Parse("Привет. [pause 2s]", testOpts); err != nil || cs[0].PauseAfter != 2 {
		t.Errorf("trailing pause: %+v %v", cs, err)
	}
	for _, tag := range []string{"style", "Style", "STYLE"} {
		if cs, err := Parse("["+tag+": calm]\nПривет.", testOpts); err != nil || cs[0].Style != "calm" {
			t.Errorf("[%s: calm]: %+v %v", tag, cs, err)
		}
	}
	if _, err := Parse("Привет. [Style: calm]", testOpts); err == nil || strings.Contains(err.Error(), "unknown directive") {
		t.Errorf("mid-text style must say it is paragraph-start only, got %v", err)
	}
	if _, err := Parse("Привет [bad]", testOpts); err == nil || !strings.Contains(err.Error(), "unknown directive") {
		t.Errorf("unknown directive: %v", err)
	}
	for _, o := range []Options{
		{TargetChars: 0, MaxChars: 10, MinChars: 1, MaxScriptChars: 100},
		{TargetChars: 10, MaxChars: 9, MinChars: 1, MaxScriptChars: 100},
		{TargetChars: 10, MaxChars: 20, MinChars: 10, MaxScriptChars: 100},
		{TargetChars: 10, MaxChars: 20, MinChars: 0, MaxScriptChars: 100},
		{TargetChars: 10, MaxChars: 20, MinChars: 1},
	} {
		if _, err := Parse("Привет.", o); err == nil {
			t.Errorf("options %+v accepted", o)
		}
	}
}

// Unambiguous abbreviations are written out for the engine (it reads "т.е."
// as letters); ambiguous ones are left alone; a sentence-closing "и т.д."
// keeps its dot.
// Mutation: Spoken returns unparen(text) without expandAbbreviations -> RED.
func TestSpokenExpandsAbbreviations(t *testing.T) {
	for in, want := range map[string]string{
		"Начните с одного. Т.е. с простого.":    "Начните с одного. То есть с простого.",
		"Т.е. с самого простого.":               "То есть с самого простого.",
		"Это важно, т.е. срочно.":               "Это важно, то есть срочно.",
		"Это важно, т. е. срочно.":              "Это важно, то есть срочно.",
		"Это важно, т. е. срочно.":              "Это важно, то есть срочно.",
		"Купите хлеб, т.к. он кончился.":        "Купите хлеб, так как он кончился.",
		"Т. к. он кончился, купите хлеб.":       "Так как он кончился, купите хлеб.",
		"Хлеб, молоко и т.д. Потом домой.":      "Хлеб, молоко и так далее. Потом домой.",
		"Хлеб, молоко и т. д.":                  "Хлеб, молоко и так далее.",
		"Хлеб, молоко и т.д., и всё.":           "Хлеб, молоко и так далее, и всё.",
		"Хлеб, молоко и т.п. Потом домой.":      "Хлеб, молоко и тому подобное. Потом домой.",
		"Хлеб и т. п.":                          "Хлеб и тому подобное.",
		"И т.д. и т.п.":                         "И так далее и тому подобное.",
		"Напр. так.":                            "Например так.",
		"Есть, напр., такой случай.":            "Есть, например, такой случай.",
		"Т.н. эксперт и др. смотрите см. выше.": "Т.н. эксперт и др. смотрите см. выше.",
		"Кот.к. не трогаем, ват.е. тоже.":       "Кот.к. не трогаем, ват.е. тоже.",
		"(Шёпотом) т.е. тише.":                  "Шёпотом — то есть тише.",
	} {
		if got := Spoken(in); got != want {
			t.Errorf("Spoken(%q) = %q, want %q", in, got, want)
		}
	}
}

// The written text keeps the abbreviation (subtitles); only Spoken changes.
func TestChunkKeepsWrittenAbbreviation(t *testing.T) {
	got, err := Parse("Тогда начните с одного приёма. Т.е. с самого простого.", testOpts)
	if err != nil || len(got) != 1 || got[0].Text != "Тогда начните с одного приёма. Т.е. с самого простого." ||
		got[0].Spoken != "Тогда начните с одного приёма. То есть с самого простого." {
		t.Fatalf("%v %+v", err, got)
	}
}
