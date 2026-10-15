package vscript

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// abbreviations end with a dot that does not end a sentence (razdel's
// abbreviation rule, MIT). Pair abbreviations keep their inner dot.
var abbreviations = map[string]bool{
	"т.е": true, "т.д": true, "т.п": true, "т.к": true, "т.н": true, "т.ч": true, "н.э": true, "и.о": true,
	"г": true, "гг": true, "в": true, "вв": true, "ул": true, "пр": true, "пер": true, "пл": true, "д": true,
	"кв": true, "корп": true, "им": true, "ст": true, "т": true, "тт": true, "руб": true, "коп": true,
	"тыс": true, "млн": true, "млрд": true, "трлн": true, "см": true, "рис": true, "стр": true, "гл": true,
	"п": true, "пп": true, "др": true, "проф": true, "акад": true, "доц": true, "св": true, "ок": true,
	"ср": true, "напр": true, "англ": true, "лат": true,
	"e.g": true, "i.e": true, "mr": true, "mrs": true, "dr": true, "vs": true, "etc": true, "st": true,
}

// spokenForms are the abbreviations the engine would read as letters ("тэ е")
// or skip, and that have exactly one reading in any case and number. Each
// pattern allows white space (incl. NBSP) between the parts and requires the
// closing dot. The text before the match must not be a letter, so "кот.е." or
// "ват.к." never match.
//
// Deliberately NOT expanded, because the reading depends on grammar the
// script does not carry: т.н. (так называемый/-ая/-ое/-ые), др. (другие /
// другой / другое), см. (смотри / смотрите), г./гг./ул./д./кв./пр./пер./стр.
// (case), руб./коп./тыс./млн./млрд. (declension by the number), т.ч., н.э.,
// и.о., ср., рис.
var spokenForms = []struct {
	re       *regexp.Regexp
	spoken   string
	endsSent bool // "и т.д." / "и т.п." usually close the sentence: the dot stays
}{
	{regexp.MustCompile(`(?i)(^|[^\p{L}])(т\.[\s\x{00a0}\x{202f}]*е\.)`), "то есть", false},
	{regexp.MustCompile(`(?i)(^|[^\p{L}])(т\.[\s\x{00a0}\x{202f}]*к\.)`), "так как", false},
	{regexp.MustCompile(`(?i)(^|[^\p{L}])(и[\s\x{00a0}]+т\.[\s\x{00a0}\x{202f}]*д\.)`), "и так далее", true},
	{regexp.MustCompile(`(?i)(^|[^\p{L}])(и[\s\x{00a0}]+т\.[\s\x{00a0}\x{202f}]*п\.)`), "и тому подобное", true},
	{regexp.MustCompile(`(?i)(^|[^\p{L}])(напр\.)`), "например", false},
}

// expandAbbreviations rewrites spokenForms in text, keeping a leading capital
// ("Т.е." -> "То есть"). A sentence-closing form keeps its dot when text ends
// there or a new sentence (capital, quote, dash) follows.
func expandAbbreviations(text string) string {
	for _, f := range spokenForms {
		var b strings.Builder
		last := 0
		for _, m := range f.re.FindAllStringSubmatchIndex(text, -1) {
			start, end := m[4], m[5]
			b.WriteString(text[last:start])
			rep := f.spoken
			if r, _ := utf8.DecodeRuneInString(text[start:end]); unicode.IsUpper(r) {
				rep = upperFirst(rep)
			}
			b.WriteString(rep)
			if f.endsSent && closesSentence(text[end:]) {
				b.WriteByte('.')
			}
			last = end
		}
		b.WriteString(text[last:])
		text = b.String()
	}
	return text
}

func upperFirst(s string) string {
	r, n := utf8.DecodeRuneInString(s)
	return string(unicode.ToUpper(r)) + s[n:]
}

// closesSentence reports whether rest (the text after an abbreviation's dot)
// is the end of the text or starts a new sentence.
func closesSentence(rest string) bool {
	rest = strings.TrimLeftFunc(rest, unicode.IsSpace)
	if rest == "" {
		return true
	}
	r, _ := utf8.DecodeRuneInString(rest)
	return unicode.IsUpper(r) || strings.ContainsRune("«\"—–(", r)
}
