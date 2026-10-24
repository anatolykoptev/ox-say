package meeting

import (
	"fmt"
	"strings"
)

// headings are the notes sections in the meeting's language. Languages
// without a table use English: the model still writes the content in the
// transcript's own language.
var headings = map[string]struct{ summary, decisions, actions, questions, numbers, unstated, partial, short string }{
	"en": {"Summary", "Decisions", "Action items", "Open questions", "Key numbers and dates", "not stated",
		"Part %d of the transcript could not be summarized.", "The recording is too short to summarize."},
	"ru": {"Резюме", "Решения", "Задачи", "Открытые вопросы", "Ключевые цифры и даты", "не указано",
		"Часть %d записи не удалось обработать.", "Запись слишком короткая для заметок."},
}

// NotesMarkdown is notes.md.
func NotesMarkdown(m Manifest, n Notes, lang string) string {
	h, ok := headings[lang]
	if !ok {
		h = headings["en"]
	}
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n## %s\n\n%s\n", heading(m), h.summary, strings.TrimSpace(n.Summary))
	section := func(title string, items []string) {
		if len(items) == 0 {
			return
		}
		fmt.Fprintf(&b, "\n## %s\n\n", title)
		for _, it := range items {
			fmt.Fprintf(&b, "- %s\n", it)
		}
	}
	section(h.decisions, n.Decisions)
	if len(n.ActionItems) > 0 {
		fmt.Fprintf(&b, "\n## %s\n\n", h.actions)
		for _, a := range n.ActionItems {
			fmt.Fprintf(&b, "- [ ] %s — %s — %s\n", orDash(a.Who, h.unstated), a.What, orDash(a.When, h.unstated))
		}
	}
	section(h.questions, n.OpenQuestions)
	section(h.numbers, n.Numbers)
	for _, i := range n.SkippedChunks {
		fmt.Fprintf(&b, "\n_%s_\n", fmt.Sprintf(h.partial, i+1))
	}
	return b.String()
}

func orDash(s, unstated string) string {
	if isUnstated(s) {
		return unstated
	}
	return s
}

// ShortNotesMarkdown is notes.md for a recording with too little speech to
// summarize.
func ShortNotesMarkdown(m Manifest, lang string) string {
	h, ok := headings[lang]
	if !ok {
		h = headings["en"]
	}
	return fmt.Sprintf("# %s\n\n%s\n", heading(m), h.short)
}
