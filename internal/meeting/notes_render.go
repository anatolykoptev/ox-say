package meeting

import (
	"fmt"
	"regexp"
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
	fmt.Fprintf(&b, "# %s\n\n## %s\n\n%s\n", heading(m), h.summary, cleanBlock(n.Summary))
	section := func(title string, items []string) {
		if len(items) == 0 {
			return
		}
		fmt.Fprintf(&b, "\n## %s\n\n", title)
		for _, it := range items {
			fmt.Fprintf(&b, "- %s\n", cleanLine(it))
		}
	}
	section(h.decisions, n.Decisions)
	if len(n.ActionItems) > 0 {
		fmt.Fprintf(&b, "\n## %s\n\n", h.actions)
		for _, a := range n.ActionItems {
			fmt.Fprintf(&b, "- [ ] %s — %s — %s\n", orDash(ownerText(a.Who, m, n), h.unstated), cleanLine(a.What), orDash(cleanLine(a.When), h.unstated))
		}
	}
	section(h.questions, n.OpenQuestions)
	section(h.numbers, n.Numbers)
	for _, i := range n.SkippedChunks {
		fmt.Fprintf(&b, "\n_%s_\n", fmt.Sprintf(h.partial, i+1))
	}
	return b.String()
}

// The notes are rendered by whatever opens notes.md, and the text comes from a
// language model reading a transcript the user does not control. A model string
// must stay inline text: no heading, quote, image or link of its own.

var linkTarget = regexp.MustCompile(`\]\([^)\n]*\)?`)

// cleanLine is one model string as a single inline line.
func cleanLine(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	s = linkTarget.ReplaceAllString(s, "]")
	if s != "" && strings.ContainsRune("#[!>", rune(s[0])) {
		s = `\` + s
	}
	return s
}

// cleanBlock is a model string that may span lines (the summary): every line
// is cleaned alone, blank lines are kept as paragraph breaks.
func cleanBlock(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	for i, l := range lines {
		lines[i] = cleanLine(l)
	}
	return strings.Join(lines, "\n")
}

// ownerText is an action item's owner. When it is one of the speakers' labels (the recorder's, the far side's, a
// voice's) it is the user's own text and may hold markup, so it is escaped as in transcript.md; anything else is
// the model's string and is cleaned like the rest, not escaped twice.
func ownerText(who string, m Manifest, n Notes) string {
	line := strings.Join(strings.Fields(who), " ")
	if line != "" {
		labels := []string{m.Labels.Me, m.Labels.Them}
		for _, l := range n.Labels {
			labels = append(labels, l)
		}
		for _, l := range labels {
			if strings.Join(strings.Fields(l), " ") == line {
				return escapeMarkdown(line)
			}
		}
	}
	return cleanLine(who)
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
