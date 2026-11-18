package codevocab

import (
	"strings"
	"testing"
	"unicode"

	"github.com/anatolykoptev/ox-say/internal/glossary"
	"github.com/anatolykoptev/ox-say/internal/wordlists"
)

var allPacks = []string{"python", "go", "rust"}

// TestCyrillicRowsRewrite: every heard form the task's table made safe — and the Cyrillic
// renderings of the packs' identifiers — rewrites to the Latin written form through the REAL
// post-pass, trailing punctuation included.
func TestCyrillicRowsRewrite(t *testing.T) {
	pairs := RewritePairs(allPacks)
	for in, want := range map[string]string{
		// the recognition table
		"Пайтест":       "pytest",
		"Py test":       "pytest",
		"Из инстанс":    "isinstance",
		"Изинстанс":     "isinstance",
		"asis instance": "isinstance",
		"Энумерейт":     "enumerate",
		"Аппент":        "append",
		"Аппент.":       "append.",
		"Эрстрип":       "rstrip",
		"Джойн":         "join",
		"реплейс":       "replace",
		"реплейс,":      "replace,",
		"Startс with":   "startswith",
		"Регулер экспрессионс": "regular expressions",
		"Сортед": "sorted",
		"Элиф":   "elif",
		"É liv":  "elif",
		// builtins and methods
		"Аппенд":      "append",
		"Экстенд":     "extend",
		"Элстрип":     "lstrip",
		"Стрип":       "strip",
		"Эндсвиз":     "endswith",
		"Реверст":     "reversed",
		"Лямда":       "lambda",
		"Йилд":        "yield",
		"Асинк":       "async",
		"Авейт":       "await",
		"Дикт":        "dict",
		"Тапл":        "tuple",
		"Рейндж":      "range",
		"Принт":       "print",
		"Селф":        "self",
		"Нан":         "None",
		"Труе":        "True",
		"Фолс":        "False",
		"Трай":        "try",
		"Эксепт":      "except",
		"Рейз":        "raise",
		"Кваргс":      "kwargs",
		"Аргс":        "args",
		"Дандер инит": "__init__",
		"Пайтон":      "Python",
		// go and rust
		"Горутина":  "goroutine",
		"Дефер":     "defer",
		"Готест":    "go test",
		"Горан":     "go run",
		"Голанг":    "Go",
		"Мьютекс":   "Mutex", // filed under both go's "mutex" and rust's "Mutex"; rust's pair wins
		"Серде":     "serde",
		"Анврап":    "unwrap",
		"Карготест": "cargo test",
		"Ок":        "Ok",
		"Инам":      "enum",
		"Резалт":    "Result",
		"Трейсбек":  "traceback",
		"Сабагент":  "subagent",
	} {
		if out, _ := glossary.Apply(in, pairs); out != want {
			t.Errorf("%q -> %q, want %q", in, out, want)
		}
	}
}

// TestUnsafeRowsNeverRewrite: the table rows and spellings that failed the dictionary rule stay
// put — they carry the decoder boost through the written form and never become a rewrite.
func TestUnsafeRowsNeverRewrite(t *testing.T) {
	pairs := RewritePairs(allPacks)
	for _, in := range []string{
		"by test", "fixed tours", "Sort it", "quirks", "quarks", "as I seen stance",
		"Пай тест", "Сплит", "сорт", "реверс", "лямбда", "лен", "тру", "нон", "стр",
		"матч", "карго", "район", "токио", "век", "бокс", "клон", "копи", "селл", "дин",
		"эрр", "опцион", "реф селл", "контекст дот контекст", "нил", "паника", "байт",
		"чан", "йота", "руна", "интерфейс", "паб", "район", "сам", "итератор", "статик",
		"го тест", "го ран", "го мод", "ре матч", "рематч", "мок", "питон", "юнион",
		"генератор", "май пай", "нам пай", "пай пи ай", "класс метод", "статик метод",
		"конф тест", "контекст менеджер", "Full Moss",
	} {
		if out, _ := glossary.Apply(in, pairs); out != in {
			t.Errorf("unsafe form %q rewritten to %q", in, out)
		}
	}
}

// TestBoostPairsDropCyrillic: a Cyrillic safe alias is a post-pass rewrite and never a wire alias —
// the decoder is never pushed towards Cyrillic. Mutation: the hasCyrillic skip in BoostPairs removed
// -> RED here.
func TestBoostPairsDropCyrillic(t *testing.T) {
	n := 0
	for _, p := range BoostPairs(allPacks) {
		if hasCyrillic(p.Heard) || hasCyrillic(p.Meant) {
			t.Errorf("Cyrillic reached the decoder boost: %q -> %q", p.Heard, p.Meant)
		}
		if p.Heard != "" {
			n++
		}
	}
	if n == 0 {
		t.Error("no alias pairs at all — the skip dropped Latin aliases too")
	}
}

// russianNeutral is 40 ordinary Russian sentences with the task's trap words worked in.
var russianNeutral = []string{
	"Мы выбрали сорт яблок с кислинкой.",
	"У него погасла лампа реверса.",
	"Летом мы поставили сплит-систему в спальне.",
	"Из окна виднелась река.",
	"Буква лямбда обозначает длину волны.",
	"Она сделала селфи у фонтана.",
	"В субботу мы сидели в джойн-клубе до полуночи.",
	"Диджей Джойн выступил в клубе.",
	"Дефер пояснил, как читается толкование.",
	"Из Токио привезли сувениры.",
	"Он листает чаны по вечерам.",
	"Карго пришло из Китая за две недели.",
	"В теплице раст редкий вид папоротника.",
	"На платье красивый принт с пальмами.",
	"Он читает документацию по регулярным выражениям.",
	"Она рассказала анекдот.",
	"Он пишет диктант без ошибок.",
	"Мы обсудили макроэкономику страны.",
	"Он открыл крейт с инструментами.",
	"На камне вырезана руна.",
	"Матч закончился ничьей.",
	"Ему выдали бокс в паркинге.",
	"Он был первым по району.",
	"Он принёс опцион на собрание.",
	"Сам он сказал, что придёт поздно.",
	"Век технологий наступил.",
	"Эрр приехал из Таллинна.",
	"Он издал короткий ерр вместо ответа.",
	"Паб на углу закрылся.",
	"Лямбда-функция вычисляет интеграл.",
	"Клон овечки Долли был первым.",
	"Он сел на диван с пультом.",
	"Москва встретила нас дождём.",
	"Дети играли во дворе.",
	"Синоптики обещали дождь.",
	"Она работает в библиотеке.",
	"Дед чинил забор.",
	"На столе лежали деньги.",
	"Они спели любимую песню.",
	"Рыбак тянул сеть.",
}

// justifiedCodeTokens is the explicit list of non-dictionary tokens that may change inside
// Russian prose — each is a Cyrillic transliteration of a code term, so the collision is the
// feature's known cost, not a leak. A change outside this list fails the test.
var justifiedCodeTokens = map[string]string{
	"джойн": "transliteration of join(); required table row",
	"дефер": "transliteration of go's defer; not a Russian word",
	"принт": "transliteration of print(); «принт» as a noun is jargon Hunspell lacks",
	"крейт": "transliteration of rust's crate; gaming jargon Hunspell lacks",
}

// TestRussianNeutralSet runs every sentence through the real post-pass with all packs on and with
// no packs. With packs off nothing may change. With packs on a word may change only when it is not
// a Russian dictionary word and sits in justifiedCodeTokens — every such change is logged for the
// report.
func TestRussianNeutralSet(t *testing.T) {
	if len(russianNeutral) != 40 {
		t.Fatalf("the neutral set must hold 40 sentences, holds %d", len(russianNeutral))
	}
	ck := wordlists.New()
	pairs := RewritePairs(allPacks)
	changes := 0
	for _, in := range russianNeutral {
		if off, _ := glossary.Apply(in, nil); off != in {
			t.Fatalf("packs off rewrote %q to %q", in, off)
		}
		out, _ := glossary.Apply(in, pairs)
		if out == in {
			continue
		}
		changes++
		for _, w := range removedWords(in, out) {
			if ck.Common(w) {
				t.Errorf("%q: the ordinary word %q was rewritten", in, w)
				continue
			}
			why, ok := justifiedCodeTokens[strings.ToLower(w)]
			if !ok {
				t.Errorf("%q: %q changed but is not a justified code-only token", in, w)
				continue
			}
			t.Logf("changed %q -> %q (word %q: %s)", in, out, w, why)
		}
	}
	t.Logf("%d of %d neutral sentences changed", changes, len(russianNeutral))
}

// removedWords lists the folded words of `in` that no longer appear in `out`.
func removedWords(in, out string) []string {
	count := map[string]int{}
	for _, w := range words(in) {
		count[w]++
	}
	for _, w := range words(out) {
		if count[w] > 0 {
			count[w]--
		}
	}
	var gone []string
	for w, n := range count {
		for ; n > 0; n-- {
			gone = append(gone, w)
		}
	}
	return gone
}

func words(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
}
