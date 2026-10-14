package voices

import (
	"errors"
	"strings"
	"unicode"
)

// ErrScript marks a ref_text the speech-to-text cannot reproduce. Parakeet
// reads only Latin- and Cyrillic-script languages; given Chinese, Arabic or
// Hebrew speech it emits a transliteration ("Tintian Tianxi Heng Hao…"), so
// replacing such a ref_text with the transcript would swap the user's text
// for nonsense.
var ErrScript = errors.New("voices: ref_text is not in a script the speech-to-text can transcribe")

const (
	scriptLatin    = "latin"
	scriptCyrillic = "cyrillic"

	// scriptShare is the share of a text's letters that must be Latin or
	// Cyrillic for the text to count as one of them; a sentence with a few
	// foreign words still does.
	scriptShare = 0.8

	// matchThreshold is the word-level similarity at which a ref_text is taken
	// to be the transcript of its clip. ASR word error on clean read speech is
	// 5-15% and the user's text keeps punctuation, fillers and spellings the
	// STT drops, so 0.8 tolerates up to ~20% disagreement. A transcript that
	// runs past the audio is far off: 64 words over a 20 s clip whose audio
	// holds ~45 matches at <= 0.7, 90 over ~45 at 0.5.
	matchThreshold = 0.8
)

// Script returns "latin" or "cyrillic" for a text written predominantly in
// that script, "" for anything else (CJK, Arabic, digits only, empty).
func Script(text string) string {
	var latin, cyr, letters int
	for _, r := range text {
		if !unicode.IsLetter(r) {
			continue
		}
		letters++
		switch {
		case unicode.Is(unicode.Latin, r):
			latin++
		case unicode.Is(unicode.Cyrillic, r):
			cyr++
		}
	}
	if letters == 0 || float64(latin+cyr) < scriptShare*float64(letters) {
		return ""
	}
	if cyr > latin {
		return scriptCyrillic
	}
	return scriptLatin
}

// SameScript reports whether both texts are in the same transcribable script.
func SameScript(a, b string) bool {
	sa := Script(a)
	return sa != "" && sa == Script(b)
}

// TextsMatch reports whether a and b are, word for word, nearly the same
// text: the share of words they have in common, over the longer text, is at
// least matchThreshold. Case and punctuation are ignored.
func TextsMatch(a, b string) bool {
	wa, wb := normWords(a), normWords(b)
	longer := max(len(wa), len(wb))
	if longer == 0 {
		return false
	}
	bag := map[string]int{}
	for _, w := range wb {
		bag[w]++
	}
	common := 0
	for _, w := range wa {
		if bag[w] > 0 {
			bag[w]--
			common++
		}
	}
	return float64(common)/float64(longer) >= matchThreshold
}

func normWords(text string) []string {
	fields := strings.FieldsFunc(strings.ToLower(text), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '\''
	})
	out := fields[:0]
	for _, f := range fields {
		if f = strings.Trim(f, "'"); f != "" {
			out = append(out, f)
		}
	}
	return out
}
