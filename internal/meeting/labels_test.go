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
	if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": "Boris"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": "Olga", "them:2": "Boris"}}); err != nil {
		t.Fatal(err)
	}
	notes = readFile(t, dir, NotesMD)
	if !strings.Contains(notes, "Olga and Boris met.") || !strings.Contains(notes, "Olga — send the plan to Boris") {
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
	if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{SpeakerThem: "Masha"}}); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, dir, NotesMD); !strings.Contains(got, "Masha said hello") {
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

// settledNotes is a processed group call whose notes read "Speaker 1 and Speaker 2 met. Other options were dropped."
func settledNotes(t *testing.T) (*fixture, *fakeChat, string, string) {
	t.Helper()
	f := groupFixture(t, &diarFake{})
	chat := setNotes(f, notesReply(t, "Speaker 1", "Speaker 1 and Speaker 2 met. Other options were dropped."))
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	return f, chat, id, dir
}

// A rename is made by substitution only where that is unambiguous. Where a label is part of another label or name
// (before or after), survives inside its replacement, or the notes hold it inside a longer word (an inflection,
// text without spaces), nothing is substituted: the notes are queued to be written again, like after a merge, and
// the notes on disk are left exactly as they were.
// Mutations: internal/meeting/labels.go, `safe()`: add `return true` as its first line -> RED (the first three
// cases rewrite the notes); `ambiguousIn`: add `return false` as its first line -> RED (the last three).
func TestARenameIsSubstitutedOnlyWhenUnambiguous(t *testing.T) {
	for _, tc := range []struct {
		name   string
		pre    map[string]string // renames made first (safe ones)
		text   string            // replaces "Other options were dropped." in the notes
		final  map[string]string
		queued bool
		never  string // must not appear in notes.md
	}{
		{"a new name that holds another speaker's name", map[string]string{"them:1": "Anna", "them:2": "Anna Lee"}, "Anna Lee joined Anna.",
			map[string]string{"them:1": "Anna Smith"}, true, "Anna Smith Lee"},
		{"a name that holds a label", map[string]string{"them:2": "Speaker 1 (CFO)"}, "Speaker 1 (CFO) approved.",
			map[string]string{"them:1": "Ivan"}, true, "Ivan (CFO)"},
		{"a Russian inflection", map[string]string{"them:1": "Иван"}, "Ивану передали план.",
			map[string]string{"them:1": "Пётр"}, true, "Пётру"},
		{"Japanese without spaces", map[string]string{"them:1": "田中"}, "田中さんが決めた。",
			map[string]string{"them:1": "佐藤"}, true, "佐藤さん"},
		{"an inflected numbered label", nil, "Speakers 1 agreed.",
			map[string]string{"them:1": "Ivan"}, true, "Ivans"},
		{"a plain name stays cheap", map[string]string{"them:1": "Ivan"}, "Ivan said hello.",
			map[string]string{"them:1": "Boris"}, false, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f, chat, id, dir := settledNotes(t)
			if tc.pre != nil {
				if _, err := f.r.EditSpeakers(id, Edit{Rename: tc.pre}); err != nil {
					t.Fatal(err)
				}
			}
			setNoteText(t, dir, tc.text)
			before := readFile(t, dir, NotesMD)
			asked := len(chat.reqs)
			if _, err := f.r.EditSpeakers(id, Edit{Rename: tc.final}); err != nil {
				t.Fatal(err)
			}
			after := readFile(t, dir, NotesMD)
			if tc.never != "" && strings.Contains(after, tc.never) {
				t.Errorf("notes.md was corrupted:\n%s", after)
			}
			if !tc.queued {
				if f.load(t, id).Status != StatusDone || len(chat.reqs) != asked || !strings.Contains(after, "Boris said hello.") {
					t.Errorf("a plain rename: status %s, model asked %d more times:\n%s", f.load(t, id).Status, len(chat.reqs)-asked, after)
				}
				return
			}
			if st := f.load(t, id).Status; st != StatusSummarizing {
				t.Errorf("status = %s, want the notes queued", st)
			}
			if after != before {
				t.Errorf("notes.md was touched although the notes are to be written again:\n%s", after)
			}
			if err := f.r.Process(context.Background(), id); err != nil {
				t.Fatal(err)
			}
			if len(chat.reqs) <= asked {
				t.Error("the model was not asked to write the notes again")
			}
		})
	}
}

// Adding a surname to a name is the commonest rename and is made in place: the new label starts with the old one at a
// word edge, so the only other label or name it may touch is its own. Where the notes already hold the whole new
// name ("Ivan Petrov"), it is not extended again. Another speaker whose name holds the old one still queues the notes.
// Mutations: internal/meeting/labels.go `safe()`, delete the `x == c.free[old]` exemption -> RED (the first case is
// queued); replaceLabels, delete the `strings.HasPrefix(s[i+len(hit):], ext)` skip -> RED ("Ivan Petrov Petrov").
func TestAddingASurnameIsSubstitutedInPlace(t *testing.T) {
	for _, tc := range []struct{ text, want string }{
		{"Ivan said so.", "Ivan Petrov said so."},
		{"Ivan Petrov said so, Ivan agreed.", "Ivan Petrov said so, Ivan Petrov agreed."},
		{"Ivan, Ivan.", "Ivan Petrov, Ivan Petrov."},
	} {
		f, chat, id, dir := settledNotes(t)
		if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": "Ivan"}}); err != nil {
			t.Fatal(err)
		}
		setNoteText(t, dir, tc.text)
		asked := len(chat.reqs)
		v, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": "Ivan Petrov"}})
		if err != nil {
			t.Fatal(err)
		}
		after := readFile(t, dir, NotesMD)
		if v.NotesQueued || f.load(t, id).Status != StatusDone || len(chat.reqs) != asked {
			t.Errorf("%q: queued %v, status %s, model asked %d more times: a surname must not run the model", tc.text, v.NotesQueued, f.load(t, id).Status, len(chat.reqs)-asked)
		}
		if !strings.Contains(after, tc.want) || strings.Contains(after, "Petrov Petrov") {
			t.Errorf("%q: notes.md lacks %q:\n%s", tc.text, tc.want, after)
		}
	}
}

// The substitution is replayable: the notes carry the labels they were written under, so a request applied twice
// (the first died after the notes were corrected and before the speakers were saved) changes nothing the second
// time. A swap is the sharp case: replayed from the speakers alone it would swap back.
// Mutation: internal/meeting/labels.go rewriteNotes, delete `n.Labels = c.labels` -> RED (the replay swaps back).
func TestARenameAppliedTwiceChangesNothingTheSecondTime(t *testing.T) {
	f, _, id, dir := settledNotes(t)
	if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": "Ivan", "them:2": "Olga"}}); err != nil {
		t.Fatal(err)
	}
	snapshot, err := os.ReadFile(filepath.Join(dir, SpeakersJSON))
	if err != nil {
		t.Fatal(err)
	}
	swap := Edit{Rename: map[string]string{"them:1": "Olga", "them:2": "Ivan"}}
	if _, err := f.r.EditSpeakers(id, swap); err != nil {
		t.Fatal(err)
	}
	want := readFile(t, dir, NotesMD)
	if !strings.Contains(want, "Olga and Ivan met.") {
		t.Fatalf("the swap:\n%s", want)
	}
	writeFile(t, filepath.Join(dir, SpeakersJSON), string(snapshot)) // the state before the swap, as after a crash
	if _, err := f.r.EditSpeakers(id, swap); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, dir, NotesMD); got != want {
		t.Errorf("the replay changed the notes:\n%s\nwas\n%s", got, want)
	}
	if got := f.load(t, id).Status; got != StatusDone {
		t.Errorf("status = %s", got)
	}
}

// When the text already holds the start of the new name's extra words but not the words themselves (a longer word,
// another case), substituting would write "Иван Петров Петрович" or "Ivan Petrov petrov": the notes are written
// again by the model instead, and notes.md is left as it was. A new name that only continues the old word
// ("Ivan" -> "Ivanov") is not a surname added after it and is queued too.
// Mutations: internal/meeting/labels.go ambiguousIn, delete the `partialExtension(rest, ext)` clause -> RED (the
// first two cases are substituted); extension(), delete the `isWordRune(r)` guard -> RED (the third is substituted).
func TestAnExtensionThatIsOnlyPartlyThereIsWrittenAgain(t *testing.T) {
	for _, tc := range []struct{ name, from, to, text string }{
		{"a longer word", "Иван", "Иван Петров", "Иван Петрович согласился."},
		{"another case", "Ivan", "Ivan Petrov", "Ivan petrov said so."},
		{"a word continued", "Ivan", "Ivanov", "Ivan said so."},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f, chat, id, dir := settledNotes(t)
			if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": tc.from}}); err != nil {
				t.Fatal(err)
			}
			setNoteText(t, dir, tc.text)
			before := readFile(t, dir, NotesMD)
			asked := len(chat.reqs)
			v, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": tc.to}})
			if err != nil {
				t.Fatal(err)
			}
			if !v.NotesQueued || f.load(t, id).Status != StatusSummarizing {
				t.Errorf("queued %v, status %s: the notes should be written again", v.NotesQueued, f.load(t, id).Status)
			}
			if after := readFile(t, dir, NotesMD); after != before {
				t.Errorf("notes.md was touched:\n%s", after)
			}
			if err := f.r.Process(context.Background(), id); err != nil {
				t.Fatal(err)
			}
			if len(chat.reqs) <= asked {
				t.Error("the model was not asked to write the notes again")
			}
		})
	}
}

func TestExtension(t *testing.T) {
	for _, tc := range []struct {
		old, to, ext string
		ok           bool
	}{
		{"Ivan", "Ivan Petrov", " Petrov", true}, {"Ivan", "Ivanov", "", false}, {"Ivan", "Ivan", "", false}, {"Ivan", "Boris", "", false},
	} {
		if ext, ok := extension(tc.old, tc.to); ext != tc.ext || ok != tc.ok {
			t.Errorf("extension(%q, %q) = %q, %v; want %q, %v", tc.old, tc.to, ext, ok, tc.ext, tc.ok)
		}
	}
}
