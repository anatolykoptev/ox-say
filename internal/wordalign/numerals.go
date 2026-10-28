package wordalign

import "strings"

// numeralStems is the Russian numeral lexicon a digit token may absorb: stems of
// cardinals and ordinals 0-19, tens, hundreds, thousand/million/billion and the
// fraction words, each used with any ending in numeralEndings.
var numeralStems = []string{
	"нул", "нол", "один", "одн", "перв", "два", "две", "дву", "двух", "втор", "три", "трех", "трем", "тремя", "трет",
	"четыр", "четвер", "пят", "шест", "седьм", "восем", "восьм", "девят", "десят",
	"одиннадцат", "двенадцат", "тринадцат", "четырнадцат", "пятнадцат", "шестнадцат", "семнадцат", "восемнадцат", "девятнадцат",
	"двадцат", "тридцат", "сорок", "пятьдесят", "пятидесят", "шестьдесят", "шестидесят", "семьдесят", "семидесят",
	"восемьдесят", "восьмидесят", "девяност", "сот", "двест", "двухсот", "триста", "трехсот", "четыреста", "четырехсот",
	"пятьсот", "пятисот", "шестьсот", "шестисот", "семьсот", "семисот", "восемьсот", "восьмисот", "девятьсот", "девятисот",
	"тысяч", "миллион", "миллиард", "триллион", "половин",
	// ordinals the long-form number speller writes (vscript.ExpandNumbers):
	// "четвёртый" (ё folds to е), "сороковой", "нулевой" and the one-word
	// thousands ordinals "двухтысячный" …
	"четверт", "сороков", "нулев", "двухтысяч", "трехтысяч", "четырехтысяч", "пятитысяч", "шеститысяч",
	"семитысяч", "восьмитысяч", "девятитысяч",
}

// numeralWords are the short or irregular numeral-lexicon forms matched whole.
var numeralWords = map[string]bool{
	"семь": true, "семи": true, "семью": true, "сто": true, "ста": true, "ноль": true, "минус": true, "плюс": true, "запятая": true, "запятых": true,
	"целых": true, "целая": true, "целое": true, "целой": true, "целую": true, "полтора": true, "полторы": true,
	"четверть": true, "четверти": true,
}

// notNumerals are stem+ending products that no number is ever spoken as but
// that would fill a number slot for free ("трио", the heel "пята", the pole
// "шест", "перва", "сота").
var notNumerals = map[string]bool{"трио": true, "пята": true, "шест": true, "перва": true, "сота": true, "соты": true}

// numeralEndings are the case, gender and number endings numeralStems take.
var numeralEndings = map[string]bool{
	"": true, "а": true, "у": true, "и": true, "ы": true, "е": true, "о": true, "ь": true, "я": true, "ю": true,
	"ей": true, "ам": true, "ах": true, "ами": true, "ов": true, "ом": true, "ой": true, "ою": true, "ью": true,
	"ям": true, "ях": true, "ями": true, "ым": true, "ыми": true, "ых": true, "ого": true, "ому": true, "ий": true,
	"ый": true, "ая": true, "ое": true, "ые": true, "ие": true, "их": true, "ими": true, "ем": true, "ею": true,
	"ьми": true, "ной": true, "ная": true, "ное": true, "ные": true, "ный": true, "ных": true, "ного": true,
	"ному": true, "ьего": true, "ьему": true, "ьем": true, "ьим": true, "ьей": true, "ья": true, "ье": true, "ьи": true, "ным": true, "ными": true, "ную": true, "ти": true,
	// accusative feminine, soft plural and prepositional forms the speller writes (vscript.ExpandNumbers)
	"ую": true, "ьих": true, "ьими": true, "ном": true,
}

// fillerAnd is free inside a number only between two numeral words ("две тысячи и один").
const fillerAnd = "и"

// signUnits maps a sign written with a number to the stem of the unit word
// that is spoken for it ("40%" = "сорок процентов").
var signUnits = map[rune]string{'%': "процент", '₽': "руб", '°': "градус", '$': "доллар", '€': "евро"}

func hasDigit(w string) bool {
	return strings.IndexFunc(w, isDigit) >= 0
}

// isNumeral reports whether w is a spoken number word (or itself digits).
func isNumeral(w string) bool {
	if notNumerals[w] {
		return false
	}
	if hasDigit(w) || numeralWords[w] {
		return true
	}
	for _, st := range numeralStems {
		if strings.HasPrefix(w, st) && numeralEndings[w[len(st):]] {
			return true
		}
	}
	return false
}

// spanCost is the errors of letting digit token tok stand for words: a word
// that is not a numeral costs 1, except one unit word for a sign tok carries.
func spanCost(tok string, words []string) int {
	var units []string
	for _, r := range tok {
		if u, ok := signUnits[r]; ok {
			units = append(units, u)
		}
	}
	cost, unitUsed := 0, false
	for i, w := range words {
		switch {
		case isNumeral(w):
		case w == fillerAnd && i > 0 && i < len(words)-1 && isNumeral(words[i-1]) && isNumeral(words[i+1]):
		case !unitUsed && startsWithAny(w, units):
			unitUsed = true
		default:
			cost++
		}
	}
	return cost
}

func startsWithAny(w string, stems []string) bool {
	for _, st := range stems {
		if strings.HasPrefix(w, st) {
			return true
		}
	}
	return false
}
