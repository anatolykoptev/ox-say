//go:build ignore

// Regenerates internal/meeting/notes_calibration_data_test.go: the synthetic
// samples below, each with its real token count from llama-server's
// /tokenize (Qwen3.5 vocab, shared by the 4B and the 9B).
//
//	ox-llm -m Qwen3.5-4B-Q4_K_M.gguf -ngl 0 -c 512 --port 18977 --host 127.0.0.1 --no-webui &
//	go run scripts/token-calibration/main.go -url http://127.0.0.1:18977 \
//	    > internal/meeting/notes_calibration_data_test.go
//
// The tokenizer is the oracle; the estimator in internal/meeting is checked
// against these counts, never the other way round. Synthetic text only.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"go/format"
	"io"
	"net/http"
	"os"
	"strings"
)

type sample struct{ name, text string }

func rep(s string) string { return strings.Repeat(s, 5) }

func samples() []sample {
	prose := map[string]string{
		"en": "We reviewed the release plan, the schedule risks and how the tasks are split between the teams for the quarter. ",
		"ru": "Мы обсудили план релиза, риски по срокам и распределение задач между командами на квартал. ",
		"uk": "Ми обговорили план релізу, ризики щодо термінів і розподіл завдань між командами на квартал. ",
		"de": "Wir haben den Releaseplan, die Terminrisiken und die Verteilung der Aufgaben zwischen den Teams besprochen. ",
		"es": "Revisamos el plan de lanzamiento, los riesgos del calendario y el reparto de tareas entre los equipos. ",
		"fr": "Nous avons examiné le plan de lancement, les risques de calendrier et la répartition des tâches entre les équipes. ",
		"zh": "我们讨论了发布计划、进度风险以及本季度各团队之间的任务分配情况。",
		"ja": "リリース計画、スケジュールのリスク、四半期ごとのチーム間のタスク分担について話し合いました。",
		"ko": "우리는 출시 계획과 일정 위험, 그리고 분기별 팀 간 업무 분담에 대해 논의했습니다. ",
		"hi": "हमने रिलीज़ योजना, समय-सीमा के जोखिमों और तिमाही के लिए टीमों के बीच कार्यों के बंटवारे पर चर्चा की। ",
		"bn": "আমরা রিলিজ পরিকল্পনা, সময়সূচীর ঝুঁকি এবং দলগুলোর মধ্যে কাজ ভাগ করার বিষয়ে আলোচনা করেছি। ",
		"ta": "வெளியீட்டுத் திட்டம், கால அட்டவணை அபாயங்கள் மற்றும் குழுக்களுக்கு இடையிலான பணிப் பகிர்வு பற்றி விவாதித்தோம். ",
		"th": "เราได้หารือเกี่ยวกับแผนการเผยแพร่ ความเสี่ยงด้านกำหนดเวลา และการแบ่งงานระหว่างทีมในไตรมาสนี้ ",
		"ar": "ناقشنا خطة الإصدار ومخاطر الجدول الزمني وتوزيع المهام بين الفرق خلال هذا الربع. ",
		"he": "דנו בתוכנית השחרור, בסיכוני לוח הזמנים ובחלוקת המשימות בין הצוותים ברבעון. ",
		"ka": "ჩვენ განვიხილეთ გამოშვების გეგმა, ვადების რისკები და გუნდებს შორის ამოცანების განაწილება კვარტალისთვის. ",
		"hy": "Մենք քննարկեցինք թողարկման պլանը, ժամկետների ռիսկերը և թիմերի միջև առաջադրանքների բաշխումը եռամսյակի համար։ ",
		"pa": "ਅਸੀਂ ਰਿਲੀਜ਼ ਯੋਜਨਾ, ਸਮਾਂ-ਸਾਰਣੀ ਦੇ ਜੋਖਮਾਂ ਅਤੇ ਟੀਮਾਂ ਵਿਚਕਾਰ ਕੰਮਾਂ ਦੀ ਵੰਡ ਬਾਰੇ ਚਰਚਾ ਕੀਤੀ। ",
		"gu": "અમે રિલીઝ યોજના, સમયપત્રકના જોખમો અને ટીમો વચ્ચે કામની વહેંચણી વિશે ચર્ચા કરી. ",
		"te": "మేము విడుదల ప్రణాళిక, షెడ్యూల్ ప్రమాదాలు మరియు జట్ల మధ్య పనుల పంపిణీ గురించి చర్చించాము. ",
		"kn": "ನಾವು ಬಿಡುಗಡೆ ಯೋಜನೆ, ವೇಳಾಪಟ್ಟಿಯ ಅಪಾಯಗಳು ಮತ್ತು ತಂಡಗಳ ನಡುವಿನ ಕೆಲಸದ ಹಂಚಿಕೆಯ ಬಗ್ಗೆ ಚರ್ಚಿಸಿದೆವು. ",
		"ml": "ഞങ്ങൾ റിലീസ് പദ്ധതി, ഷെഡ്യൂൾ അപകടസാധ്യതകൾ, ടീമുകൾ തമ്മിലുള്ള ജോലി വിഭജനം എന്നിവ ചർച്ച ചെയ്തു. ",
		"km": "យើងបានពិភាក្សាអំពីផែនការចេញផ្សាយ ហានិភ័យនៃកាលវិភាគ និងការបែងចែកការងារក្នុងចំណោមក្រុម។ ",
		"am": "የመልቀቂያውን እቅድ፣ የጊዜ ሰሌዳ አደጋዎችን እና በቡድኖች መካከል የሥራ ክፍፍልን ለሩብ ዓመቱ ተወያይተናል። ",
	}
	var out []sample
	for _, k := range []string{"en", "ru", "uk", "de", "es", "fr", "zh", "ja", "ko", "hi", "bn", "ta", "th", "ar", "he", "ka", "hy", "pa", "gu", "te", "kn", "ml", "km", "am"} {
		out = append(out, sample{"prose_" + k, rep(prose[k])})
	}
	out = append(out,
		sample{"chat_en", rep("[00:01:12] Speaker 1: Yeah. [00:01:13] Speaker 2: Right, ok. [00:01:15] Speaker 1: Sure. [00:01:16] Speaker 2: Got it, thanks.\n")},
		sample{"chat_ru", rep("[0:12] Я: Да. [0:13] Он: Ок, понял. [0:15] Я: Хорошо. [0:16] Он: Ладно, спасибо.\n")},
		sample{"digits", rep("[12:34] Иван: Да. [12:35] Мария: 4500 рублей, 17.08.2026, 15%. [12:36] Иван: Итого 12 345 678 и 3,14.\n")},
		sample{"digits_en", rep("[12:34] Me: Budget 4500 USD, due 2026-08-17, margin 15%, order 9087123, phone 555 0142 7788.\n")},
		sample{"digits_only", rep("4500 17082026 15 3 1415926535 0042 987654321 2026 08 17 ")},
		sample{"emoji", rep("👍🎉🔥😀🙏✅❤️🚀👩‍💻🤝💡📅 ")},
		sample{"mixed", rep("[0:20] Me: Call Иван about 项目进度 and the 한국어 notes, see https://example.com/a?b=1&c=2 — ok 👍.\n")},
		sample{"url_code", rep("see https://example.com/path/to/page?id=12345&ref=abc_def#section and call foo_bar(x, y) -> {\"k\": [1, 2, 3]}\n")},
	)
	return out
}

func tokens(base, text string) (int, error) {
	body, _ := json.Marshal(map[string]string{"content": text})
	resp, err := http.Post(base+"/tokenize", "application/json", bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out struct {
		Tokens []int `json:"tokens"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || resp.StatusCode != 200 {
		return 0, fmt.Errorf("tokenize: status %d: %v", resp.StatusCode, err)
	}
	return len(out.Tokens), nil
}

func main() {
	base := flag.String("url", "http://127.0.0.1:18977", "llama-server base URL")
	flag.Parse()
	ss := samples()
	var b strings.Builder
	b.WriteString("// Code generated by scripts/token-calibration/main.go; DO NOT EDIT.\n")
	b.WriteString("// Counts: llama-server /tokenize, Qwen3.5-4B-Q4_K_M vocab (the 9B shares it).\n")
	b.WriteString("// Synthetic text only.\n\npackage meeting\n\n")
	b.WriteString("var tokenCalibration = []struct {\n\tname string\n\ttext string\n\treal  int\n}{\n")
	for _, s := range ss {
		n, err := tokens(*base, s.text)
		if err != nil {
			fmt.Fprintln(os.Stderr, s.name, err)
			os.Exit(1)
		}
		fmt.Fprintf(&b, "\t{%q, %q, %d},\n", s.name, s.text, n)
	}
	b.WriteString("}\n")
	src, err := format.Source([]byte(b.String()))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Stdout.Write(src)
}
