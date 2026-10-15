package vscript

import "strings"

// The spoken forms of Russian numbers: cardinals up to 999 999 999 and
// ordinals up to 999 999. Pure functions; numerals_scan.go decides which
// digits in a text become which form.

type gender int

const (
	masculine gender = iota
	feminine
	neuter
)

const (
	thousand = 1000
	million  = 1000000
	hundred  = 100
	ten      = 10
	teenEnd  = 20 // 10..19 are single words
	// maxCardinal is the largest number ExpandNumbers speaks.
	maxCardinal = 999999999
	// maxOrdinal is the largest ordinal ordinalParts builds.
	maxOrdinal = 999999
	// maxThousandsPrefix is the largest k for which "k thousand" has a
	// one-word ordinal ("пятитысячный"); beyond it the digits stay.
	maxThousandsPrefix = 9
)

var (
	unitsM = []string{"", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"}
	unitsF = []string{"", "одна", "две", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"}
	unitsN = []string{"", "одно", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"}
	teens  = []string{"десять", "одиннадцать", "двенадцать", "тринадцать", "четырнадцать", "пятнадцать", "шестнадцать", "семнадцать", "восемнадцать", "девятнадцать"}
	tens   = []string{"", "", "двадцать", "тридцать", "сорок", "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят", "девяносто"}
	hunds  = []string{"", "сто", "двести", "триста", "четыреста", "пятьсот", "шестьсот", "семьсот", "восемьсот", "девятьсот"}
)

func units(g gender) []string {
	switch g {
	case feminine:
		return unitsF
	case neuter:
		return unitsN
	}
	return unitsM
}

// triple spells 0..999 (nothing for 0) with the gender of its last unit.
func triple(n int, g gender) []string {
	var out []string
	if h := n / hundred; h > 0 {
		out = append(out, hunds[h])
	}
	switch t := n % hundred; {
	case t >= ten && t < teenEnd:
		out = append(out, teens[t-ten])
	default:
		if d := t / ten; d > 0 {
			out = append(out, tens[d])
		}
		if u := t % ten; u > 0 {
			out = append(out, units(g)[u])
		}
	}
	return out
}

// plural picks the noun form for n: 1 → one, 2..4 → few, else many (11..14 many).
func plural(n int, one, few, many string) string {
	switch {
	case n%hundred >= 11 && n%hundred <= 14:
		return many
	case n%ten == 1:
		return one
	case n%ten >= 2 && n%ten <= 4:
		return few
	}
	return many
}

// cardinalWords spells 0..999 999 999 in the nominative; g is the gender of the
// last group. "тысяча" is feminine, "миллион" masculine; a leading "один
// миллион" / "одна тысяча" is just "миллион" / "тысяча".
func cardinalWords(n int, g gender) []string {
	if n == 0 {
		return []string{"ноль"}
	}
	var out []string
	if m := n / million; m > 0 {
		out = append(out, groupWords(m, masculine, "миллион", "миллиона", "миллионов", len(out) == 0)...)
	}
	if th := n / thousand % thousand; th > 0 {
		out = append(out, groupWords(th, feminine, "тысяча", "тысячи", "тысяч", len(out) == 0)...)
	}
	return append(out, triple(n%thousand, g)...)
}

func groupWords(n int, g gender, one, few, many string, leading bool) []string {
	var out []string
	if !leading || n != 1 {
		out = triple(n, g)
	}
	return append(out, plural(n, one, few, many))
}

// endsInOneOrTwo reports whether the last word of the number depends on the
// gender of the counted noun (…1 or …2, not 11/12).
func endsInOneOrTwo(n int) bool {
	last := n % hundred
	return (last%ten == 1 || last%ten == 2) && last != 11 && last != 12
}

type ordKind int

const (
	ordHard     ordKind = iota // -ый: пятый
	ordStressed                // -ой: второй
	ordSoft                    // -ий: третий
)

type ordStem struct {
	stem string
	kind ordKind
}

var (
	ordUnits = []ordStem{{"нулев", ordStressed}, {"перв", ordHard}, {"втор", ordStressed}, {"трет", ordSoft}, {"четвёрт", ordHard},
		{"пят", ordHard}, {"шест", ordStressed}, {"седьм", ordStressed}, {"восьм", ordStressed}, {"девят", ordHard}}
	ordTeens = []string{"десят", "одиннадцат", "двенадцат", "тринадцат", "четырнадцат", "пятнадцат", "шестнадцат", "семнадцат", "восемнадцат", "девятнадцат"}
	ordTens  = []ordStem{{}, {}, {"двадцат", ordHard}, {"тридцат", ordHard}, {"сороков", ordStressed}, {"пятидесят", ordHard},
		{"шестидесят", ordHard}, {"семидесят", ordHard}, {"восьмидесят", ordHard}, {"девяност", ordHard}}
	ordHunds = []string{"", "сот", "двухсот", "трёхсот", "четырёхсот", "пятисот", "шестисот", "семисот", "восьмисот", "девятисот"}
	ordThous = []string{"", "тысячн", "двухтысячн", "трёхтысячн", "четырёхтысячн", "пятитысячн", "шеститысячн", "семитысячн", "восьмитысячн", "девятитысячн"}
)

// ordinalParts splits the ordinal of n into the cardinal words before it and
// its last word's stem: 2026 → "две тысячи двадцать" + "шест". Compound
// round ordinals (двухсотый, двухтысячный) are one stem. ok is false for an
// ordinal the tables do not cover (n beyond maxOrdinal, k·1000 with k > 9
// or not a plain thousands count).
func ordinalParts(n int) (prefix []string, last ordStem, ok bool) {
	if n < 0 || n > maxOrdinal {
		return nil, ordStem{}, false
	}
	var tail int // the part carried by the last word
	switch {
	case n%hundred >= 1 && n%hundred < teenEnd:
		tail = n % hundred
	case n%ten != 0:
		tail = n % ten
	case n%hundred != 0:
		tail = n % hundred
	case n%thousand != 0:
		tail = n % thousand
	default:
		return thousandsOrdinal(n)
	}
	if n > tail {
		prefix = cardinalWords(n-tail, masculine)
	}
	return prefix, ordStemFor(tail), true
}

func thousandsOrdinal(n int) ([]string, ordStem, bool) {
	if n == 0 {
		return nil, ordUnits[0], true
	}
	if k := n / thousand; k <= maxThousandsPrefix {
		return nil, ordStem{ordThous[k], ordHard}, true
	}
	return nil, ordStem{}, false
}

// ordStemFor is the stem of the ordinal of a tail value: 1..19, a ten
// (20..90) or a hundred (100..900).
func ordStemFor(tail int) ordStem {
	switch {
	case tail < ten:
		return ordUnits[tail]
	case tail < teenEnd:
		return ordStem{ordTeens[tail-ten], ordHard}
	case tail < hundred:
		return ordTens[tail/ten]
	}
	return ordStem{ordHunds[tail/hundred], ordHard}
}

type ordForm int

const (
	formNomM ordForm = iota
	formNomF
	formNomN
	formNomPl
	formAccF
	formGenMN
	formDatMN
	formInsMN
	formPrepMN
	formGenPl // also prepositional plural
	formInsPl
	formCount
)

var ordEndings = [3][formCount]string{
	ordHard:     {"ый", "ая", "ое", "ые", "ую", "ого", "ому", "ым", "ом", "ых", "ыми"},
	ordStressed: {"ой", "ая", "ое", "ые", "ую", "ого", "ому", "ым", "ом", "ых", "ыми"},
	ordSoft:     {"ий", "ья", "ье", "ьи", "ью", "ьего", "ьему", "ьим", "ьем", "ьих", "ьими"},
}

// ordinalWords is the ordinal of n in the given form, or ok false.
func ordinalWords(n int, f ordForm) (words []string, ok bool) {
	prefix, last, ok := ordinalParts(n)
	if !ok {
		return nil, false
	}
	return append(prefix, last.stem+ordEndings[last.kind][f]), true
}

func join(words []string) string { return strings.Join(words, " ") }
