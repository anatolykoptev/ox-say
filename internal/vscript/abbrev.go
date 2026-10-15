package vscript

// abbreviations end with a dot that does not end a sentence (razdel's
// abbreviation rule, MIT). Pair abbreviations keep their inner dot.
var abbreviations = map[string]bool{
	"т.е": true, "т.д": true, "т.п": true, "т.к": true, "т.н": true, "т.ч": true, "н.э": true, "и.о": true,
	"г": true, "гг": true, "в": true, "вв": true, "ул": true, "пр": true, "пер": true, "пл": true, "д": true,
	"кв": true, "корп": true, "им": true, "ст": true, "т": true, "тт": true, "руб": true, "коп": true,
	"тыс": true, "млн": true, "млрд": true, "трлн": true, "см": true, "рис": true, "стр": true, "гл": true,
	"п": true, "пп": true, "др": true, "проф": true, "акад": true, "доц": true, "св": true, "ок": true,
	"ср": true, "напр": true, "англ": true, "лат": true,
	"e.g": true, "i.e": true, "mr": true, "mrs": true, "dr": true, "vs": true, "etc": true, "st": true,
}
