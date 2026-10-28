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
var notNumerals = map[string]bool{
	"трио": true, "пята": true, "шест": true, "перва": true, "сота": true, "соты": true,
	// the heel "пята", the pole "шест" and the honeycomb "сота" in the cases
	// that are no form of пятый/шестой/сотый (those keep "пятой", "шестом",
	// "сотых" ...). Only clear non-numbers: the rest of the lexicon is
	// calibrated against the owner's blind labels once they exist (#146.2).
	"пяте": true, "пяту": true, "пяты": true, "пятам": true, "пятах": true, "пятами": true,
	"шеста": true, "шесту": true, "шесты": true, "шесте": true, "шестов": true, "шестам": true, "шестах": true, "шестами": true,
	"сотов": true, "сотам": true, "сотах": true, "сотами": true, "соте": true,
}

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

// englishNumerals is the English number-word lexicon a digit token may absorb:
// cardinals and ordinals 0-19, tens, hundred/thousand/million/billion/trillion,
// their plurals ("nineties", "hundreds") and the words a decimal or a negative
// number is read with. Hyphenated forms ("twenty-five") reach the aligner as
// separate words (Words splits on "-"), so each part is matched on its own, as
// "twenty twenty six" years are.
var englishNumerals = map[string]bool{}

func init() {
	for _, w := range strings.Fields(`zero one two three four five six seven eight nine ten eleven twelve
		thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy
		eighty ninety hundred thousand million billion trillion
		first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth
		fifteenth sixteenth seventeenth eighteenth nineteenth twentieth thirtieth fortieth fiftieth sixtieth
		seventieth eightieth ninetieth hundredth thousandth millionth billionth
		twenties thirties forties fifties sixties seventies eighties nineties hundreds thousands millions billions
		point minus plus`) {
		englishNumerals[w] = true
	}
}

// fillerAnd is free inside a number only between two numeral words ("две тысячи и один").
var fillerAnds = map[string]bool{"и": true, "and": true}

// signUnits maps a sign written with a number to the stem of the unit word
// that is spoken for it ("40%" = "сорок процентов").
var signUnits = map[rune][]string{
	'%': {"процент", "percent"}, '₽': {"руб", "ruble", "rouble"}, '°': {"градус", "degree"},
	'$': {"доллар", "dollar"}, '€': {"евро", "euro"},
}

func hasDigit(w string) bool {
	return strings.IndexFunc(w, isDigit) >= 0
}

// isNumeral reports whether w is a spoken number word (or itself digits).
func isNumeral(w string) bool {
	if notNumerals[w] {
		return false
	}
	if hasDigit(w) || numeralWords[w] || englishNumerals[w] {
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
		units = append(units, signUnits[r]...)
	}
	cost, unitUsed := 0, false
	for i, w := range words {
		switch {
		case isNumeral(w):
		case fillerAnds[w] && i > 0 && i < len(words)-1 && isNumeral(words[i-1]) && isNumeral(words[i+1]):
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
