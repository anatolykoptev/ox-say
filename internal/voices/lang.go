package voices

import (
	"slices"
	"strings"
	"unicode"
)

// Language names the language of a text by its own letters and function
// words, on the device and without a model: "en", "de", "fr", "es", "it",
// "pt", "nl", "pl" (and a few neighbours, see functionWords), "ru", "uk", or
// "" when the text does not say clearly — too short, mixed, another script, or
// a language the detector has no row for. "" is a safe answer: callers fall
// back to "the language of the transcript" instead of forcing a wrong one.
//
// It reads speech-to-text output, which is spelled with the language's own
// letters (parakeet-tdt-0.6b-v3 writes Cyrillic for bg/ru/uk, Latin for most
// of the rest), so no phonetic guesswork is needed.
func Language(text string) string {
	switch Script(text) {
	case scriptCyrillic:
		return cyrillicLanguage(text)
	case scriptLatin:
		return latinLanguage(text)
	}
	return ""
}

const (
	// minCyrillicLetters: below this a script-only guess is a coin flip.
	minCyrillicLetters = 12
	// letterDominance: the letters of one language must outnumber the other's
	// by this factor, so one quoted Ukrainian name in Russian speech does not
	// flip the call, while Belarusian (both sets, often) stays unclaimed.
	letterDominance = 2

	// minLatinWords is the fewest words a Latin text needs to be classified.
	minLatinWords = 6
	// minFunctionShare: the winning language's function words must make up at
	// least this share of the words. Running text in a listed language is
	// about 30-45%; a language with no row here (Finnish, Hungarian...) shares
	// only a few accidental words.
	minFunctionShare = 0.2
	// winnerRatio and winnerMargin: the winner must beat the runner-up both
	// relatively and absolutely, so a text that fits two languages (or fits
	// one that only a neighbour's row covers) stays unclaimed.
	winnerRatio  = 1.4
	winnerMargin = 0.05
)

// Ukrainian-only letters (і ї є ґ) and letters Ukrainian does not use but
// Russian does (ы э ё). ъ is left out on purpose: Bulgarian writes it in
// nearly every sentence.
const (
	ukrainianLetters = "іїєґІЇЄҐ"
	russianLetters   = "ыэёЫЭЁ"
)

func cyrillicLanguage(text string) string {
	var uk, ru, letters int
	for _, r := range text {
		if !unicode.IsLetter(r) {
			continue
		}
		letters++
		switch {
		case strings.ContainsRune(ukrainianLetters, r):
			uk++
		case strings.ContainsRune(russianLetters, r):
			ru++
		}
	}
	switch {
	case letters < minCyrillicLetters:
		return ""
	case uk > 0 && uk >= letterDominance*ru:
		return "uk"
	case ru > 0 && ru >= letterDominance*uk:
		return "ru"
	}
	return "" // Bulgarian, Serbian, Belarusian, or Russian written without ы э ё
}

func latinLanguage(text string) string {
	// Split on every non-letter, apostrophes included, so l'homme gives "l"
	// and "homme" and don't gives "don" and "t".
	words := strings.FieldsFunc(strings.ToLower(text), func(r rune) bool { return !unicode.IsLetter(r) })
	if len(words) < minLatinWords {
		return ""
	}
	best, second, bestLang := 0.0, 0.0, ""
	for lang, set := range functionWords {
		hits := 0
		for _, w := range words {
			if set[w] {
				hits++
			}
		}
		share := float64(hits) / float64(len(words))
		switch {
		case share > best:
			best, second, bestLang = share, best, lang
		case share > second:
			second = share
		}
	}
	if best < minFunctionShare || best < winnerRatio*second || best-second < winnerMargin {
		return ""
	}
	return bestLang
}

// functionWords are the most frequent function words of each Latin-script
// language: articles, pronouns, prepositions, conjunctions and auxiliaries.
// A word shared by several languages counts for each of them. Besides the
// languages the notes name (en de fr es it pt nl pl) there are rows for
// neighbours (sv da cs ro) that would otherwise be read as their closest
// relative: a Czech text scored against Polish alone wins with Polish.
var functionWords = map[string]map[string]bool{
	"en": wordSet("the and to of in that is it you for with this we on are have was but not be they so what can will there just i as at my your about a"),
	"de": wordSet("der die das und ist nicht ich ein eine zu den mit von auf für es sich auch dass wir sie aber im dem wie nach bei noch nur wenn oder haben wird sind ja mal schon"),
	"fr": wordSet("le la les des du de un une et est que qui pas pour dans ce il elle nous vous je ne sur avec au aux en ça c l d qu j mais sont plus être"),
	"es": wordSet("el la los las un una y es que de en no por con para se su lo al del como más pero muy también esto eso yo nos está son ya hay si le a"),
	"it": wordSet("il lo la gli le un una di che è e non per con sono del della dei ho ha ma anche come più questo quello mi ci si da al nel alla cosa perché a"),
	"pt": wordSet("o a os as um uma de que e é não para com em do da dos das no na se por mais como mas foi ele ela você já muito isso está são também ao pelo"),
	"nl": wordSet("de het een en van is dat niet ik je we zijn op te met voor ook maar er aan dit naar om als wat bij dan nog wel heb hebben wordt kan ze jij hij"),
	"pl": wordSet("i w na nie to się że z do jest jak ale co po tak czy od za już dla tylko będzie ten tego mnie jestem bardzo też są ze o mi jeśli może"),
	"sv": wordSet("och det att i en som är på för med inte jag har till den av om ett vi kan men så de"),
	"da": wordSet("og det at en til er på ikke jeg med for har af som den vi kan men så de et"),
	"cs": wordSet("a je se na to že v s z do ale jak co ne tak jsem pro by už být má jsou"),
	"ro": wordSet("și în de la cu nu să un o este pe că sunt mai din pentru care ce dar fi am ai le"),
}

// Languages lists every code Language can return, sorted.
func Languages() []string {
	out := []string{"ru", "uk"}
	for lang := range functionWords {
		out = append(out, lang)
	}
	slices.Sort(out)
	return out
}

func wordSet(s string) map[string]bool {
	out := map[string]bool{}
	for _, w := range strings.Fields(s) {
		out[w] = true
	}
	return out
}
