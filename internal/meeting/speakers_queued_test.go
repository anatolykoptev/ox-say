package meeting

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

// The answer to an edit says whether the notes were queued to be written again, from the branch the runner
// actually took: a client that guessed from the kind of edit would refresh its exported copy with notes that are
// about to change (a rename the substitution could not do safely is queued like a merge).
// Mutations: internal/meeting/speakers_runner.go queueNotesAfter, delete `v.NotesQueued = true` -> RED (merge,
// unsafe rename); the `if cur.NotesStale {` block's `v.NotesQueued = true` -> RED (finished stale edit);
// internal/meeting/speakers_runner.go EditSpeakers, final `return View(*m, next, turns), nil` -> set NotesQueued
// true first -> RED (substituted rename).
func TestAnEditSaysWhetherTheNotesWereQueued(t *testing.T) {
	t.Run("substituted rename", func(t *testing.T) {
		f, _, id, dir := settledNotes(t)
		if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": "Ivan"}}); err != nil {
			t.Fatal(err)
		}
		setNoteText(t, dir, "Ivan said hello.")
		v, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": "Boris"}})
		if err != nil || v.NotesQueued || f.load(t, id).Status != StatusDone {
			t.Fatalf("notes_queued %v, err %v, status %s: a rename done in place is final", v.NotesQueued, err, f.load(t, id).Status)
		}
	})
	t.Run("unsafe rename", func(t *testing.T) {
		f, _, id, dir := settledNotes(t)
		if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": "Ivan"}}); err != nil {
			t.Fatal(err)
		}
		setNoteText(t, dir, "Ivan said so.")
		v, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": "Ivan Petrov"}})
		if err != nil || !v.NotesQueued || f.load(t, id).Status != StatusSummarizing {
			t.Fatalf("notes_queued %v, err %v, status %s: a rename that was queued must say so", v.NotesQueued, err, f.load(t, id).Status)
		}
	})
	t.Run("merge", func(t *testing.T) {
		f, id, _ := settledGroup(t)
		v, err := f.r.EditSpeakers(id, Edit{Merge: map[string]string{"them:3": "them:1"}})
		if err != nil || !v.NotesQueued {
			t.Fatalf("notes_queued %v, err %v", v.NotesQueued, err)
		}
	})
	t.Run("a finished stale edit", func(t *testing.T) {
		f, id, dir := settledGroup(t)
		merge := Edit{Merge: map[string]string{"them:3": "them:1"}}
		if _, err := f.r.EditSpeakers(id, merge); err != nil {
			t.Fatal(err)
		}
		if err := f.r.Process(context.Background(), id); err != nil { // the notes are written: status done
			t.Fatal(err)
		}
		st, _ := LoadSpeakers(dir)
		st.NotesStale = true // the first attempt died after saving the speakers and before queueing the notes
		if err := SaveSpeakers(dir, st); err != nil {
			t.Fatal(err)
		}
		v, err := f.r.EditSpeakers(id, merge)
		if err != nil || !v.NotesQueued {
			t.Fatalf("notes_queued %v, err %v: the repeat queued the notes", v.NotesQueued, err)
		}
	})
	t.Run("the field is in the JSON", func(t *testing.T) {
		raw, _ := json.Marshal(SpeakersView{NotesQueued: true})
		if !strings.Contains(string(raw), `"notes_queued":true`) {
			t.Fatalf("%s", raw)
		}
	})
}
