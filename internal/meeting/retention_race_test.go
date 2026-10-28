package meeting

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// unavailableDone is a finished meeting that was recorded while this Mac could not run the diarizer and now can,
// 400 days on: the retention sweep wants its audio and a voices retry would be accepted. It carries a user-made far
// side name so a retry that loses it is visible.
func unavailableDone(t *testing.T) (*fixture, string, string) {
	t.Helper()
	d := &diarFake{}
	f := groupFixture(t, d)
	f.r.DiarizeReady = func() string { return DiarModelsMissing }
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{SpeakerThem: "Maria"}}); err != nil {
		t.Fatal(err)
	}
	f.r.DiarizeReady = func() string { return "" }
	f.now = f.now.Add(400 * 24 * time.Hour)
	if m := f.load(t, id); m.Status != StatusDone || !contains(m.Warnings, WarnDiarUnavailable) {
		t.Fatalf("setup: %+v", m)
	}
	return f, id, dir
}

// The race of #340.1: a voices retry lands between the sweep's judgement and its delete. The retry queues the
// meeting for a transcription of that very audio, so the sweep must leave the audio alone.
// F1 mutation: internal/meeting/retention.go deleteAudio, delete the status re-check under the store lock (the
// `case StatusDone, StatusTranscribed, StatusFailed:` guard inside the Modify) -> RED here (the audio is removed
// from under the queued meeting).
func TestRetentionSkipsAMeetingARetryQueuedMeanwhile(t *testing.T) {
	f, id, dir := unavailableDone(t)
	retried := false
	f.r.beforeAudioDelete = func() {
		retried = true
		if _, err := f.r.RetryVoices(id); err != nil {
			t.Errorf("the retry in the gap: %v", err)
		}
	}
	if n := f.r.SweepRetention(); n != 0 {
		t.Errorf("the sweep deleted the audio of %d meetings, one of them queued", n)
	}
	if !retried {
		t.Fatal("the seam was not reached: the sweep never judged the meeting expired")
	}
	if _, err := os.Stat(filepath.Join(dir, ThemPCM)); err != nil {
		t.Fatalf("them.pcm is gone from under the queued meeting: %v", err)
	}
	m := f.load(t, id)
	if m.AudioDeleted || m.Status != StatusQueued {
		t.Fatalf("manifest = %+v, want queued with its audio", m)
	}
	// and the queued run has what it needs
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if got := f.load(t, id); got.Status != StatusDone || got.VoiceMode != VoicesAuto {
		t.Errorf("after the retry: %+v", got)
	}
}

// The sweep re-checks everything it judged: a meeting that is in progress by the time it takes the lock is skipped
// whatever put it there (here a Retry of the notes, which also re-queues a finished meeting).
func TestRetentionSkipsAMeetingThatIsSummarizingByNow(t *testing.T) {
	f, id, dir := unavailableDone(t)
	f.r.beforeAudioDelete = func() {
		if _, err := f.r.Retry(id); err != nil {
			t.Errorf("Retry: %v", err)
		}
	}
	if n := f.r.SweepRetention(); n != 0 {
		t.Errorf("deleted %d", n)
	}
	if _, err := os.Stat(filepath.Join(dir, ThemPCM)); err != nil {
		t.Fatalf("audio removed from under an in-progress meeting: %v", err)
	}
}

// A queued transcription that finds the recording gone must not blank the finished meeting: the transcript, the
// notes and the user's far side name stay, and the manifest says why nothing was redone.
// F2 mutation: internal/meeting/runner.go transcribe, delete the `r.keepFinishedWithoutAudio(...)` guard call at
// the top -> RED here (transcript.json is rewritten empty, with a "no system audio" warning).
func TestAQueuedMeetingWhoseAudioIsGoneKeepsItsTranscriptAndNotes(t *testing.T) {
	f, id, dir := unavailableDone(t)
	before := map[string]string{}
	for _, name := range []string{TranscriptJSON, TranscriptMD, NotesJSON, NotesMD, SpeakersJSON} {
		before[name] = readFile(t, dir, name)
		if before[name] == "" {
			t.Fatalf("setup: no %s", name)
		}
	}
	for _, name := range audioFiles {
		if err := os.Remove(filepath.Join(dir, name)); err != nil {
			t.Fatal(err)
		}
	}
	// what the old race left behind: queued, audio gone
	if _, err := f.r.Store.Update(id, func(m *Manifest) { m.Status = StatusQueued }); err != nil {
		t.Fatal(err)
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatalf("Process: %v", err)
	}
	for name, want := range before {
		if got := readFile(t, dir, name); got != want {
			t.Errorf("%s changed:\n--- before\n%s\n--- after\n%s", name, want, got)
		}
	}
	m := f.load(t, id)
	if m.Status != StatusDone || m.FailReason != "" || m.Error != "" {
		t.Errorf("manifest = status %s reason %q error %q, want a plain done (a finished meeting carries no failure)", m.Status, m.FailReason, m.Error)
	}
	if !m.AudioDeleted {
		t.Errorf("the manifest does not say the audio is gone: %+v", m)
	}
	if contains(m.Warnings, WarnNoSystemAudio) || contains(m.Warnings, WarnNoMicAudio) {
		t.Errorf("a missing recording was read as a silent one: %v", m.Warnings)
	}
}

// A pair left half-deleted (a crash, a failed unlink) must not let a retry rewrite the transcript from one side:
// the far side is gone and the mic file stays, or the other way round.
// Mutation (unconditional `m.AudioDeleted = true` in the guard) -> RED at the first sweep: the survivor stays.
// F5 mutation: internal/meeting/runner.go keepFinishedWithoutAudio, make the loop's condition require both files
// missing (`gone = true` only when the other channel is missing too) -> RED (the user's turns are rewritten away).
func TestAHalfDeletedPairNeverRewritesTheTranscriptFromOneSide(t *testing.T) {
	for _, gone := range []string{MePCM, ThemPCM} {
		t.Run(gone, func(t *testing.T) {
			f, id, dir := unavailableDone(t)
			tr := readFile(t, dir, TranscriptJSON)
			notes := readFile(t, dir, NotesMD)
			if err := os.Remove(filepath.Join(dir, gone)); err != nil {
				t.Fatal(err)
			}
			if _, err := f.r.Store.Update(id, func(m *Manifest) { m.Status = StatusQueued }); err != nil {
				t.Fatal(err)
			}
			if err := f.r.Process(context.Background(), id); err != nil {
				t.Fatal(err)
			}
			if got := readFile(t, dir, TranscriptJSON); got != tr {
				t.Errorf("transcript.json was rewritten from half a recording:\n%s", got)
			}
			if got := readFile(t, dir, NotesMD); got != notes {
				t.Errorf("notes.md changed")
			}
			if m := f.load(t, id); m.Status != StatusDone || m.AudioDeleted {
				t.Errorf("manifest = %+v; want done with AudioDeleted false while a channel file remains", m)
			}
			// the survivor still goes with the retention period
			if n := f.r.SweepRetention(); n != 1 {
				t.Fatalf("the sweep removed %d meetings' audio, want the half pair finished", n)
			}
			for _, name := range audioFiles {
				if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
					t.Errorf("%s survived the retention sweep", name)
				}
			}
			if !f.load(t, id).AudioDeleted {
				t.Error("AudioDeleted not set after the survivor went")
			}
			if got := readFile(t, dir, TranscriptJSON); got != tr {
				t.Error("the sweep touched the transcript")
			}
		})
	}
}

// A meeting whose mic never had audio (recorded as silent) and whose far side is still here is not "incomplete":
// it is transcribed again as asked.
func TestASideThatNeverHadAudioIsNotALoss(t *testing.T) {
	f, id, dir := unavailableDone(t)
	if err := os.Remove(filepath.Join(dir, MePCM)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.r.Store.Update(id, func(m *Manifest) { m.Status = StatusQueued; m.Warnings = append(m.Warnings, WarnNoMicAudio) }); err != nil {
		t.Fatal(err)
	}
	if kept, err := f.r.keepFinishedWithoutAudio(id, dir); kept || err != nil {
		t.Errorf("kept = %v, %v; want the transcription to go ahead", kept, err)
	}
}

// A transcribed meeting that goes on to its notes carries no stale reason while the notes wait for the model.
func TestAKeptMeetingWaitingForTheNotesModelCarriesNoReason(t *testing.T) {
	f, id, dir := unavailableDone(t)
	for _, name := range append(append([]string{}, audioFiles...), NotesJSON, NotesMD) {
		_ = os.Remove(filepath.Join(dir, name))
	}
	f.notes = "model_missing"
	if _, err := f.r.Store.Update(id, func(m *Manifest) { m.Status = StatusQueued }); err != nil {
		t.Fatal(err)
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	m := f.load(t, id)
	if m.Status != StatusTranscribed || m.NotesPending == "" || m.FailReason != "" || m.Error != "" || !m.AudioDeleted {
		t.Errorf("manifest = %+v", m)
	}
}

// The decision to delete and the move of the files are one step under the store lock, and the unlink is not.
// F6 mutation: internal/meeting/store.go retireLocked, move the rename loop out of the locked function (do it in
// Retire after retireLocked returns) -> RED: the retry in the gap is accepted and queues a meeting whose audio is
// then moved away.
func TestRetentionMovesTheAudioInTheSameLockedStepAsTheDecision(t *testing.T) {
	f, id, dir := unavailableDone(t)
	locked, gap := false, false
	f.r.Store.inRetire = func() {
		locked = !f.r.Store.mu.TryLock() // held by the retire step itself
		if _, err := os.Stat(filepath.Join(dir, ThemPCM)); err != nil {
			t.Errorf("them.pcm was moved before the decision was made: %v", err)
		}
	}
	f.r.Store.afterLock = func() {
		gap = true
		// the lock is free again, the unlink has not begun: a retry now must find the audio gone
		if _, err := f.r.RetryVoices(id); err == nil {
			t.Error("a retry in the gap after the lock was accepted: its audio is moved away")
		}
		if _, err := os.Stat(filepath.Join(dir, ThemPCM)); err == nil {
			t.Error("them.pcm still has its name after the locked step")
		}
	}
	if n := f.r.SweepRetention(); n != 1 {
		t.Fatalf("swept %d", n)
	}
	if !locked || !gap {
		t.Fatalf("seams not reached: locked=%v gap=%v", locked, gap)
	}
	m := f.load(t, id)
	if !m.AudioDeleted || m.Status != StatusDone {
		t.Errorf("manifest = %+v", m)
	}
	left, _ := filepath.Glob(filepath.Join(f.r.Store.Root, tombstonePrefix+"*"))
	if len(left) != 0 {
		t.Errorf("tombstones left after the unlink: %v", left)
	}
}

// An unlink that fails leaves a tombstone holding the audio; the List sweep removes it once it is old enough, so a
// crash between the rename and the unlink does not keep a recording past its retention.
func TestAnAudioTombstoneLeftByAFailedUnlinkIsSweptLater(t *testing.T) {
	f, id, dir := unavailableDone(t)
	fail := true
	f.r.Store.removeAll = func(p string) error {
		if fail {
			return errors.New("busy")
		}
		return os.RemoveAll(p)
	}
	if n := f.r.SweepRetention(); n != 1 {
		t.Fatalf("swept %d", n)
	}
	left, _ := filepath.Glob(filepath.Join(f.r.Store.Root, tombstonePrefix+"*"))
	if len(left) != 1 {
		t.Fatalf("tombstones = %v, want the one with the audio", left)
	}
	if _, err := os.Stat(filepath.Join(left[0], ThemPCM)); err != nil {
		t.Errorf("the tombstone does not hold them.pcm: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, ThemPCM)); err == nil {
		t.Error("the audio still has its place in the meeting")
	}
	fail = false
	old := time.Now().Add(-2 * tombstoneGrace)
	if err := os.Chtimes(left[0], old, old); err != nil { // the name's time is "now"; age it through a rename
		t.Fatal(err)
	}
	renamed := filepath.Join(f.r.Store.Root, tombstonePrefix+id+"-"+strconv.FormatInt(old.UnixNano(), 36))
	if err := os.Rename(left[0], renamed); err != nil {
		t.Fatal(err)
	}
	if _, err := f.r.Store.List(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(renamed); err == nil {
		t.Error("the old tombstone was not swept")
	}
}

// Same, for a meeting that never got notes: the transcript stays and the notes are written from it.
func TestAQueuedMeetingWithoutAudioAndWithoutNotesGetsItsNotes(t *testing.T) {
	f, id, dir := unavailableDone(t)
	tr := readFile(t, dir, TranscriptJSON)
	for _, name := range append(append([]string{}, audioFiles...), NotesJSON, NotesMD) {
		if err := os.Remove(filepath.Join(dir, name)); err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
	}
	if _, err := f.r.Store.Update(id, func(m *Manifest) { m.Status = StatusQueued }); err != nil {
		t.Fatal(err)
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatalf("Process: %v", err)
	}
	if got := readFile(t, dir, TranscriptJSON); got != tr {
		t.Errorf("transcript.json changed")
	}
	if m := f.load(t, id); m.Status != StatusDone || readFile(t, dir, NotesMD) == "" {
		t.Errorf("manifest = %+v, notes %q", m, readFile(t, dir, NotesMD))
	}
}

// A meeting that has no transcript and no audio keeps the behaviour it always had (a capture that heard nothing):
// the guard is for finished meetings only.
func TestAMeetingWithoutAnyTranscriptStillReadsMissingAudioAsSilence(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 20, 20, 5000, false)
	dir, _ := f.r.Store.Dir(id)
	for _, name := range audioFiles {
		_ = os.Remove(filepath.Join(dir, name))
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	m := f.load(t, id)
	if !contains(m.Warnings, WarnNoMicAudio) || !contains(m.Warnings, WarnNoSystemAudio) {
		t.Errorf("warnings = %v", m.Warnings)
	}
}

// What a voices retry of a finished meeting keeps (#340.2): the far side name the user gave, the title, and the
// notes until the new ones are written. With the two voices of this fake the offer mode shows the single label,
// so the name is still on the transcript after the retry.
// F3 mutation: internal/meeting/voices.go dropVoiceState, delete the `keep.Names = map[string]string{SpeakerThem: n}`
// line -> RED here (the name "Maria" is gone from speakers.json and from the transcript).
func TestAVoicesRetryKeepsTheFarSideNameAndTheTitle(t *testing.T) {
	d := &diarFake{two: true}
	f := groupFixture(t, d)
	f.r.Diarize, f.r.DiarizeReady = d.run, func() string { return DiarModelsMissing }
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	if _, err := f.r.EditSpeakers(id, Edit{Rename: map[string]string{SpeakerThem: "Maria"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.r.Rename(id, "Budget call"); err != nil {
		t.Fatal(err)
	}
	f.r.DiarizeReady = func() string { return "" }
	notesBefore := readFile(t, dir, NotesMD)
	if _, err := f.r.RetryVoices(id); err != nil {
		t.Fatal(err)
	}
	// the old notes stay readable until the new ones replace them
	if got := readFile(t, dir, NotesMD); got != notesBefore {
		t.Errorf("notes.md changed at the moment of the retry")
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	st, err := LoadSpeakers(dir)
	if err != nil || st.Names[SpeakerThem] != "Maria" {
		t.Fatalf("speakers.json = %+v, %v; want the far side still named Maria", st, err)
	}
	m := f.load(t, id)
	if m.Title != "Budget call" || m.VoiceMode != VoicesOffer || m.Status != StatusDone {
		t.Fatalf("manifest = %+v", m)
	}
	if tr := readFile(t, dir, TranscriptMD); !strings.Contains(tr, "**Maria**") || !strings.HasPrefix(tr, "# Budget call") {
		t.Errorf("transcript after the retry:\n%s", tr)
	}
}

// A meeting deleted while the sweep was about to retire its audio is nothing to do, not a warning.
func TestRetentionIgnoresAMeetingDeletedMeanwhile(t *testing.T) {
	f, id, _ := unavailableDone(t)
	var logs syncBuf
	f.logTo(&logs)
	f.r.beforeAudioDelete = func() {
		if err := f.r.Store.Delete(id); err != nil {
			t.Error(err)
		}
	}
	if n := f.r.SweepRetention(); n != 0 {
		t.Errorf("swept %d", n)
	}
	if strings.Contains(logs.String(), "could not be deleted") {
		t.Errorf("a meeting deleted meanwhile was logged as a failure:\n%s", logs.String())
	}
}
