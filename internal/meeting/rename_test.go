package meeting

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func firstLine(t *testing.T, dir, name string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	line, _, _ := strings.Cut(string(raw), "\n")
	return line
}

func afterFirstLine(t *testing.T, dir, name string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	_, rest, _ := strings.Cut(string(raw), "\n")
	return rest
}

// A rename changes the manifest and the heading of every markdown file that carries the title, and nothing else.
// Mutation: internal/meeting/rename.go Rename, skip the notes.md heading (drop NotesMD from the rewritten files)
// -> RED.
func TestRenameRewritesTheManifestAndBothHeadings(t *testing.T) {
	f, id, dir := settledGroup(t)
	transcriptBody := afterFirstLine(t, dir, TranscriptMD)
	notesBody := afterFirstLine(t, dir, NotesMD)
	m, err := f.r.Rename(id, "Квартальный план")
	if err != nil {
		t.Fatal(err)
	}
	if m.Title != "Квартальный план" || f.load(t, id).Title != "Квартальный план" {
		t.Fatalf("manifest title = %q", f.load(t, id).Title)
	}
	for name, body := range map[string]string{TranscriptMD: transcriptBody, NotesMD: notesBody} {
		if h := firstLine(t, dir, name); !strings.HasPrefix(h, "# Квартальный план — ") {
			t.Errorf("%s heading = %q", name, h)
		}
		if got := afterFirstLine(t, dir, name); got != body {
			t.Errorf("%s: the body changed", name)
		}
	}
}

// The same request again redoes the files (a rename that died halfway is finished by repeating it), and an empty
// title is the create rule: "Meeting" stands in.
func TestRenameIsRepeatableAndAnEmptyTitleFallsBack(t *testing.T) {
	f, id, dir := settledGroup(t)
	if _, err := f.r.Rename(id, "One"); err != nil {
		t.Fatal(err)
	}
	// half-done: the manifest has the title, the notes heading is the old one
	raw, _ := os.ReadFile(filepath.Join(dir, NotesMD))
	_ = os.WriteFile(filepath.Join(dir, NotesMD), []byte(strings.Replace(string(raw), "# One", "# Plan", 1)), 0o600)
	if _, err := f.r.Rename(id, "One"); err != nil {
		t.Fatal(err)
	}
	if h := firstLine(t, dir, NotesMD); !strings.HasPrefix(h, "# One — ") {
		t.Fatalf("the repeat did not redo the notes heading: %q", h)
	}
	if _, err := f.r.Rename(id, ""); err != nil {
		t.Fatal(err)
	}
	if h := firstLine(t, dir, TranscriptMD); !strings.HasPrefix(h, "# Meeting — ") {
		t.Fatalf("empty title heading = %q", h)
	}
}

// A meeting being recorded or processed is refused like a speakers edit is: the pass in flight would write the old
// title after it.
// Mutation: internal/meeting/rename.go Rename, delete the status switch -> RED.
func TestRenameRefusedWhileBusy(t *testing.T) {
	f := newFixture(t)
	m, _, err := f.r.Store.Create(Manifest{Title: "Plan"}, t0)
	if err != nil {
		t.Fatal(err)
	}
	for _, st := range []Status{StatusRecording, StatusQueued, StatusTranscribing, StatusSummarizing} {
		_, _ = f.r.Store.Update(m.ID, func(mm *Manifest) { mm.Status = st })
		if _, err := f.r.Rename(m.ID, "New"); !errors.Is(err, ErrSpeakersBusy) {
			t.Errorf("%s: err = %v, want ErrSpeakersBusy", st, err)
		}
		if got := f.load(t, m.ID).Title; got != "Plan" {
			t.Errorf("%s: title changed to %q", st, got)
		}
	}
}

// A failed meeting with no transcript has no markdown to rewrite: the manifest changes, no file appears. An unknown
// id is ErrNotFound.
func TestRenameOfAFailedMeetingWithoutFilesAndOfAnUnknownID(t *testing.T) {
	f := newFixture(t)
	m, dir, _ := f.r.Store.Create(Manifest{Title: "Plan"}, t0)
	_, _ = f.r.Store.Update(m.ID, func(mm *Manifest) { mm.Status = StatusFailed })
	if _, err := f.r.Rename(m.ID, "New"); err != nil {
		t.Fatal(err)
	}
	if f.load(t, m.ID).Title != "New" {
		t.Fatal("title not changed")
	}
	for _, name := range []string{TranscriptMD, NotesMD} {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			t.Errorf("%s appeared", name)
		}
	}
	if _, err := f.r.Rename("19700101-000000-nope", "x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown id: %v", err)
	}
}

// A rename and a speakers edit at once do not lose each other: the speakers edit has read the manifest (old title)
// and is about to write transcript.md whole; the rename, kept waiting under the meeting's lock, rewrites the headings
// after it. The hook holds the edit 300 ms after its read, long enough for an unlocked rename to finish first.
// Mutation: internal/meeting/rename.go Rename, delete the `defer r.speakerLocks.lock(id)()` line -> RED (the
// transcript keeps the old title).
func TestRenameAndSpeakersEditAtOnceKeepBoth(t *testing.T) {
	f, id, dir := settledGroup(t)
	done := make(chan error, 1)
	armed := true
	f.r.afterSpeakersRead = func() {
		if !armed {
			return
		}
		armed = false
		go func() {
			_, err := f.r.Rename(id, "Новый план")
			done <- err
		}()
		select {
		case err := <-done:
			done <- err
		case <-time.After(300 * time.Millisecond):
		}
	}
	if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{"them:1": "Ivan"}}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the rename never finished")
	}
	for _, name := range []string{TranscriptMD, NotesMD} {
		if h := firstLine(t, dir, name); !strings.HasPrefix(h, "# Новый план — ") {
			t.Errorf("%s heading = %q: the rename was lost", name, h)
		}
	}
	if raw, _ := os.ReadFile(filepath.Join(dir, TranscriptMD)); !strings.Contains(string(raw), "Ivan") {
		t.Error("the speakers edit was lost")
	}
	if got := f.load(t, id).Title; got != "Новый план" {
		t.Errorf("manifest title = %q", got)
	}
}

// The status is read again under the store lock: a Retry or a Finish that queued the meeting between Rename's first
// check and its update wins, and the rename is refused without touching the manifest. The hook queues the meeting
// in exactly that window and records the manifest file (identity, mtime, bytes) to prove nothing re-saved it.
// Mutation: internal/meeting/rename.go Rename, drop the `!renameable(m.Status)` check inside the Store.Update
// closure -> RED (the rename goes through on a queued meeting). Without the veto the same window re-saves the
// manifest unchanged: RED on the file comparison.
func TestRenameRefusesAMeetingThatTurnedBusyBeforeTheUpdate(t *testing.T) {
	f, id, dir := settledGroup(t)
	path := filepath.Join(dir, ManifestFile)
	var before os.FileInfo
	var beforeRaw []byte
	f.r.beforeRenameUpdate = func() {
		if _, err := f.r.Store.Update(id, func(m *Manifest) { m.Status = StatusQueued }); err != nil {
			t.Error(err)
			return
		}
		before, _ = os.Stat(path)
		beforeRaw, _ = os.ReadFile(path)
		time.Sleep(20 * time.Millisecond) // a later save would carry a later mtime
	}
	_, err := f.r.Rename(id, "Too late")
	if !errors.Is(err, ErrSpeakersBusy) {
		t.Fatalf("Rename on a meeting that turned busy = %v, want ErrSpeakersBusy", err)
	}
	if before == nil {
		t.Fatal("the hook never ran")
	}
	got := f.load(t, id)
	if got.Title == "Too late" || got.Status != StatusQueued {
		t.Fatalf("manifest = title %q status %q", got.Title, got.Status)
	}
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	if !os.SameFile(before, after) || !after.ModTime().Equal(before.ModTime()) || string(raw) != string(beforeRaw) {
		t.Error("the refused rename re-saved the manifest")
	}
}

// A rename rewrites the headings the same way the renderers write them: a title with < is escaped in both files.
// Mutation: internal/meeting/rename.go Rename, `line := headingLine(*m)` -> `"# " + heading(*m)` -> RED.
func TestRenameEscapesAngleBracketsInTheHeadings(t *testing.T) {
	f, id, dir := settledGroup(t)
	if _, err := f.r.Rename(id, "<img src=http://example.invalid/x.png>"); err != nil {
		t.Fatal(err)
	}
	for _, name := range headingFiles {
		if h := firstLine(t, dir, name); !strings.HasPrefix(h, `# \<img src=http://example.invalid/x.png\> — `) {
			t.Errorf("%s heading = %q", name, h)
		}
	}
}
