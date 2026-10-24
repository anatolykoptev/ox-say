package meeting

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Whole words only, in one pass: "Speaker 1" is not in "Speaker 10", two names can swap, a name may hold
// characters a pattern would treat as special, and other alphabets work.
// Mutations: internal/meeting/labels.go, delete the `wordEdgeAfter(s, i+len(k)) &&` condition -> RED
// ("Speaker 10" is changed); delete the `wordEdgeBefore(s, i) &&` ... i.e. replace `if wordEdgeBefore(s, i) {`
// with `if true {` -> RED ("ASpeaker 1" is changed).
func TestReplaceLabels(t *testing.T) {
	for _, c := range []struct {
		name, in, want string
		m              map[string]string
	}{
		{"a label", "Speaker 1 agreed.", "Ivan agreed.", map[string]string{"Speaker 1": "Ivan"}},
		{"not inside a longer number", "Speaker 10 and Speaker 1", "Speaker 10 and Ivan", map[string]string{"Speaker 1": "Ivan"}},
		{"not inside a longer word", "ASpeaker 1 and Speaker 1x", "ASpeaker 1 and Speaker 1x", map[string]string{"Speaker 1": "Ivan"}},
		{"a swap", "Ivan asked Olga", "Olga asked Ivan", map[string]string{"Ivan": "Olga", "Olga": "Ivan"}},
		{"the longer key first", "Ivan Petrov and Ivan", "Ivan P. and Ivan", map[string]string{"Ivan Petrov": "Ivan P.", "Ivan": "Ivan"}},
		{"punctuation is an edge", "(Speaker 2), said", "(Olga), said", map[string]string{"Speaker 2": "Olga"}},
		{"cyrillic", "Спикер 2 и Спикер 20", "Ольга и Спикер 20", map[string]string{"Спикер 2": "Ольга"}},
		{"special characters in a name", "Speaker 3 left", "A.B (C) left", map[string]string{"Speaker 3": "A.B (C)"}},
		{"nothing to do", "no names here", "no names here", nil},
	} {
		if got := replaceLabels(c.in, c.m); got != c.want {
			t.Errorf("%s: %q -> %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

// notesReply is what the fake model answers: an owner by label, free text naming a voice, and the word "Other"
// as plain English.
func notesReply(t *testing.T, who, summary string) string {
	return replyJSON(t, ChunkNotes{
		Summary:     summary,
		Decisions:   []string{"Speaker 2 will own the budget"},
		ActionItems: []ActionItem{{Who: who, What: "send the plan to Speaker 2", When: "Friday"}},
	})
}

func setNotes(f *fixture, replies ...string) *fakeChat {
	chat := f.r.Chat.(*fakeChat)
	chat.replies = nil
	for i := 0; i < 4; i++ {
		chat.replies = append(chat.replies, replies...)
	}
	return chat
}

// A rename corrects the notes already written by substitution: the model is not asked again, the meeting keeps its
// status, notes.md is rendered again from the corrected notes.json, and a name can be renamed again or swapped.
// Mutations: internal/meeting/speakers_runner.go EditSpeakers, delete the `rewriteNotes(dir, shown, ...)` call ->
// RED (the notes keep "Speaker 1"); change `if next.Split != cur.Split || !maps.Equal(next.Merge, cur.Merge) {` to
// `if true {` -> RED (the notes are queued again and the model is asked).
func TestARenameCorrectsTheNotesWithoutAskingTheModelAgain(t *testing.T) {
	f := groupFixture(t, &diarFake{})
	chat := setNotes(f, notesReply(t, "Speaker 1", "Speaker 1 and Speaker 2 met. Other options were dropped."))
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	asked := len(chat.reqs)
	v, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": "Ivan", "them:2": "Olga"}})
	if err != nil {
		t.Fatal(err)
	}
	if v.Speakers[0].Label != "Ivan" {
		t.Fatalf("view = %+v", v)
	}
	if got := f.load(t, id).Status; got != StatusDone || len(chat.reqs) != asked {
		t.Fatalf("status %s, model asked %d more times; a rename must leave both alone", got, len(chat.reqs)-asked)
	}
	notes := readFile(t, dir, NotesMD)
	for _, want := range []string{"Ivan and Olga met. Other options were dropped.", "Olga will own the budget", "Ivan — send the plan to Olga — Friday"} {
		if !strings.Contains(notes, want) {
			t.Errorf("notes.md lacks %q:\n%s", want, notes)
		}
	}
	if strings.Contains(notes, "Speaker 1") || strings.Contains(notes, "Speaker 2") {
		t.Errorf("a numbered label survived in\n%s", notes)
	}
	if js := readFile(t, dir, NotesJSON); !strings.Contains(js, `"who": "Ivan"`) {
		t.Errorf("notes.json was not corrected:\n%s", js)
	}
	if tr := readFile(t, dir, TranscriptMD); !strings.Contains(tr, "**Ivan**") || !strings.Contains(tr, "**Olga**") {
		t.Errorf("transcript.md:\n%s", tr)
	}
	// renamed again, then swapped, still without the model
	if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": "Ivan Petrov"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": "Olga", "them:2": "Ivan Petrov"}}); err != nil {
		t.Fatal(err)
	}
	notes = readFile(t, dir, NotesMD)
	if !strings.Contains(notes, "Olga and Ivan Petrov met.") || !strings.Contains(notes, "Olga — send the plan to Ivan Petrov") {
		t.Errorf("after the swap:\n%s", notes)
	}
	if len(chat.reqs) != asked {
		t.Errorf("the model was asked %d more times", len(chat.reqs)-asked)
	}
}

// The generic far-side label is ordinary text in the notes ("Other options"), so only an owner that is exactly
// that label is corrected.
// Mutation: internal/meeting/labels.go changesBetween, delete the `continue // the generic label: exact only`
// line -> RED ("Other options" becomes "Maria options").
func TestRenamingTheSingleFarSideLabelCorrectsOnlyOwners(t *testing.T) {
	f := newFixture(t)
	setNotes(f, replyJSON(t, ChunkNotes{
		Summary:     "Other options were dropped.",
		ActionItems: []ActionItem{{Who: "Other", What: "send the plan", When: "Friday"}},
	}))
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{SpeakerThem: "Maria"}}); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	notes := readFile(t, dir, NotesMD)
	if !strings.Contains(notes, "Other options were dropped.") || !strings.Contains(notes, "Maria — send the plan") {
		t.Errorf("notes.md:\n%s", notes)
	}
	// a name the user gave is a name: renaming it again corrects it in free text too
	setNoteText(t, dir, "Maria said hello")
	if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{SpeakerThem: "Maria Rossi"}}); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, dir, NotesMD); !strings.Contains(got, "Maria Rossi said hello") {
		t.Errorf("a user-given name in free text:\n%s", got)
	}
}

// setNoteText replaces the summary in notes.json, standing in for a model that named the far side by its name.
func setNoteText(t *testing.T, dir, summary string) {
	t.Helper()
	path := filepath.Join(dir, NotesJSON)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	out := strings.Replace(string(raw), "Other options were dropped.", summary, 1)
	if out == string(raw) {
		t.Fatalf("no summary to replace in %s", raw)
	}
	if err := os.WriteFile(path, []byte(out), 0o600); err != nil {
		t.Fatal(err)
	}
}
