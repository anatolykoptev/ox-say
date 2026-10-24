package meeting

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// --- a failed meeting without a transcript keeps the only copy of what was said

// A meeting that never got a transcript keeps its audio however long it has
// been failed, until the user retries or deletes it.
// Mutation: internal/meeting/retention.go expired, re-add
// `case m.Status == StatusFailed && m.Attempts >= maxAutoRetries:` that sets
// `since` from Started/Ended -> RED (the audio is deleted).
func TestAFailedMeetingWithoutATranscriptKeepsItsAudio(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 20, 0, 5000, false)
	_, _ = f.r.Store.Update(id, func(m *Manifest) { m.Status, m.Attempts = StatusFailed, maxAutoRetries })
	f.now = t0.Add(400 * 24 * time.Hour)
	if n := f.r.SweepRetention(); n != 0 || !audioLeft(t, f, id) {
		t.Fatalf("swept %d; the only audio of a meeting without a transcript was deleted", n)
	}
	if f.load(t, id).AudioDeleted {
		t.Fatal("manifest says the audio is gone")
	}
}

// A transcript that cannot be read does not license deleting the audio.
// Mutation: internal/meeting/retention.go expired, replace
// `transcriptReadable(dir)` with `true` -> RED.
func TestACorruptTranscriptDoesNotLetTheAudioGo(t *testing.T) {
	f := newFixture(t)
	id := expiredMeeting(t, f)
	dir, _ := f.r.Store.Dir(id)
	if err := os.WriteFile(filepath.Join(dir, TranscriptJSON), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if n := f.r.SweepRetention(); n != 0 || !audioLeft(t, f, id) {
		t.Fatalf("swept %d; the audio went with an unreadable transcript", n)
	}
}

// --- a missing recognizer model waits, it does not spend the retries ----------

// A ModelError leaves the attempt count at zero across any number of Recover
// rounds, shows the meeting as waiting for the model, and the first Recover
// after the model is back brings it to done.
// Mutation: internal/meeting/runner.go retryFailed, replace
// `if !waiting { m.Attempts++ }` with `m.Attempts++` -> RED (Attempts is 1).
// Mutation: internal/meeting/runner.go stop, delete the
// `m.WaitingFor = WaitSTTModel` assignment -> RED (the meeting is not waiting).
func TestAMissingRecognizerModelWaitsInsteadOfSpendingRetries(t *testing.T) {
	f := newFixture(t)
	good := f.r.Transcribe
	var missing atomic.Bool
	missing.Store(true)
	f.r.Transcribe = func(ctx context.Context, wav string) (*stt.Result, error) {
		if missing.Load() {
			return nil, &stt.ModelError{}
		}
		return good(ctx, wav)
	}
	id := f.start(t, 20, 0, 5000, false)
	_ = f.r.Process(context.Background(), id)
	for range 2 * maxAutoRetries {
		f.r.Recover()
		_ = f.r.Process(context.Background(), id)
	}
	m := f.load(t, id)
	if m.Status != StatusFailed || m.Attempts != 0 || m.WaitingFor != WaitSTTModel {
		t.Fatalf("manifest = status %s, attempts %d, waiting %q; want failed, 0, %q", m.Status, m.Attempts, m.WaitingFor, WaitSTTModel)
	}
	if !audioLeft(t, f, id) {
		t.Fatal("audio deleted while waiting for the model")
	}
	missing.Store(false)
	f.r.Recover()
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if m := f.load(t, id); m.Status != StatusDone || m.WaitingFor != "" || m.Attempts != 0 {
		t.Fatalf("after the model came back: %+v", m)
	}
}

// A plain failure is not "waiting", and still spends the retries.
// Mutation: internal/meeting/runner.go stop, replace `permanent(err)` with
// `true` so every failure is "waiting" -> RED.
func TestAPlainFailureIsNotWaiting(t *testing.T) {
	f := newFixture(t)
	f.sleeps()
	f.r.Transcribe = func(context.Context, string) (*stt.Result, error) { return nil, errors.New("engine crashed") }
	id := f.start(t, 20, 0, 5000, false)
	_ = f.r.Process(context.Background(), id)
	f.r.Recover()
	if m := f.load(t, id); m.WaitingFor != "" || m.Attempts != 1 {
		t.Fatalf("manifest = %+v, want an ordinary failure that counts one attempt", m)
	}
}

// A manual Retry clears the waiting mark too.
// Mutation: internal/meeting/runner.go Retry, delete `m.WaitingFor = ""` -> RED.
func TestRetryClearsTheWaitingMark(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 20, 0, 5000, false)
	_, _ = f.r.Store.Update(id, func(m *Manifest) { m.Status, m.WaitingFor = StatusFailed, WaitSTTModel })
	m, err := f.r.Retry(id)
	if err != nil || m.WaitingFor != "" || m.Status != StatusQueued {
		t.Fatalf("Retry = %+v, %v", m, err)
	}
}

// --- a stale or corrupt transcript is not a place to resume ---------------------

// A meeting re-queued with a longer recording that then failed holds the old,
// shorter transcript: resuming at the notes would summarize the short one.
// Mutation: internal/meeting/runner.go resumeStatus, delete `&& !grewSince(dir, m)`
// -> RED (resumes at the notes).
func TestAStaleTranscriptIsTranscribedAgain(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 20, 20, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	writePCM(t, dir, MePCM, 90, 5000) // the app flushed the rest
	if _, err := f.r.Finish(id, t0.Add(3*time.Hour)); err != nil {
		t.Fatal(err)
	}
	_, _ = f.r.Store.Update(id, func(m *Manifest) { m.Status, m.Error = StatusFailed, "engine crashed" })
	m, err := f.r.Retry(id)
	if err != nil || m.Status != StatusQueued {
		t.Fatalf("Retry = %+v, %v; want queued (the transcript is shorter than the audio)", m, err)
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if got := f.load(t, id); got.Status != StatusDone || got.DurationS < 90 {
		t.Fatalf("after the retry: status %s, duration %v; want done over the whole recording", got.Status, got.DurationS)
	}
}

// ... and Recover's automatic retry judges it the same way.
func TestRecoverDoesNotResumeAtNotesOnAStaleTranscript(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 20, 20, 5000, false)
	_ = f.r.Process(context.Background(), id)
	dir, _ := f.r.Store.Dir(id)
	writePCM(t, dir, MePCM, 90, 5000)
	_, _ = f.r.Store.Update(id, func(m *Manifest) { m.Status = StatusFailed })
	f.r.Recover()
	if m := f.load(t, id); m.Status != StatusQueued {
		t.Fatalf("status = %s, want queued", m.Status)
	}
}

// A transcript.json that does not parse is no transcript.
// Mutation: internal/meeting/runner.go resumeStatus, replace
// `transcriptReadable(dir)` with a bare os.Stat of TranscriptJSON -> RED.
func TestACorruptTranscriptIsTranscribedAgain(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 20, 20, 5000, false)
	_ = f.r.Process(context.Background(), id)
	dir, _ := f.r.Store.Dir(id)
	if err := os.WriteFile(filepath.Join(dir, TranscriptJSON), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, _ = f.r.Store.Update(id, func(m *Manifest) { m.Status = StatusFailed })
	m, err := f.r.Retry(id)
	if err != nil || m.Status != StatusQueued {
		t.Fatalf("Retry = %+v, %v; want queued", m, err)
	}
}

// A transcription superseded by a later Finish writes no transcript at all: it
// is of the shorter recording, and the next round writes the real one.
// Mutation: internal/meeting/runner.go transcribe, delete the
// `if cur.Status != StatusTranscribing {` early return -> RED (transcript.json
// exists although the meeting is queued).
func TestASupersededTranscriptionWritesNothing(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 20, 20, 5000, false)
	good := f.r.Transcribe
	var once sync.Once
	f.r.Transcribe = func(ctx context.Context, wav string) (*stt.Result, error) {
		once.Do(func() {
			dir, _ := f.r.Store.Dir(id)
			writePCM(t, dir, MePCM, 90, 5000)
			if _, err := f.r.Finish(id, t0.Add(3*time.Hour)); err != nil {
				t.Error(err)
			}
		})
		return good(ctx, wav)
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	if m := f.load(t, id); m.Status != StatusQueued {
		t.Fatalf("status = %s, want queued", m.Status)
	}
	for _, name := range []string{TranscriptJSON, TranscriptMD} {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			t.Errorf("%s was written for a superseded transcription", name)
		}
	}
}

// --- a Finish landing while the notes start is not overwritten -------------------

// The window between reading the meeting and marking it summarizing: the model
// check runs there.
// Mutation: internal/meeting/runner.go summarize, delete the
// `if requeued(m) {` guard in the NotesReady update -> RED (it reads
// transcribed/model_missing, not queued); delete the one in the summarizing
// update -> RED (summarizing, then done on the short recording).
func TestAFinishBeforeTheNotesStartKeepsTheMeetingQueued(t *testing.T) {
	for _, tc := range []struct{ name, notes string }{{"model ready", ""}, {"model missing", "model_missing"}} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			id := f.start(t, 30, 30, 5000, false)
			var once sync.Once
			f.r.NotesReady = func() string {
				once.Do(func() {
					dir, _ := f.r.Store.Dir(id)
					writePCM(t, dir, MePCM, 90, 5000)
					if _, err := f.r.Finish(id, t0.Add(5*time.Hour)); err != nil {
						t.Error(err)
					}
				})
				return tc.notes
			}
			_ = f.r.Process(context.Background(), id)
			if m := f.load(t, id); m.Status != StatusQueued || m.NotesPending != "" {
				t.Fatalf("manifest = %+v, want queued for another round", m)
			}
		})
	}
}

// A notes write that fails after a Finish landed must not undo the re-queue.
// Mutation: internal/meeting/runner.go stopNotes, delete the
// `if requeued(m) { return }` guard -> RED (transcribed, notes failed).
func TestANotesFailureDoesNotUndoALaterFinish(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 30, 30, 5000, false)
	dir, _ := f.r.Store.Dir(id)
	if err := os.MkdirAll(filepath.Join(dir, NotesMD, "x"), 0o700); err != nil { // the notes cannot be written
		t.Fatal(err)
	}
	var once sync.Once
	f.r.Chat = chatHook{Chat: f.r.Chat, fn: func() {
		once.Do(func() {
			writePCM(t, dir, MePCM, 90, 5000)
			if _, err := f.r.Finish(id, t0.Add(5*time.Hour)); err != nil {
				t.Error(err)
			}
		})
	}}
	if err := f.r.Process(context.Background(), id); err == nil {
		t.Fatal("want the write failure")
	}
	if m := f.load(t, id); m.Status != StatusQueued {
		t.Fatalf("status = %s (pending %q), want queued", m.Status, m.NotesPending)
	}
}
