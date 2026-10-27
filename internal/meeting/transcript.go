package meeting

import (
	"fmt"
	"strings"
)

// Clock renders seconds as m:ss, or h:mm:ss from one hour.
func Clock(sec float64) string {
	n := int(sec)
	if n < 0 {
		n = 0
	}
	if n >= 3600 {
		return fmt.Sprintf("%d:%02d:%02d", n/3600, n/60%60, n%60)
	}
	return fmt.Sprintf("%d:%02d", n/60, n%60)
}

// label is the speaker's display name.
func (l Labels) label(speaker string) string {
	if speaker == SpeakerMe {
		return l.Me
	}
	if n := strings.TrimSpace(l.Names[speaker]); n != "" {
		return n
	}
	return l.Them
}

// turnLabel is the name printed for a turn: a far-side voice by its voice id.
func (l Labels) turnLabel(t Turn) string {
	if t.Speaker == SpeakerThem && t.Voice != "" {
		return l.label(t.Voice)
	}
	return l.label(t.Speaker)
}

// TranscriptMarkdown is transcript.md: a title line, then one paragraph per
// turn, "**Name** [m:ss]: text".
func TranscriptMarkdown(m Manifest, turns []Turn) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n", heading(m))
	for _, t := range turns {
		fmt.Fprintf(&b, "**%s** [%s]: %s\n\n", escapeMarkdown(m.Labels.turnLabel(t)), Clock(t.S), t.Text)
	}
	return b.String()
}

// markdownSpecials are the characters a name must not carry into a markdown file as markup.
const markdownSpecials = "\\`*_[]<>&"

// escapeMarkdown makes a name inline text: each markup character gets a backslash. Names are allowed to hold them
// (checkName); the renderer is where they are made harmless.
func escapeMarkdown(s string) string {
	if !strings.ContainsAny(s, markdownSpecials) {
		return s
	}
	var b strings.Builder
	for _, r := range s {
		if strings.ContainsRune(markdownSpecials, r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// PromptText is the transcript the language model reads: one line per turn,
// "[m:ss] Name: text". A line is never split by Chunk, so a turn stays whole.
func PromptText(m Manifest, turns []Turn) string {
	var b strings.Builder
	for _, t := range turns {
		fmt.Fprintf(&b, "[%s] %s: %s\n", Clock(t.S), m.Labels.turnLabel(t), t.Text)
	}
	return b.String()
}

func heading(m Manifest) string {
	title := strings.TrimSpace(m.Title)
	if title == "" {
		title = "Meeting"
	}
	return title + " — " + m.Started.Local().Format("2006-01-02 15:04")
}

// WordCount is the number of words in the turns.
func WordCount(turns []Turn) int {
	n := 0
	for _, t := range turns {
		n += len(strings.Fields(t.Text))
	}
	return n
}
