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
	scriptGreek    = "greek"

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

// Script returns "latin", "cyrillic" or "greek" for a text written
// predominantly in that script, "" for anything else (CJK, Arabic, digits
// only, empty). The three are the scripts of parakeet-tdt-0.6b-v3's 25
// languages (model card, huggingface.co/nvidia/parakeet-tdt-0.6b-v3):
// bg hr cs da nl en et fi fr de el hu it lv lt mt pl pt ro sk sl es sv ru uk —
// Latin for all but bg/el/ru/uk, Cyrillic for bg/ru/uk, Greek for el. Latin
// letters of a language the model does not list (Turkish, Vietnamese) are not
// told apart: the script-mismatch and match checks cover those.
func Script(text string) string {
	var latin, cyr, greek, letters int
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
		case unicode.Is(unicode.Greek, r):
			greek++
		}
	}
	top, name := latin, scriptLatin
	if cyr > top {
		top, name = cyr, scriptCyrillic
	}
	if greek > top {
		top, name = greek, scriptGreek
	}
	if letters == 0 || float64(top) < scriptShare*float64(letters) {
		return ""
	}
	return name
}

// SameScript reports whether both texts are in the same transcribable script.
func SameScript(a, b string) bool {
	sa := Script(a)
	return sa != "" && sa == Script(b)
}

// WordOverlap is the share of words a and b have in common, over the longer
// of the two texts (0..1). Case and punctuation are ignored; 0 when both are
// empty.
func WordOverlap(a, b string) float64 {
	wa, wb := normWords(a), normWords(b)
	longer := max(len(wa), len(wb))
	if longer == 0 {
		return 0
	}
	return float64(commonWords(wa, wb)) / float64(longer)
}

// WordShare is the share of a's words that b also has (0..1): how much of a
// is contained in b, however much longer b is. 0 when a has no words.
func WordShare(a, b string) float64 {
	wa := normWords(a)
	if len(wa) == 0 {
		return 0
	}
	return float64(commonWords(wa, normWords(b))) / float64(len(wa))
}

// TextsMatch reports whether a and b are, word for word, nearly the same
// text: WordOverlap is at least matchThreshold.
func TextsMatch(a, b string) bool {
	return WordOverlap(a, b) >= matchThreshold
}

func commonWords(wa, wb []string) int {
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
	return common
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
