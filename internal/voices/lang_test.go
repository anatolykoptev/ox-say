package voices

import "testing"

// Mutation: internal/voices/lang.go latinLanguage, change `best < winnerRatio*second`
// to `false` -> RED (the Spanish/Portuguese and Czech/Polish cases are claimed
// by the nearer relative).
func TestLanguage(t *testing.T) {
	for _, tc := range []struct {
		name, text, want string
	}{
		{"english", "Thanks everyone for joining today, we will go through the plan and the open questions now.", "en"},
		{"english with I", "I think that we should have it done by Friday but I am not sure about the budget.", "en"},
		{"german", "Danke, dass ihr alle heute dabei seid, wir gehen jetzt den Plan und die offenen Fragen durch.", "de"},
		{"french", "Merci à tous d'être là aujourd'hui, nous allons passer en revue le plan et les questions ouvertes.", "fr"},
		{"french elisions", "C'est l'heure, j'ai dit que l'équipe n'est pas prête et qu'il faut d'abord finir l'audit.", "fr"},
		{"spanish", "Gracias a todos por venir hoy, vamos a revisar el plan y las preguntas abiertas con el equipo.", "es"},
		{"italian", "Grazie a tutti per essere qui oggi, andiamo a rivedere il piano e le domande che sono ancora aperte.", "it"},
		{"portuguese", "Obrigado a todos por estarem aqui hoje, vamos rever o plano e as perguntas que ainda estão em aberto.", "pt"},
		{"dutch", "Bedankt dat jullie er allemaal zijn, we gaan het plan en de open vragen nu doornemen met het team.", "nl"},
		{"polish", "Dziękuję wszystkim, że jesteście tutaj, przejdziemy teraz przez plan i jest kilka pytań, na które nie mamy jeszcze odpowiedzi.", "pl"},
		{"russian", "Спасибо всем, что пришли сегодня, сейчас мы пройдёмся по плану и по открытым вопросам.", "ru"},
		{"ukrainian", "Дякую всім, що прийшли сьогодні, зараз ми пройдемося по плану і по відкритих питаннях.", "uk"},
		{"russian with one Ukrainian word", "Мы вчера обсуждали, что эта команда из Київ приедет в пятницу, и это очень хорошая новость для всех нас, вы же сами рады.", "ru"},
		// Bulgarian writes ъ in nearly every sentence and has no ы э ё і ї є ґ:
		// nothing here tells it from Russian written without ы, so it is unclaimed.
		{"bulgarian", "Благодаря на всички, че дойдохте днес, сега ще разгледаме плана и отворените въпроси за екипа.", ""},
		{"serbian", "Хвала свима што сте дошли данас, сада ћемо проћи кроз план и отворена питања за тим.", ""},
		{"belarusian has both sets", "Дзякуй усім, што прыйшлі сёння, зараз мы разгледзім план і адкрытыя пытанні для каманды ў Мінску.", ""},
		{"czech is not polish", "Děkuji všem, že jste dnes přišli, teď projdeme plán a otevřené otázky, které jsou před námi.", ""},
		{"czech", "Já jsem dnes ráno řekl, že to je pro nás všechny velmi důležité, ale jak už jsme se bavili, nemáme na to dost času a musíme se rozhodnout.", "cs"},
		{"czech second", "Děkuji vám všem, že jste přišli. Máme dnes před sebou několik věcí a já bych chtěl začít tím, co jsme minule nedokončili, protože to je pro nás důležité.", "cs"},
		// Slovak shares most of Czech's function words; sa, ako, som, sú, nie
		// and the like tell them apart.
		{"slovak", "Ďakujem vám všetkým, že ste prišli. Dnes máme pred sebou niekoľko vecí a ja by som chcel začať tým, čo sme minule nedokončili, pretože to je pre nás dôležité.", "sk"},
		{"slovak second", "Ja som dnes ráno povedal, že to je pre nás všetkých veľmi dôležité, ale ako sme sa už rozprávali, nemáme na to dosť času a musíme sa rozhodnúť.", "sk"},
		{"finnish is unclaimed", "Kiitos kaikille että tulitte tänään, käymme nyt läpi suunnitelman ja avoimet kysymykset yhdessä.", ""},
		{"too short", "ok thanks", ""},
		{"cyrillic too short", "да", ""},
		{"digits only", "12 345 678 9", ""},
		{"chinese", "谢谢大家今天来参加我们现在讨论计划和未解决的问题", ""},
		{"mixed english and german", "the plan and das ist nicht the budget aber we have it und wir are done ist es", ""},
		{"empty", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := Language(tc.text); got != tc.want {
				t.Fatalf("Language(%q) = %q, want %q", tc.text, got, tc.want)
			}
		})
	}
}
