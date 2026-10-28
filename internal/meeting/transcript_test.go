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

// A rendering viewer fetches <img src=...> and <http://...> by itself: turn text is third-party speech and the
// title is user text, so no < reaches transcript.md unescaped, and normal text is unchanged (#235).
// Mutations: transcript.go TranscriptMarkdown, `escapeAngle(t.Text)` -> `t.Text` -> RED (F6); the title line
// `headingLine(m)` -> `"# " + heading(m)` -> RED (F7).
func TestTranscriptMarkdownEscapesAngleBracketsInTitleAndTurns(t *testing.T) {
	img := "<img src=http://example.invalid/x.png>"
	m := Manifest{Title: img, Started: t0, Labels: Labels{Me: "A", Them: "B"}}
	md := TranscriptMarkdown(m, []Turn{
		{Speaker: SpeakerMe, S: 1, Text: "see " + img},
		{Speaker: SpeakerThem, S: 2, Text: "<http://example.invalid/a> and 3 < 4, plain words"},
	})
	assertAnglesEscaped(t, "transcript", md)
	for _, want := range []string{`# \<img src=http://example.invalid/x.png\> — `, `**A** [0:01]: see \<img`, `plain words`} {
		if !strings.Contains(md, want) {
			t.Errorf("transcript lacks %q:\n%s", want, md)
		}
	}
	if got := TranscriptMarkdown(Manifest{Started: t0, Labels: Labels{Me: "A"}}, []Turn{{Speaker: SpeakerMe, S: 1, Text: "Привет, как дела? (ok) #1"}}); !strings.Contains(got, "**A** [0:01]: Привет, как дела? (ok) #1\n") {
		t.Errorf("normal text was changed:\n%s", got)
	}
}

// The app (DictationCore TranscriptTurn.parse, MeetingPlaybackTests.testTurnTextRoundTripsTheGoWriter) pins the same
// bytes: turn text is escaped with escapeMarkdown, and the app takes the backslashes out again.
func TestTranscriptMarkdownTurnTextContract(t *testing.T) {
	m := Manifest{Started: t0, Labels: Labels{Me: "A"}}
	md := TranscriptMarkdown(m, []Turn{{Speaker: SpeakerMe, S: 1, Text: `[Music] AT&T snake_case 3 > 2 C:\dir`}})
	if want := `**A** [0:01]: \[Music\] AT\&T snake\_case 3 \> 2 C:\\dir` + "\n"; !strings.Contains(md, want) {
		t.Fatalf("transcript lacks %q:\n%s", want, md)
	}
}
