package meeting

import (
	"strings"
	"testing"
)

func TestClock(t *testing.T) {
	for _, tc := range []struct {
		sec  float64
		want string
	}{{-3, "0:00"}, {0, "0:00"}, {65.9, "1:05"}, {754, "12:34"}, {3723, "1:02:03"}} {
		if got := Clock(tc.sec); got != tc.want {
			t.Errorf("Clock(%v) = %q, want %q", tc.sec, got, tc.want)
		}
	}
}

func TestTranscriptMarkdownNamesTheSpeakers(t *testing.T) {
	m := Manifest{Title: "Plan", Started: t0, Labels: Labels{Me: "Anatoly", Them: "Other"}}
	md := TranscriptMarkdown(m, []Turn{
		{Speaker: SpeakerMe, S: 1, E: 3, Text: "hello there"},
		{Speaker: SpeakerThem, S: 65, E: 70, Text: "good morning"},
	})
	for _, want := range []string{"# Plan — ", "**Anatoly** [0:01]: hello there", "**Other** [1:05]: good morning"} {
		if !strings.Contains(md, want) {
			t.Errorf("transcript lacks %q:\n%s", want, md)
		}
	}
}

func TestPromptTextIsOneLinePerTurn(t *testing.T) {
	m := Manifest{Labels: Labels{Me: "A", Them: "B"}}
	got := PromptText(m, []Turn{{Speaker: SpeakerMe, S: 1, Text: "x y"}, {Speaker: SpeakerThem, S: 2, Text: "z"}})
	if got != "[0:01] A: x y\n[0:02] B: z\n" {
		t.Fatalf("PromptText = %q", got)
	}
}

// A name is text, not markup: the characters markdown reads are escaped where the name is printed bold, so a name
// of "*x*" or "[a](http://e)" stays a name in the exported file (#256).
// Mutation: internal/meeting/transcript.go TranscriptMarkdown, replace `escapeMarkdown(m.Labels.turnLabel(t))` with
// `m.Labels.turnLabel(t)` -> RED.
func TestTranscriptMarkdownEscapesNames(t *testing.T) {
	m := Manifest{Started: t0, Labels: Labels{Me: "a*b_c", Them: "[x](http://e) `y` <b>"}}
	md := TranscriptMarkdown(m, []Turn{
		{Speaker: SpeakerMe, S: 1, E: 2, Text: "hi"},
		{Speaker: SpeakerThem, S: 3, E: 4, Text: "yo"},
	})
	for _, want := range []string{"**a\\*b\\_c** [0:01]", "**\\[x\\](http://e) \\`y\\` \\<b\\>** [0:03]"} {
		if !strings.Contains(md, want) {
			t.Errorf("transcript lacks %q:\n%s", want, md)
		}
	}
	plain := TranscriptMarkdown(Manifest{Started: t0, Labels: Labels{Me: "Anatoly", Them: "Иван Петров"}}, []Turn{{Speaker: SpeakerMe, S: 1, Text: "hi"}})
	if !strings.Contains(plain, "**Anatoly** [0:01]") {
		t.Errorf("a plain name was changed:\n%s", plain)
	}
}
