package vscript

import "strings"

// Nouns after a number ending in 1 or 2 give the number its gender. After …1
// the noun is nominative singular ("21 день"), after …2 genitive singular
// ("22 дня"); each list pairs the two forms as nom/gen. A noun not listed, or
// a form of the wrong case ("1 человека"), leaves the digits. Words with a
// time-of-day reading ("в 2 ночи", "1 утра") are deliberately absent.
var nounNom, nounGen = buildNouns(map[gender]string{
	masculine: `день/дня час/часа раз/раза рубль/рубля доллар/доллара евро/евро человек/человека процент/процента метр/метра
		километр/километра сантиметр/сантиметра миллиметр/миллиметра грамм/грамма килограмм/килограмма литр/литра шаг/шага
		этап/этапа урок/урока вариант/варианта пункт/пункта балл/балла участник/участника месяц/месяца век/века класс/класса
		градус/градуса кадр/кадра эпизод/эпизода фильм/фильма слой/слоя уровень/уровня файл/файла проект/проекта клиент/клиента
		пользователь/пользователя сервер/сервера пакет/пакета тест/теста раунд/раунда курс/курса`,
	feminine: `минута/минуты секунда/секунды неделя/недели копейка/копейки штука/штуки страница/страницы строка/строки
		цифра/цифры глава/главы часть/части точка/точки ложка/ложки чашка/чашки кнопка/кнопки тысяча/тысячи
		серия/серии версия/версии попытка/попытки задача/задачи функция/функции тема/темы`,
	neuter: `окно/окна место/места слово/слова число/числа яблоко/яблока письмо/письма дело/дела видео/видео
		сообщение/сообщения задание/задания условие/условия`,
})

func buildNouns(groups map[gender]string) (nom, gen map[string]gender) {
	nom, gen = map[string]gender{}, map[string]gender{}
	for g, pairs := range groups {
		for _, p := range strings.Fields(pairs) {
			n, ge, _ := strings.Cut(p, "/")
			nom[n], gen[ge] = g, g
		}
	}
	return nom, gen
}

// obliquePluralEndings are the dative, instrumental and prepositional plural
// endings: a number before such a noun is not nominative ("в 5 домах",
// "за 3 днями", "дал 3 детям"), so its digits stay.
var obliquePluralEndings = []string{"ами", "ями", "ам", "ям", "ах", "ях"}

func obliquePlural(w string) bool {
	for _, e := range obliquePluralEndings {
		if strings.HasSuffix(w, e) {
			return true
		}
	}
	return false
}
