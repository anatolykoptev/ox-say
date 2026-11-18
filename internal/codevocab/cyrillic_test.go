package codevocab

import (
	"strings"
	"testing"
	"unicode"

	"github.com/anatolykoptev/ox-say/internal/glossary"
)

var allPacks = []string{"python", "go", "rust"}

// TestCyrillicRowsRewrite: every heard form the packs still carry — a Cyrillic rendering long
// enough to pass the alias rule, or a mixed-script spelling Parakeet actually emits — rewrites to
// the written form through the REAL post-pass, trailing punctuation included. The short and
// prose-reading rows the pack once had live in TestUnsafeRowsNeverRewrite now.
func TestCyrillicRowsRewrite(t *testing.T) {
	pairs := RewritePairs(allPacks)
	for in, want := range map[string]string{
		// the recognition table
		"Пайтест":       "pytest",
		"Из инстанс":    "isinstance",
		"Изинстанс":     "isinstance",
		"asis instance": "isinstance",
		"Энумерейт":     "enumerate",
		"Аппент":        "append",
		"Аппент.":       "append.",
		"Эрстрип":       "rstrip",
		"реплейс":       "replace",
		"реплейс,":      "replace,",
		"Startс with":   "startswith",
		"Endс with":     "endswith",
		"enдs with":     "endswith", // the spelled-out mix Parakeet emits for it
		"Ченнал":        "channel",
		"Комрехеншин":   "comprehension",
		"Компрехеншн":   "comprehension",
		"Дэйсон Лодс":   "json.loads",
		"Регулер экспрессионс": "regular expressions",
		"Сортед": "sorted",
		// builtins and methods
		"Аппенд":      "append",
		"Экстенд":     "extend",
		"Элстрип":     "lstrip",
		"Стрип":       "strip",
		"Эндсвиз":     "endswith",
		"Реверст":     "reversed",
		"Лямда":       "lambda",
		"Асинк":       "async",
		"Авейт":       "await",
		"Эксепт":      "except",
		"Кваргс":      "kwargs",
		"Дандер инит": "__init__",
		"Пайтон":      "Python",
		// go and rust
		"Горутина":  "goroutine",
		"Готест":    "go test",
		"Голанг":    "Go",
		"Анврап":    "unwrap",
		"Карготест": "cargo test",
		"Резалт":    "Result",
		"Трейсбек":  "traceback",
		"Сабагент":  "subagent",
	} {
		if out, _ := glossary.Apply(in, pairs); out != want {
			t.Errorf("%q -> %q, want %q", in, out, want)
		}
	}
}

// TestUnsafeRowsNeverRewrite: the forms filed unsafe and every alias the loader rule or the
// review pruned out of `safe` stay put — a prose, name or brand reading owns them. The review's
// flagged set (принт, джойн, ок, о кей, фанк, рун, нан, пин, дефер, крейт, дроп, арк, аксум,
// серде, горан, элиф, гил, джанго, джупитер, рафф, руф, арси, рейндж, рендж, рейз, синк, трейт,
// тайпинг, селери, Py test, É liv), the conflicting мьютекс/мутекс pair, and every sub-five-letter
// token the length floor dropped.
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
		// the review-flagged prose, name and brand readings, now unsafe or gone
		"ок", "о кей", "фанк", "функ", "рун", "нан", "пин", "джойн", "дефер", "принт",
		"крейт", "дроп", "арк", "аксум", "серде", "горан", "элиф", "гил", "джанго",
		"джупитер", "рафф", "руф", "арси", "рейндж", "рендж", "рейз", "синк", "трейт",
		"тайпинг", "селери", "Py test", "É liv", "SQL alchemy", "Pyproject.tom will",
		"Golem CI link", "Golem CI Lint", "апи",
		// aliases one pack spelled one way and another spelled another way
		"мьютекс", "мутекс",
		// every sub-five-letter Cyrillic token the length floor removed
		"аргс", "бул", "дикт", "тапл", "тупл", "фолс", "фалс", "фолз", "труе", "трю",
		"трай", "селф", "йилд", "илд", "венв", "мап", "мэп", "инам", "енам", "импл",
		"опшн", "сенд",
		// multi-token aliases no single word of which qualifies any more
		"старт свиз", "го вет", "го фмт", "вейт груп", "контекст туду", "го билд",
		"го дот сум", "синк дот ванс", "синк дот вейт груп", "го ланг", "манки патч",
		"фаст апи", "фанк тулз", "итер тулз", "лру кэш", "эл ар ю кеш", "пай торч",
		"ре дот мэтч", "ре мэтч", "юнит тест", "раст фмт", "ар дабл ю лок", "би три мэп",
		"карго билд", "карго фмт", "карго дот лок", "карго дот томл", "хэш мап", "хеш мап",
		"хэш сет", "хеш сет", "эм си пи", "эл джи ти эм", "саб агент", "гет аттр",
		"джи ар пи си",
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

// russianNeutral is 57 ordinary Russian sentences with the task's trap words worked in: the names
// and loanwords the pruned aliases collided with, and the inflected forms a stemming pack pair
// would once have rewritten.
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
	// the inflected forms a stemming pack pair once rewrote — exact-only now, all unchanged
	"Принтами украсили всю обложку альбома.",
	"На футболках были яркие принты.",
	"Футболка с принтом лежала на стуле.",
	"Обложку с принтами показали на выставке.",
	"Мы позвали Джойна на вечеринку.",
	"Открытку подписали Джойну.",
	"Книга Дефера стоит на полке.",
	"Цвета стрипа на форме отличались.",
	"Для съёмки подготовили новые фикстуры.",
	"Дженерики продаются без рецепта.",
	"Заказали роллы и слайсы с лососем.",
	"Реквесты на песни принимали до полуночи.",
	"Фьючеры на нефть подорожали.",
	"Я из инстансов ничего не получил.",
	// the names the short aliases collided with
	"Пин вышел из комнаты.",
	"Ок приехал из Сеула на конференцию.",
	"Фанк записал статью для журнала.",
}

// TestRussianNeutralSet runs every sentence through the real post-pass with all packs on and with
// no packs, and asserts the EXACT set of changed tokens — the expected set is empty: the pruning
// and the exact-only pack matching leave ordinary Russian untouched. A change anywhere fails with
// the full diff list, case-sensitively, so a case-only substitution counts too.
func TestRussianNeutralSet(t *testing.T) {
	if len(russianNeutral) != 57 {
		t.Fatalf("the neutral set must hold 57 sentences, holds %d", len(russianNeutral))
	}
	pairs := RewritePairs(allPacks)
	var changed []string
	for _, in := range russianNeutral {
		if off, _ := glossary.Apply(in, nil); off != in {
			t.Fatalf("packs off rewrote %q to %q", in, off)
		}
		if out, _ := glossary.Apply(in, pairs); out != in {
			changed = append(changed, in+" -> "+out)
		}
	}
	if len(changed) != 0 {
		t.Errorf("%d neutral sentences changed (want 0): %q", len(changed), changed)
	}
}

// TestNoAliasMapsToTwoTargets derives the rewrite surface from the real loaded packs and requires
// one folded heard form to name one written form only: «мьютекс» must not map to go's "mutex" in
// one pack and rust's "Mutex" in another — whichever sorted first would win silently.
// Mutation: the dropConflicting call in packs() removed -> RED (the raw packs carry it nowhere,
// so the test also asserts the loaded safe aliases directly).
func TestNoAliasMapsToTwoTargets(t *testing.T) {
	heard := map[string]string{}
	for _, p := range RewritePairs(allPacks) {
		k := glossary.Key(p.Heard)
		if w, ok := heard[k]; ok && w != p.Meant {
			t.Errorf("heard %q maps to both %q and %q", k, w, p.Meant)
		}
		heard[k] = p.Meant
	}
	for name, ts := range PackTerms() {
		for _, term := range ts {
			for _, a := range term.Safe {
				if a == "мьютекс" || a == "мутекс" {
					t.Errorf("%s %s: conflicting alias %q survived the loader", name, term.Written, a)
				}
			}
		}
	}
}

// TestDropConflicting drives the loader's check itself on a synthetic conflict: the same folded
// heard form filed under two written forms is dropped from BOTH terms, while an alias that maps to
// one target everywhere stays.
// Mutation: dropConflicting returning early, or comparing raw strings instead of glossary.Key ->
// RED (the map below exercises folded-key equality via case).
func TestDropConflicting(t *testing.T) {
	packs := map[string][]Term{
		"go":   {{Written: "mutex", Safe: []string{"Мьютекс", "мьютекс2"}}},
		"rust": {{Written: "Mutex", Safe: []string{"мьютекс", "мьютексы"}}},
	}
	dropConflicting(packs)
	for name, ts := range packs {
		for _, a := range ts[0].Safe {
			if glossary.Key(a) == "мьютекс" {
				t.Errorf("%s kept conflicting alias %q", name, a)
			}
		}
		if len(ts[0].Safe) != 1 {
			t.Errorf("%s safe = %v, want the single non-conflicting alias kept", name, ts[0].Safe)
		}
	}
}

// TestLatinAliasesSurviveTheFold proves the mixed-script fold cannot equate two different Latin
// aliases: for every pure-Latin safe alias word in the real packs the fold is the identity — the
// map only ever rewrites the Cyrillic half of a mixed token, so no alias folds onto another one.
func TestLatinAliasesSurviveTheFold(t *testing.T) {
	n := 0
	for _, ts := range PackTerms() {
		for _, term := range ts {
			for _, a := range term.Safe {
				for _, w := range strings.Fields(a) {
					if !pureLatin(w) {
						continue
					}
					n++
					if got := glossary.Latinized(w); got != w {
						t.Errorf("%s: pure-Latin alias word %q folds to %q", term.Written, w, got)
					}
				}
			}
		}
	}
	if n < 50 {
		t.Fatalf("only %d pure-Latin alias words checked", n)
	}
}

// pureLatin reports whether every letter of s is Latin.
func pureLatin(s string) bool {
	seen := false
	for _, r := range s {
		switch {
		case unicode.Is(unicode.Cyrillic, r):
			return false
		case unicode.Is(unicode.Latin, r):
			seen = true
		}
	}
	return seen
}
