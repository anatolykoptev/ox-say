package glossary

import (
	"strings"
	"unicode"
)

// cyrToLatin transliterates a Russian Cyrillic letter to its Latin sound. Parakeet picks an
// alphabet per utterance and, inside Russian speech, may write single sounds of a Latin
// identifier in Cyrillic («Quаrgs» for "Quargs", а for the 'a' sound — not for lookalike a,
// since a lookalike map would miss ё→e). Letters without a one-to-one Latin sound keep a digraph
// (ш→sh); the soft signs vanish. The map covers the Russian alphabet only: a letter outside it
// (і, є, ѕ) is not a plausible Parakeet slip and stays untransliterated.
var cyrToLatin = map[rune]string{
	'а': "a", 'б': "b", 'в': "v", 'г': "g", 'д': "d", 'е': "e", 'ё': "e", 'ж': "zh", 'з': "z",
	'и': "i", 'й': "y", 'к': "k", 'л': "l", 'м': "m", 'н': "n", 'о': "o", 'п': "p",
	'р': "r", 'с': "s", 'т': "t", 'у': "u", 'ф': "f", 'х': "h", 'ц': "ts", 'ч': "ch",
	'ш': "sh", 'щ': "shch", 'ъ': "", 'ы': "y", 'ь': "", 'э': "e", 'ю': "yu", 'я': "ya",
}

// foldable reports whether a folded text token may take the mixed-script fold: it holds both
// Latin and Cyrillic letters and the Latin ones are the majority. A mostly-Cyrillic word is
// Russian text — «rёплейс» is not the identifier "replace" — so its letters never fold; a
// pure-Latin or pure-Cyrillic word has nothing to fold from.
func foldable(s string) bool {
	var lat, cyr int
	for _, r := range s {
		switch {
		case unicode.Is(unicode.Cyrillic, r):
			cyr++
		case unicode.Is(unicode.Latin, r):
			lat++
		}
	}
	return cyr > 0 && lat > cyr
}

// Latinized is s with each Russian Cyrillic letter replaced by its Latin sound; every other rune
// passes through. Matching folds the text token only, never the filed alias: a pure-Latin alias
// may meet a folded token («Quаrgs» -> "quargs"), a Cyrillic or a mixed-script one may not.
func Latinized(s string) string {
	var b strings.Builder
	for _, r := range s {
		if l, ok := cyrToLatin[r]; ok {
			b.WriteString(l)
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}
