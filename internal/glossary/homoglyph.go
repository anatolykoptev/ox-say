package glossary

import (
	"strings"
	"unicode"
)

// cyrToLat transliterates Cyrillic letters to their Latin sounds (а→a, с→s, р→r, н→n). Parakeet
// picks an alphabet per utterance and, inside Russian speech, may write single sounds of a Latin
// identifier in Cyrillic («Startс» for "Starts"). Folding those letters back to their sounds
// recovers the intended Latin spelling — a lookalike map would not, since с is a lookalike of c
// but was written for the 's' sound. Letters without a one-to-one Latin sound keep a digraph
// (ш→sh); the soft signs vanish. The map is consulted only while matching a code-pack pair and
// only on a token that already mixes the two scripts — never on a pure-Cyrillic or a pure-Latin
// word, so it can neither invent nor destroy a real word of either language.
var cyrToLat = map[rune]string{
	'а': "a", 'б': "b", 'в': "v", 'г': "g", 'д': "d", 'е': "e", 'ж': "zh", 'з': "z",
	'и': "i", 'й': "y", 'к': "k", 'л': "l", 'м': "m", 'н': "n", 'о': "o", 'п': "p",
	'р': "r", 'с': "s", 'т': "t", 'у': "u", 'ф': "f", 'х': "h", 'ц': "ts", 'ч': "ch",
	'ш': "sh", 'щ': "shch", 'ъ': "", 'ы': "y", 'ь': "", 'э': "e", 'ю': "yu", 'я': "ya",
	'і': "i", 'ї': "yi", 'є': "ye", 'ґ': "g", 'ѕ': "z", 'ј': "y", 'ԁ': "d", 'ԍ': "g",
	'һ': "h",
}

// mixedScript reports whether s holds both Cyrillic and Latin letters. The check runs on folded
// text, so the transliteration map needs only the lowercase forms.
func mixedScript(s string) bool {
	var cyr, lat bool
	for _, r := range s {
		switch {
		case unicode.Is(unicode.Cyrillic, r):
			cyr = true
		case unicode.Is(unicode.Latin, r):
			lat = true
		}
	}
	return cyr && lat
}

// latinized is s with each Cyrillic letter replaced by its Latin sound; Latin letters and other
// runes pass through.
func latinized(s string) string {
	var b strings.Builder
	for _, r := range s {
		if l, ok := cyrToLat[r]; ok {
			b.WriteString(l)
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}
