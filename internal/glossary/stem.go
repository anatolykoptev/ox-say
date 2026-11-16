package glossary

import (
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/kljensen/snowball/russian"
)

// minStemRunes is the shortest stem that may stand for a word. A short stem is shared by unrelated words («вол» is
// also «воля», «пол» is also «поле»): on the lower-case, flagged entries of the Russian dictionary in
// internal/wordlists, 4.2% of the entries matched by stem share it with another entry at a 3-letter minimum, 3.5%
// at 4 and 2.9% at 5 (TestStemMatchingIsRareOnOrdinaryWords). A heard form whose stem is shorter than this
// matches only itself.
const minStemRunes = 5

// nounEndings are the case endings of a noun, and nothing else: matching goes through the Snowball stemmer, but
// a word whose stemmed-off tail is not one of these is a derivation or a verb form («курс» / «курсив»,
// «охрана» / «охранить»), not another case of the same name, and is not matched.
var nounEndings = map[string]bool{"": true}

func init() {
	for _, e := range strings.Fields("а я у ю е ы и ом ем ой ей ою ею ам ям ами ями ах ях ов ев") {
		nounEndings[e] = true
	}
}

// nominalStem is the Snowball stem of a folded Cyrillic word when the word may be matched by stem: the stem is
// at least minStemRunes long and the word is that stem plus a noun case ending or nothing. Otherwise "".
// Snowball only strips suffixes, so the stem is a prefix of the word; a word it rewrites («нн» → «н») is exact-only.
func nominalStem(w string) string {
	for _, r := range w {
		if !unicode.Is(unicode.Cyrillic, r) {
			return ""
		}
	}
	st := russian.Stem(w, false)
	if utf8.RuneCountInString(st) < minStemRunes || !strings.HasPrefix(w, st) || !nounEndings[w[len(st):]] {
		return ""
	}
	return st
}

// sameWord reports whether the folded text word w is the heard word h, or another case of it: its stem equals
// the heard word's stem hs (nominalStem(h), "" when h matches only itself).
func sameWord(h, hs, w string) bool {
	if w == h {
		return true
	}
	return hs != "" && strings.HasPrefix(w, hs) && nominalStem(w) == hs
}

// hasCyrillic reports whether s holds a Cyrillic letter.
func hasCyrillic(s string) bool {
	for _, r := range s {
		if unicode.Is(unicode.Cyrillic, r) {
			return true
		}
	}
	return false
}
