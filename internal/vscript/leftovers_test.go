package vscript

import (
	"errors"
	"strings"
	"testing"
)

// #147 item 1: two trailing pauses add up and are capped at MaxPause.
// Mutation: markup.go `PauseAfter = min(pending, MaxPause)` -> `= pending` -> RED.
func TestTrailingPauseCapped(t *testing.T) {
	cs, err := Parse("Привет. [pause 6s][pause 6s]", testOpts)
	if err != nil {
		t.Fatal(err)
	}
	if got := cs[len(cs)-1].PauseAfter; got != MaxPause {
		t.Errorf("trailing PauseAfter = %v, want %v", got, MaxPause)
	}
}

// #147 item 2: a format character before an inner "(" is trimmed on the
// inner text too, so Spoken never opens with Cf + "(".
// Mutation: chunk.go unparen drops trimLead(inner) -> RED.
func TestSpokenInnerFormatCharBeforeParen(t *testing.T) {
	got := Spoken("(​(a) b) c")
	if got != "a — b — c" {
		t.Errorf("Spoken = %q, want %q", got, "a — b — c")
	}
}

// #147 item 4: option errors are plain configuration errors, not script lines.
// Mutation: markup.go validate returns &LineError{1, ...} again -> RED.
func TestOptionErrorsAreNotLineErrors(t *testing.T) {
	_, err := Parse("Привет.", Options{TargetChars: 0, MaxChars: 10, MinChars: 1, MaxScriptChars: 100})
	var le *LineError
	if err == nil || errors.As(err, &le) || strings.HasPrefix(err.Error(), "line ") {
		t.Errorf("option error = %v (LineError %v)", err, le)
	}
}

// #149.7: the abbreviation expander never glues words, honours all-caps text
// and keeps the closing dot of «и т.д.» before a closing quote or bracket;
// the dotless "т.е" is a documented gap and stays as written.
// Mutation: abbrev.go expandAbbreviations drops the separator after the
// replacement -> "то естьт.к." -> RED (glued row).
func TestSpokenAbbreviationEdges(t *testing.T) {
	for in, want := range map[string]string{
		"Это т.е.т.к. так.":                 "Это то есть так как так.",
		"Яблоки и т.д.потом груши.":         "Яблоки и так далее потом груши.",
		"ТАК Т.Е. ВСЁ":                      "ТАК ТО ЕСТЬ ВСЁ",
		"Он сказал «яблоки и т.д.» и ушёл.": "Он сказал «яблоки и так далее.» и ушёл.",
		"Яблоки (груши и т.д.) лежат.":      "Яблоки (груши и так далее.) лежат.",
		"Это т.е без точки.":                "Это т.е без точки.",
	} {
		if got := Spoken(in); got != want {
			t.Errorf("Spoken(%q) = %q, want %q", in, got, want)
		}
	}
}

// #180: an English script keeps its digits; a Russian one gets number words;
// a script with no letters keeps the Russian reading it always had.
// Mutation: markup.go Parse, `o.Language = ScriptLanguage(src)` removed ->
// the English row gets "двадцать пять" -> RED.
// Mutation: chunk_fit.go fitted.spoken, call Spoken instead of spokenIn -> RED.
func TestSpokenFollowsTheScriptLanguage(t *testing.T) {
	for _, c := range []struct{ src, want string }{
		{"I am 25 years old.", "I am 25 years old."},
		{"Мне 25 лет.", "Мне двадцать пять лет."},
		{"Мне 25 years old.", "Мне двадцать пять years old."},
		{"2026.", "две тысячи двадцать шесть."},
	} {
		cs, err := Parse(c.src, testOpts)
		if err != nil {
			t.Fatal(err)
		}
		if cs[0].Spoken != c.want {
			t.Errorf("Parse(%q).Spoken = %q, want %q", c.src, cs[0].Spoken, c.want)
		}
		if cs[0].Text != strings.TrimSpace(c.src) {
			t.Errorf("Text = %q: the subtitles keep what was written", cs[0].Text)
		}
	}
	// The English language also holds across the Spoken-length split.
	o := testOpts
	o.MaxSpokenChars = 40
	long := "We shipped 1000 units in 2025, and then we sold another 2000 units in 2026 across all regions."
	cs, err := Parse(long, o)
	if err != nil {
		t.Fatal(err)
	}
	// Length is judged on what is spoken: digits stay short, so this fits whole.
	o.MaxSpokenChars = 60
	one, err := Parse("We shipped 1000 units, in 2025, and 2000 in 2026.", o)
	if err != nil || len(one) != 1 {
		t.Errorf("an English sentence of 50 characters was split for a Russian reading it never gets: %d chunks, %v", len(one), err)
	}
	for _, ch := range cs {
		if strings.ContainsAny(ch.Spoken, "абвгдежзиклмнопрстуфхцчшщыэюя") {
			t.Errorf("English chunk %q got Russian words: %q", ch.Text, ch.Spoken)
		}
	}
}

func TestScriptLanguage(t *testing.T) {
	for in, want := range map[string]string{"Привет": "ru", "Hello": "en", "Hello, привет": "ru", "2026 !": "", "": ""} {
		if got := ScriptLanguage(in); got != want {
			t.Errorf("ScriptLanguage(%q) = %q, want %q", in, got, want)
		}
	}
}

// Reviewer #311: Russian words in a cue or directive do not make an English
// script Russian; a Russian script with an English quoted word stays Russian.
// Mutation: markup.go Parse, `spokenLanguage(src)` -> `ScriptLanguage(src)` -> RED.
func TestLanguageIsDecidedFromTheSpokenText(t *testing.T) {
	for _, c := range []struct{ src, want string }{
		{"(шёпотом) I have 25 apples.", "(шёпотом) I have 25 apples."},
		{"[style: спокойно и тепло]\nI have 25 apples.", "I have 25 apples."},
		{"Мне 25 лет, и я сказал «hello».", "Мне двадцать пять лет, и я сказал «hello»."},
	} {
		cs, err := Parse(c.src, testOpts)
		if err != nil {
			t.Fatal(err)
		}
		want := c.want
		if strings.HasPrefix(want, "(") {
			want = "шёпотом — I have 25 apples." // the cue is folded by Spoken, the digits stay
		}
		if cs[0].Spoken != want {
			t.Errorf("Parse(%q).Spoken = %q, want %q", c.src, cs[0].Spoken, want)
		}
	}
}
