// Package ruwords answers one question: is this an ordinary Russian word? The boost list sent to the decoder
// must not contain a spoken form such as «кролик» or «дозор»: the decoder is pushed towards it and starts
// inserting it into sentences that never said it (the spike measured 7–18 false insertions per 100 sentences
// for each such word). The check is a spell-check against the Russian Hunspell dictionary, which expands
// every word's inflections («кролика», «кроликам», …) from its affix rules instead of listing them.
//
// Data: data/ru.aff and data/ru.dic.gz are the Russian dictionary of Alexander I. Lebedev as packaged by
// github.com/wooorm/dictionaries (dictionary-ru 3.0.0), BSD-3-Clause, see data/LICENSE and data/README.md.
// The engine is github.com/client9/gospell (MIT, pure Go, lazy affix expansion).
package ruwords

import (
	"bytes"
	"compress/gzip"
	_ "embed"
	"strings"
	"unicode"

	"github.com/client9/gospell"
)

//go:embed data/ru.aff
var aff []byte

//go:embed data/ru.dic.gz
var dicGz []byte

// Checker holds the parsed dictionary (tens of MB while alive: load it for a rebuild of the boost list and
// drop it, never keep it for the life of the daemon).
type Checker struct {
	gs *gospell.GoSpell
}

// Load parses the embedded dictionary.
func Load() (*Checker, error) {
	zr, err := gzip.NewReader(bytes.NewReader(dicGz))
	if err != nil {
		return nil, err
	}
	defer func() { _ = zr.Close() }()
	gs, err := gospell.NewGoSpellReader(bytes.NewReader(aff), zr)
	if err != nil {
		return nil, err
	}
	return &Checker{gs: gs}, nil
}

// Common reports whether every word of s (split on spaces) is an ordinary Russian word, in any inflection.
// A multi-word spoken form counts as ordinary only when all of its words are: «окс сей» is not.
// Names are words too: the dictionary lists «Клод» with a capital, and a lower-case «клод» from a
// transcript is checked against both spellings. A form with no Cyrillic letter is never "ordinary Russian".
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
	cyr := false
	for _, r := range w {
		if unicode.Is(unicode.Cyrillic, r) {
			cyr = true
		}
	}
	if !cyr {
		return false
	}
	// the dictionary spells ё as е in none of its entries; try both
	for _, f := range []string{w, strings.ReplaceAll(w, "ё", "е")} {
		if c.gs.Spell(f) || c.gs.Spell(title(f)) {
			return true
		}
	}
	return false
}

func title(w string) string {
	r := []rune(w)
	r[0] = unicode.ToUpper(r[0])
	return string(r)
}
