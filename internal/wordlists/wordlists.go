// Package wordlists answers one question: is this an ordinary word of the language it is written in? The boost
// list sent to the decoder must contain neither a spoken form such as «кролик» nor a written form such as
// "Pillow" that is an ordinary word: the decoder is pushed towards it and starts inserting it into sentences
// that never said it (the spike measured 7-18 false insertions per 100 Russian sentences for each such word,
// and the English eval 2 of 60 for "pillow" and "GitHub"). The check is a spell-check against the Hunspell
// dictionary of the form's script — Russian for Cyrillic, English for Latin — which expands every word's
// inflections from its affix rules instead of listing them.
//
// Data (data/README.md has the pins): ru.aff + ru.dic.gz are Alexander I. Lebedev's Russian dictionary
// (BSD-3-Clause style, data/LICENSE.ru); en.aff + en.dic.gz are the SCOWL-derived en_US dictionary of Kevin
// Atkinson (MIT/BSD-style, data/LICENSE.en), both as packaged by github.com/wooorm/dictionaries. The engine is
// github.com/client9/gospell (MIT, pure Go, lazy affix expansion).
package wordlists

import (
	"bytes"
	"compress/gzip"
	_ "embed"
	"strings"
	"unicode"

	"github.com/client9/gospell"
)

//go:embed data/ru.aff
var ruAff []byte

//go:embed data/ru.dic.gz
var ruDicGz []byte

//go:embed data/en.aff
var enAff []byte

//go:embed data/en.dic.gz
var enDicGz []byte

// Checker holds the dictionaries parsed so far (the Russian one is ~100 MB of heap while alive: build a Checker
// for a rebuild of the boost list and drop it, never keep it for the life of the daemon). Each language loads on
// its first use.
type Checker struct {
	ru, en *gospell.GoSpell
	err    error
}

// New returns a Checker that loads dictionaries lazily.
func New() *Checker { return &Checker{} }

// Err is the first dictionary load failure, if any; Common answers false for that language after it.
func (c *Checker) Err() error { return c.err }

func load(aff, dicGz []byte) (*gospell.GoSpell, error) {
	zr, err := gzip.NewReader(bytes.NewReader(dicGz))
	if err != nil {
		return nil, err
	}
	defer func() { _ = zr.Close() }()
	return gospell.NewGoSpellReader(bytes.NewReader(aff), zr)
}

// Common reports whether every word of s (split on spaces) is an ordinary word, in any inflection and either
// case. A multi-word form counts only when all of its words do: «окс сей» is not, "Hugging Face" is. The script
// picks the language: Cyrillic letters -> Russian, Latin letters -> English; a form of mixed scripts, with a digit
// or with no letter is never ordinary. Names are words too: the dictionaries list «Клод» and "Claude" with a
// capital, and a lower-case form is checked against both spellings.
func (c *Checker) Common(s string) bool {
	ws := strings.Fields(s)
	if len(ws) == 0 {
		return false
	}
	for _, w := range ws {
		if !c.word(w) {
			return false
		}
	}
	return true
}

func (c *Checker) word(w string) bool {
	w = strings.Trim(strings.ToLower(w), "-'’")
	if w == "" {
		return false
	}
	var cyr, lat bool
	for _, r := range w {
		switch {
		case unicode.Is(unicode.Cyrillic, r):
			cyr = true
		case unicode.Is(unicode.Latin, r):
			lat = true
		case r == '-' || r == '\'' || r == '’':
		default: // digits, dots, other symbols: a term, not a word
			return false
		}
	}
	switch {
	case cyr && !lat:
		if c.ru == nil && c.err == nil {
			if c.ru, c.err = load(ruAff, ruDicGz); c.err != nil {
				return false
			}
		}
		if c.ru == nil {
			return false
		}
		// ё and е are one letter to the decoder; and a transliteration doubles consonants the word does not
		// («соннет» for «сонет»), which the decoder writes back the way it hears it — so a form that is a word
		// once its doubled letters are single is the word.
		ye := strings.ReplaceAll(w, "ё", "е")
		for _, f := range []string{w, ye, undouble(ye)} {
			if c.ru.Spell(f) || c.ru.Spell(title(f)) {
				return true
			}
		}
	case lat && !cyr:
		if c.en == nil && c.err == nil {
			if c.en, c.err = load(enAff, enDicGz); c.err != nil {
				return false
			}
		}
		if c.en == nil {
			return false
		}
		return c.en.Spell(w) || c.en.Spell(title(w))
	}
	return false
}

// undouble collapses every run of one repeated letter to a single letter.
func undouble(w string) string {
	var b strings.Builder
	var prev rune
	for _, r := range w {
		if r != prev {
			b.WriteRune(r)
		}
		prev = r
	}
	return b.String()
}

func title(w string) string {
	r := []rune(w)
	r[0] = unicode.ToUpper(r[0])
	return string(r)
}
