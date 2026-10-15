package vscript

import (
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// ExpandNumbers writes the numbers in text as Russian words, for the engine:
// VoxCPM2 misreads ordinals with a suffix ("2-й"), decimals ("2,5") and
// ranges ("10–15"). Covered: cardinals, percents, times "18:30", decimals,
// ordinals with a suffix, ranges, "в 1998 году", and "12 апреля".
//
// Case agreement after other prepositions ("с 5 друзьями"), Roman numerals and
// phone numbers are out of scope, and a wrong word is worse than digits: a
// number that the rules cannot place with certainty is left as written (a
// governing preposition other than в/на/за/через/про, a noun whose gender is
// unknown, an ambiguous suffix, a code like "ГОСТ 12345-2020").
func ExpandNumbers(text string) string {
	var b strings.Builder
	last := 0
	phones := phoneNumber.FindAllStringIndex(text, -1)
	for _, m := range numberToken.FindAllStringIndex(text, -1) {
		if m[0] < last || insideAny(phones, m[0]) {
			continue
		}
		repl, end, ok := expandToken(numCtx{text: text, start: m[0], end: m[1]})
		if !ok {
			continue
		}
		b.WriteString(text[last:m[0]])
		b.WriteString(repl)
		last = end
	}
	b.WriteString(text[last:])
	return b.String()
}

const (
	numPat = `(?:\d{1,3}(?:[ \x{00a0}\x{202f}]\d{3})+|\d+)`
	// ordSuffixes: longest first; "ой" is absent on purpose (masculine
	// nominative "2-ой" or a feminine oblique case: unknowable).
	ordSuffixes = `ого|ому|ыми|ых|ым|ую|ая|ое|ые|ый|ий|ом|го|му|ми|я|ю|е|й|м|х`
)

// numberToken matches, leftmost and in this order of preference: a time, a
// decimal, a range, an ordinal with a suffix, a plain number.
var numberToken = regexp.MustCompile(`\d{1,2}:\d{2}|` + numPat + `,\d+|` + numPat + `[–-]` + numPat + `|` +
	numPat + `-(?:` + ordSuffixes + `)|` + numPat)

// phoneNumber spans are never touched (out of scope): +7 (999) 123-45-67, 8 800 555 35 35.
var phoneNumber = regexp.MustCompile(`(?:\+\d|\b8)[\s\x{00a0}()\-]*\d{3}[\s\x{00a0}()\-]*\d{3}[\s\x{00a0}\-]*\d{2}[\s\x{00a0}\-]*\d{2}`)

func insideAny(spans [][]int, pos int) bool {
	for _, s := range spans {
		if pos >= s[0] && pos < s[1] {
			return true
		}
	}
	return false
}

type numCtx struct {
	text       string
	start, end int
}

func (c numCtx) token() string  { return c.text[c.start:c.end] }
func (c numCtx) before() string { return c.text[:c.start] }

func expandToken(c numCtx) (string, int, bool) {
	tok := c.token()
	if !boundaryOK(c.before(), c.text[c.end:]) {
		return "", 0, false
	}
	switch {
	case strings.Contains(tok, ":"):
		return expandTime(c)
	case strings.Contains(tok, ","):
		return expandDecimal(c)
	case isRange(tok):
		return expandRange(c)
	case isOrdinalToken(tok):
		return expandOrdinal(c)
	}
	return expandCardinal(c)
}

func isRange(tok string) bool {
	r, _ := utf8.DecodeLastRuneInString(tok)
	return unicode.IsDigit(r) && strings.ContainsAny(tok, "–-")
}

func isOrdinalToken(tok string) bool {
	r, _ := utf8.DecodeLastRuneInString(tok)
	return unicode.IsLetter(r)
}

// blockBefore are the characters that make a digit run part of something
// else when they touch it from the left: a word, a code, a sign, a version.
const blockBefore = `_/\.,:;-−+$€£₽№#@%&*=<>`

// blockAfter likewise on the right; a "." "," ":" "-" blocks only before a
// digit or letter (a sentence-final "5." is fine).
const blockAfter = `_/\°$€£₽²³@&*=<>`

// signsAfter: a unit or currency sign after a number ("300 ₽") — the number
// would be spoken without its unit, so the digits stay.
const signsAfter = "₽$€£°"

func boundaryOK(before, after string) bool {
	if r, _ := utf8.DecodeLastRuneInString(before); r != utf8.RuneError &&
		(unicode.IsLetter(r) || unicode.IsDigit(r) || strings.ContainsRune(blockBefore, r)) {
		return false
	}
	if t := strings.TrimRight(before, "   "); strings.HasSuffix(t, "№") || strings.HasSuffix(t, "#") {
		return false
	}
	if r, _ := utf8.DecodeRuneInString(strings.TrimLeft(after, " \u00a0\u202f")); strings.ContainsRune(signsAfter, r) {
		return false
	}
	r, size := utf8.DecodeRuneInString(after)
	switch {
	case size == 0:
		return true
	case unicode.IsLetter(r) || unicode.IsDigit(r) || strings.ContainsRune(blockAfter, r):
		return false
	case strings.ContainsRune(".,:-–", r):
		next, _ := utf8.DecodeRuneInString(after[size:])
		return !unicode.IsDigit(next) && (!unicode.IsLetter(next) || r != '-')
	}
	return true
}

// digitsOf is the integer value of a digit run with group separators, ok false
// for a leading zero or more than nine digits.
func digitsOf(s string) (int, bool) {
	d := strings.Map(func(r rune) rune {
		if unicode.IsDigit(r) {
			return r
		}
		return -1
	}, s)
	if d == "" || len(d) > len(strconv.Itoa(maxCardinal)) || (len(d) > 1 && d[0] == '0') {
		return 0, false
	}
	n, err := strconv.Atoi(d)
	return n, err == nil
}

// prevWord is the lower-cased word right before a token ("" when punctuation
// or the start comes first).
func prevWord(before string) string {
	t := strings.TrimRight(before, "   ")
	if len(t) == len(before) {
		return ""
	}
	i := strings.LastIndexFunc(t, func(r rune) bool { return !unicode.IsLetter(r) && r != '-' })
	if i >= 0 {
		_, size := utf8.DecodeRuneInString(t[i:])
		i += size
	} else {
		i = 0
	}
	return strings.ToLower(t[i:])
}

// nextWord is the lower-cased word right after a token, after plain spaces.
func nextWord(after string) string {
	t := strings.TrimLeft(after, "   ")
	if len(t) == len(after) {
		return ""
	}
	end := strings.IndexFunc(t, func(r rune) bool { return !unicode.IsLetter(r) })
	if end < 0 {
		end = len(t)
	}
	return strings.ToLower(t[:end])
}

// caseGovernors are the prepositions whose case is not the nominative/accusative
// the spoken numerals use ("с пятью", "до пяти"). Others ("в", "на", "за",
// "через", "про") take the accusative, which equals the nominative here.
var caseGovernors = setOf("с", "со", "к", "ко", "о", "об", "обо", "по", "при", "для", "до", "от", "из", "у", "без",
	"над", "под", "перед", "между", "около", "после", "вместо", "кроме", "среди", "против", "возле", "вокруг",
	"ради", "напротив", "из-за", "из-под", "внутри", "вдоль", "мимо", "сквозь", "благодаря", "согласно", "более", "менее", "свыше", "порядка")

func setOf(words ...string) map[string]bool {
	m := make(map[string]bool, len(words))
	for _, w := range words {
		m[w] = true
	}
	return m
}

func governed(c numCtx) bool { return caseGovernors[prevWord(c.before())] }

// expandCardinal handles a plain number: a percent, a day before a month,
// a year after "в", or a cardinal.
func expandCardinal(c numCtx) (string, int, bool) {
	n, ok := digitsOf(c.token())
	if !ok {
		return "", 0, false
	}
	after := c.text[c.end:]
	if r, ok := dateWords(c, n, after); ok {
		return r.text, r.end, true
	}
	if r, ok := yearWords(c, n, after); ok {
		return r.text, r.end, true
	}
	if governed(c) || isYearBlocked(n, nextWord(after)) {
		return "", 0, false
	}
	if sp, ok := percentSign(after); ok {
		return join(cardinalWords(n, masculine)) + " " + percentWord(n), c.end + sp, true
	}
	g, ok := nounGender(nextWord(after), n)
	if !ok {
		return "", 0, false
	}
	return join(cardinalWords(n, g)), c.end, true
}

type replacement struct {
	text string
	end  int
}

// yearForms are the words after a year-sized number that make it a year
// (read in some case the numerals here cannot take): the digits stay.
var yearForms = setOf("год", "года", "году", "годом", "годе", "г", "гг", "годы", "годов", "годам", "годах")

const minYear = 1000

func isYearBlocked(n int, next string) bool { return n >= minYear && yearForms[next] }

var (
	yearTail   = regexp.MustCompile(`^[ \x{00a0}]+(году|г\.)`)
	percentTil = regexp.MustCompile(`^[ \x{00a0}\x{202f}]*%`)
)

func percentSign(after string) (int, bool) {
	m := percentTil.FindString(after)
	return len(m), m != ""
}

const maxYear = 2999

// yearWords: «в 1998 году» / «в 1998 г.» → the prepositional ordinal.
func yearWords(c numCtx, n int, after string) (replacement, bool) {
	m := yearTail.FindStringSubmatch(after)
	if m == nil || prevWord(c.before()) != "в" || n < hundred || n > maxYear {
		return replacement{}, false
	}
	w, ok := ordinalWords(n, formPrepMN)
	if !ok {
		return replacement{}, false
	}
	end := c.end + len(m[0])
	out := join(w) + " году"
	if m[1] == "г." && closesSentence(c.text[end:]) {
		out += "."
	}
	return replacement{out, end}, true
}

var months = setOf("января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря")

const maxDay = 31

// dateNominative are the words after which a date is a nominative ("Сегодня
// двенадцатое апреля"); к takes the dative, на/по the accusative (= neuter
// nominative); otherwise the day is genitive ("двенадцатого апреля").
var (
	dateNominative = setOf("сегодня", "завтра", "вчера", "послезавтра", "на", "по")
	dateDative     = setOf("к", "ко")
)

func dateWords(c numCtx, n int, after string) (replacement, bool) {
	if n < 1 || n > maxDay || !months[nextWord(after)] {
		return replacement{}, false
	}
	form := formGenMN
	switch p := prevWord(c.before()); {
	case dateNominative[p]:
		form = formNomN
	case dateDative[p]:
		form = formDatMN
	}
	w, ok := ordinalWords(n, form)
	return replacement{join(w), c.end}, ok
}

// percentWord agrees "процент" with the number n.
func percentWord(n int) string {
	return plural(n, "процент", "процента", "процентов")
}

// nounGender is the gender for a number ending in 1 or 2: from the noun after
// it; ok false when the noun is unknown. Other numbers need no gender.
func nounGender(noun string, ns ...int) (gender, bool) {
	for _, n := range ns {
		if endsInOneOrTwo(n) {
			g, ok := nounGenders[noun]
			return g, ok
		}
	}
	return masculine, true
}

func expandOrdinal(c numCtx) (string, int, bool) {
	num, suffix, _ := strings.Cut(c.token(), "-")
	n, ok := digitsOf(num)
	if !ok {
		return "", 0, false
	}
	form, ok := suffixForms[suffix]
	if suffix == "м" {
		form, ok = formPrepMN, prepForPrep[prevWord(c.before())]
	}
	if !ok {
		return "", 0, false
	}
	w, ok := ordinalWords(n, form)
	if !ok {
		return "", 0, false
	}
	return join(w), c.end, true
}

var suffixForms = map[string]ordForm{
	"й": formNomM, "ый": formNomM, "ий": formNomM, "я": formNomF, "ая": formNomF, "е": formNomN, "ое": formNomN,
	"ые": formNomPl, "ю": formAccF, "ую": formAccF, "го": formGenMN, "ого": formGenMN, "му": formDatMN, "ому": formDatMN,
	"ым": formInsMN, "ом": formPrepMN, "х": formGenPl, "ых": formGenPl, "ми": formInsPl, "ыми": formInsPl,
}

// prepForPrep: "-м" is prepositional only after these ("в 21-м веке"); it is
// instrumental or dative elsewhere ("2-м этапом" / "к 2-му"), which the suffix
// alone does not tell.
var prepForPrep = setOf("в", "во", "на", "о", "об", "при")

func expandRange(c numCtx) (string, int, bool) {
	lo, hi, _ := strings.Cut(strings.ReplaceAll(c.token(), "–", "-"), "-")
	a, okA := digitsOf(lo)
	b, okB := digitsOf(hi)
	after := c.text[c.end:]
	next := nextWord(after)
	if !okA || !okB || a >= b || governed(c) || months[next] || isYearBlocked(a, next) || isYearBlocked(b, next) {
		return "", 0, false
	}
	g, ok := nounGender(next, a, b)
	if !ok {
		return "", 0, false
	}
	return join(cardinalWords(a, g)) + " — " + join(cardinalWords(b, g)), c.end, true
}

const (
	maxHour   = 23
	maxMinute = 59
)

func expandTime(c numCtx) (string, int, bool) {
	hs, ms, _ := strings.Cut(c.token(), ":")
	h, _ := strconv.Atoi(hs)
	m, _ := strconv.Atoi(ms)
	if h > maxHour || m > maxMinute || governed(c) {
		return "", 0, false
	}
	out := cardinalWords(h, masculine)
	switch {
	case m == 0:
		out = append(out, "ноль", "ноль")
	case m < ten:
		out = append(out, "ноль", units(masculine)[m])
	default:
		out = append(out, cardinalWords(m, masculine)...)
	}
	return join(out), c.end, true
}

var fractionDenominators = []string{"", "десят", "сот", "тысячн"}

// maxFractionDigits is how many digits after the comma are spoken ("тысячных").
const maxFractionDigits = 3

// expandDecimal: «2,5» → «две целых пять десятых»; optionally with a %.
func expandDecimal(c numCtx) (string, int, bool) {
	ip, fp, _ := strings.Cut(c.token(), ",")
	whole, ok := digitsOf(ip)
	frac, ok2 := strconv.Atoi(fp)
	if !ok || ok2 != nil || len(fp) > maxFractionDigits || frac == 0 || governed(c) {
		return "", 0, false
	}
	out := cardinalWords(whole, feminine)
	out = append(out, plural(whole, "целая", "целых", "целых"))
	out = append(out, cardinalWords(frac, feminine)...)
	den := fractionDenominators[len(fp)]
	if frac%ten == 1 && frac%hundred != 11 {
		out = append(out, den+"ая")
	} else {
		out = append(out, den+"ых")
	}
	end := c.end
	if sp, ok := percentSign(c.text[c.end:]); ok {
		out = append(out, "процента")
		end += sp
	}
	return join(out), end, true
}
