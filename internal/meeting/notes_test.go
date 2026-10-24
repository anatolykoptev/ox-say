package meeting

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
)

func TestChunkBreaksOnLinesAndKeepsEveryLine(t *testing.T) {
	var lines []string
	for i := 0; i < 50; i++ {
		lines = append(lines, "[0:00] Me: "+strings.Repeat("слово ", 20)) // Cyrillic: counted in characters
	}
	text := strings.Join(lines, "\n") + "\n"
	chunks := Chunk(text, 1000)
	if len(chunks) < 5 {
		t.Fatalf("only %d chunks for %d characters", len(chunks), runeLen(text))
	}
	got := 0
	for _, c := range chunks {
		if runeLen(c) > 1000 {
			t.Fatalf("chunk of %d characters exceeds 1000", runeLen(c))
		}
		got += strings.Count(c, "\n") + 1
	}
	if got != 50 {
		t.Fatalf("chunks hold %d lines, want 50: a line was lost or split", got)
	}
	if Chunk("  \n", 1000) != nil {
		t.Fatal("blank text must give no chunks")
	}
}

func TestChunkCutsOneOverlongLine(t *testing.T) {
	chunks := Chunk(strings.Repeat("a", 2500), 1000)
	if len(chunks) != 3 || runeLen(chunks[0]) != 1000 {
		t.Fatalf("chunks = %d", len(chunks))
	}
}

// The same task found in two chunks is one task, and it keeps the owner and
// the date from whichever copy had them.
// Mutation: internal/meeting/notes.go dedupeActions, change `< similarAction`
// to `< 2` -> RED (duplicates survive).
func TestMergeChunksDedupesActionItemsInCode(t *testing.T) {
	a := ChunkNotes{ActionItems: []ActionItem{
		{Who: "", What: "send the proposal after the call", When: ""},
		{Who: "Anatoly", What: "book the photographer", When: "next week"},
	}}
	b := ChunkNotes{ActionItems: []ActionItem{
		{Who: "Anatoly", What: "send the proposal after the call today", When: "Friday"},
		{Who: "Other", What: "send the proposal after the call", When: ""}, // a different owner: a different task
	}}
	got := MergeChunks([]ChunkNotes{a, b}).ActionItems
	if len(got) != 3 {
		t.Fatalf("items = %+v, want 3", got)
	}
	if got[0].Who != "Anatoly" || got[0].When != "Friday" || !strings.Contains(got[0].What, "today") {
		t.Fatalf("merged item = %+v, want the owner, date and the fuller wording", got[0])
	}
}

func TestMergeChunksDedupesDecisionsAndKeepsOrder(t *testing.T) {
	a := ChunkNotes{Decisions: []string{"Use the final song version", "Messages, not Slack"}}
	b := ChunkNotes{Decisions: []string{"use the final song version", "New Instagram account"}}
	got := MergeChunks([]ChunkNotes{a, b}).Decisions
	want := []string{"Use the final song version", "Messages, not Slack", "New Instagram account"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("decisions = %q, want %q", got, want)
	}
}

// fakeChat answers each structured call with the next canned reply.
type fakeChat struct {
	mu      sync.Mutex
	replies []string
	errs    []error
	reqs    []Request
}

func (f *fakeChat) Complete(_ context.Context, r Request) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	i := len(f.reqs)
	f.reqs = append(f.reqs, r)
	if i < len(f.errs) && f.errs[i] != nil {
		return "", f.errs[i]
	}
	if i < len(f.replies) {
		return f.replies[i], nil
	}
	return "", errors.New("no reply left")
}

func replyJSON(t *testing.T, c ChunkNotes) string {
	t.Helper()
	raw, err := json.Marshal(c)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func TestComposeMapsEveryChunkThenMergesTheSummary(t *testing.T) {
	text := strings.Repeat("[0:01] Me: "+strings.Repeat("word ", 30)+"\n", 300) // > 2 chunks at 16000
	n := len(Chunk(text, ChunkChars))
	if n < 2 {
		t.Fatalf("fixture makes %d chunks", n)
	}
	f := &fakeChat{}
	for i := 0; i < n; i++ {
		f.replies = append(f.replies, replyJSON(t, ChunkNotes{Summary: "part summary", ActionItems: []ActionItem{{What: "send the deck"}}}))
	}
	f.replies = append(f.replies, "The merged summary.")
	got, err := Composer{Chat: f}.Compose(context.Background(), text, Labels{Me: "Anatoly", Them: "Other"}, "en")
	if err != nil {
		t.Fatal(err)
	}
	if len(f.reqs) != n+1 || f.reqs[0].Schema == nil || f.reqs[n].Schema != nil {
		t.Fatalf("calls = %d (want %d structured + 1 free text)", len(f.reqs), n)
	}
	if got.Summary != "The merged summary." || len(got.ActionItems) != 1 {
		t.Fatalf("notes = %+v, want one deduped item and the merged summary", got)
	}
	if !strings.Contains(f.reqs[0].System, `"Anatoly"`) {
		t.Fatalf("the system prompt must name the speakers: %q", f.reqs[0].System)
	}
}

// A chunk the model cannot answer twice is skipped and recorded, not fatal.
// Mutation: internal/meeting/notes.go chunk, change `attempt < 2` to
// `attempt < 1` -> RED (the retry is gone, the chunk is skipped).
func TestComposeRetriesOnceThenSkipsAndSaysSo(t *testing.T) {
	text := strings.Repeat("[0:01] Me: "+strings.Repeat("word ", 30)+"\n", 300)
	n := len(Chunk(text, ChunkChars))
	f := &fakeChat{replies: []string{"not json at all"}}
	good := replyJSON(t, ChunkNotes{Summary: "s"})
	f.replies = append(f.replies, good) // the retry of chunk 0 succeeds
	for i := 1; i < n; i++ {
		f.replies = append(f.replies, "{broken", "{broken") // chunk i fails twice
	}
	got, err := Composer{Chat: f}.Compose(context.Background(), text, Labels{}, "en")
	if err != nil {
		t.Fatal(err)
	}
	if len(got.SkippedChunks) != n-1 {
		t.Fatalf("skipped = %v, want chunks 1..%d", got.SkippedChunks, n-1)
	}
	for _, i := range got.SkippedChunks {
		if i == 0 {
			t.Fatalf("chunk 0 answered on its retry and must not be skipped: %v", got.SkippedChunks)
		}
	}
	md := NotesMarkdown(Manifest{}, got, "en")
	if !strings.Contains(md, "could not be summarized") {
		t.Fatalf("notes must say a part was skipped:\n%s", md)
	}
}

func TestComposeFailsWhenEveryChunkFails(t *testing.T) {
	f := &fakeChat{errs: []error{errors.New("down"), errors.New("down")}}
	_, err := Composer{Chat: f}.Compose(context.Background(), "[0:01] Me: hello there everyone\n", Labels{}, "en")
	if !errors.Is(err, ErrNoNotes) {
		t.Fatalf("err = %v, want ErrNoNotes", err)
	}
}

func TestComposeCallsBeforeEveryModelCall(t *testing.T) {
	f := &fakeChat{replies: []string{replyJSON(t, ChunkNotes{Summary: "s"})}}
	calls := 0
	_, err := Composer{Chat: f, Before: func(context.Context) error { calls++; return nil }}.
		Compose(context.Background(), "[0:01] Me: hello there everyone\n", Labels{}, "en")
	if err != nil || calls != 1 {
		t.Fatalf("Before ran %d times (err %v), want once per call", calls, err)
	}
}

func TestNotesMarkdownLocalizesHeadingsAndFillsUnstated(t *testing.T) {
	n := Notes{ChunkNotes: ChunkNotes{Summary: "Итог.", ActionItems: []ActionItem{{What: "прислать план"}}}}
	md := NotesMarkdown(Manifest{Title: "Звонок"}, n, "ru")
	for _, want := range []string{"## Резюме", "## Задачи", "- [ ] не указано — прислать план — не указано"} {
		if !strings.Contains(md, want) {
			t.Errorf("notes lack %q:\n%s", want, md)
		}
	}
	if !strings.Contains(NotesMarkdown(Manifest{}, n, "de"), "## Summary") {
		t.Error("an unknown language falls back to English headings")
	}
}

// The prompts name the output language. A 4B model told only "the transcript's
// language" wrote a third of a Russian call's notes in English.
// Mutation: internal/meeting/notes.go languageRule, return the final
// "same language as the transcript" line for every lang -> RED.
func TestComposeNamesTheOutputLanguageInBothPrompts(t *testing.T) {
	text := strings.Repeat("[0:01] Me: "+strings.Repeat("word ", 30)+"\n", 300)
	n := len(Chunk(text, ChunkChars))
	for _, tc := range []struct{ lang, want string }{
		{"ru", "Write every field in Russian."},
		{"en", "Write every field in English."},
	} {
		f := &fakeChat{}
		for i := 0; i < n; i++ {
			f.replies = append(f.replies, replyJSON(t, ChunkNotes{Summary: "s"}))
		}
		f.replies = append(f.replies, "merged")
		if _, err := (Composer{Chat: f}).Compose(context.Background(), text, Labels{Me: "A", Them: "B"}, tc.lang); err != nil {
			t.Fatal(err)
		}
		if len(f.reqs) != n+1 {
			t.Fatalf("%s: %d calls, want %d", tc.lang, len(f.reqs), n+1)
		}
		for _, i := range []int{0, n} { // the first chunk call and the summary merge
			if sys := f.reqs[i].System; !strings.Contains(sys, tc.want) || !strings.Contains(sys, "Never translate quotes, names or numbers") {
				t.Errorf("%s: call %d system prompt lacks %q:\n%s", tc.lang, i, tc.want, sys)
			}
		}
	}
}

func TestComposeUnknownLanguageFallsBackToTheTranscriptsOwn(t *testing.T) {
	f := &fakeChat{replies: []string{replyJSON(t, ChunkNotes{Summary: "s"})}}
	if _, err := (Composer{Chat: f}).Compose(context.Background(), "[0:01] Me: hello there everyone\n", Labels{}, "de"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(f.reqs[0].System, "same language as the transcript") {
		t.Fatalf("unknown code must keep the generic rule: %q", f.reqs[0].System)
	}
}
