package meeting

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// clock is a settable clock safe to read from the Housekeep goroutine.
type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) Now() time.Time  { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) Set(t time.Time) { c.mu.Lock(); c.t = t; c.mu.Unlock() }

// syncBuf is a log sink safe to write from the Housekeep goroutine.
type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.b.Write(p) }
func (s *syncBuf) String() string              { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

func (r *Runner) wokeAtTime() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.wokeAt
}

func (f *fixture) logTo(buf *syncBuf) {
	f.r.Log = slog.New(slog.NewTextHandler(buf, &slog.HandlerOptions{Level: slog.LevelDebug}))
}

// sleeps records the waits the runner asked for.
func (f *fixture) sleeps() *[]time.Duration {
	var got []time.Duration
	f.r.Sleep = func(_ context.Context, d time.Duration) error { got = append(got, d); return nil }
	return &got
}

// poll waits up to 3 s for cond.
func poll(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func old(t *testing.T, dir string, at time.Time) {
	t.Helper()
	for _, name := range []string{MePCM, ThemPCM, ManifestFile} {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			_ = os.Chtimes(filepath.Join(dir, name), at, at)
		}
	}
}

// --- 1. one recognizer hiccup must not fail the meeting ---------------------

// Piece 2 of 3 fails once with a plain error and then recognizes: the meeting
// finishes, after one backoff wait.
// Mutation: internal/meeting/runner.go transcribePiece, change
// `attempt >= pieceAttempts` to `attempt >= 1` -> RED (the first hiccup fails
// the meeting).
func TestATransientErrorOnOnePieceIsRetried(t *testing.T) {
	f := newFixture(t)
	waits := f.sleeps()
	good := f.r.Transcribe
	var failed bool
	f.r.Transcribe = func(ctx context.Context, wav string) (*stt.Result, error) {
		if f.calls.Load() == 1 && !failed { // the second piece, first try
			failed = true
			return nil, errors.New("engine restarting")
		}
		return good(ctx, wav)
	}
	id := f.start(t, 600, 0, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatalf("Process = %v, want the retry to absorb the hiccup", err)
	}
	if m := f.load(t, id); m.Status != StatusDone {
		t.Fatalf("status = %s (%s), want done", m.Status, m.Error)
	}
	if len(*waits) != 1 || (*waits)[0] != retryWait {
		t.Fatalf("waits = %v, want one backoff of %v", *waits, retryWait)
	}
}

// A full queue is waited out for busyWait and tried again.
// Mutation: internal/meeting/runner.go transcribePiece, delete the
// `if errors.Is(err, stt.ErrBusy) {` block -> RED (the wait is the shorter
// backoff); change `attempt >= pieceAttempts` to `attempt >= 1` -> RED.
func TestBusyIsRetriedAfterBusyWait(t *testing.T) {
	f := newFixture(t)
	waits := f.sleeps()
	good := f.r.Transcribe
	var busy atomic.Bool
	f.r.Transcribe = func(ctx context.Context, wav string) (*stt.Result, error) {
		if busy.CompareAndSwap(false, true) {
			return nil, stt.ErrBusy
		}
		return good(ctx, wav)
	}
	id := f.start(t, 20, 0, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if m := f.load(t, id); m.Status != StatusDone {
		t.Fatalf("status = %s (%s)", m.Status, m.Error)
	}
	if len(*waits) != 1 || (*waits)[0] != busyWait {
		t.Fatalf("waits = %v, want [%v]", *waits, busyWait)
	}
}

// A recognizer that never recovers fails the meeting after pieceAttempts
// tries, with a wait between tries and none after the last.
// Mutation: internal/meeting/runner.go transcribePiece, change
// `attempt >= pieceAttempts` to `attempt > pieceAttempts` -> RED (one try too
// many, and a pointless final wait).
func TestRetriesAreBoundedAndNoWaitFollowsTheLastTry(t *testing.T) {
	f := newFixture(t)
	waits := f.sleeps()
	f.r.Transcribe = func(context.Context, string) (*stt.Result, error) {
		f.calls.Add(1)
		return nil, errors.New("engine crashed")
	}
	id := f.start(t, 20, 0, 5000, false)
	if err := f.r.Process(context.Background(), id); err == nil {
		t.Fatal("want the failure")
	}
	if got := f.calls.Load(); got != pieceAttempts {
		t.Fatalf("recognizer calls = %d, want %d", got, pieceAttempts)
	}
	if len(*waits) != pieceAttempts-1 || (*waits)[0] != retryWait || (*waits)[1] != 2*retryWait {
		t.Fatalf("waits = %v, want %d doubling waits from %v", *waits, pieceAttempts-1, retryWait)
	}
	if m := f.load(t, id); m.Status != StatusFailed {
		t.Fatalf("status = %s", m.Status)
	}
}

// A missing model cannot be cured by waiting.
// Mutation: internal/meeting/runner.go transcribePiece, delete `|| permanent(err)`
// -> RED (three pointless retries).
func TestAMissingModelIsNotRetried(t *testing.T) {
	f := newFixture(t)
	waits := f.sleeps()
	f.r.Transcribe = func(context.Context, string) (*stt.Result, error) {
		f.calls.Add(1)
		return nil, &stt.ModelError{}
	}
	id := f.start(t, 20, 0, 5000, false)
	_ = f.r.Process(context.Background(), id)
	if f.calls.Load() != 1 || len(*waits) != 0 {
		t.Fatalf("calls = %d, waits = %v; want one call and no waiting", f.calls.Load(), *waits)
	}
}

// A shutdown during the backoff wait ends the job at once and leaves the
// meeting resumable, not failed.
// Mutation: internal/meeting/runner.go transcribePiece, replace
// `if serr := r.Sleep(ctx, wait); serr != nil {` with `_ = r.Sleep(ctx, wait); if false {`
// -> RED (the loop keeps calling the recognizer after the shutdown... and the
// meeting is failed).
func TestShutdownDuringBackoffLeavesTheMeetingResumable(t *testing.T) {
	f := newFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	f.r.Sleep = func(ctx context.Context, _ time.Duration) error { cancel(); return ctx.Err() }
	f.r.Transcribe = func(context.Context, string) (*stt.Result, error) {
		f.calls.Add(1)
		return nil, errors.New("engine restarting")
	}
	id := f.start(t, 20, 0, 5000, false)
	_ = f.r.Process(ctx, id)
	if f.calls.Load() != 1 {
		t.Fatalf("calls = %d, want 1", f.calls.Load())
	}
	if m := f.load(t, id); m.Status != StatusTranscribing {
		t.Fatalf("status = %s, want transcribing (resumable)", m.Status)
	}
}

// A recognizer that answers with neither words nor an error is an error.
// Mutation: internal/meeting/runner.go transcribePiece, delete the
// `err == nil && res == nil` block -> RED (a nil pointer panic).
func TestANilResultIsAnErrorNotAPanic(t *testing.T) {
	f := newFixture(t)
	f.sleeps()
	f.r.Transcribe = func(context.Context, string) (*stt.Result, error) { return nil, nil }
	id := f.start(t, 20, 0, 5000, false)
	if err := f.r.Process(context.Background(), id); err == nil {
		t.Fatal("want an error")
	}
	if m := f.load(t, id); m.Status != StatusFailed {
		t.Fatalf("status = %s", m.Status)
	}
}

// --- 5. ungated call sites ---------------------------------------------------

// The dictation yield runs ahead of every recognizer call, retries included:
// a dictation never waits behind a meeting piece.
// Mutation: internal/meeting/runner.go transcribePiece, delete the
// `if r.Before != nil {` block -> RED.
func TestTheDictationYieldRunsBeforeEveryRecognizerCall(t *testing.T) {
	f := newFixture(t)
	f.sleeps()
	var before atomic.Int32
	f.r.Before = func(context.Context) error { before.Add(1); return nil }
	good := f.r.Transcribe
	var failed atomic.Bool
	f.r.Transcribe = func(ctx context.Context, wav string) (*stt.Result, error) {
		if got, calls := before.Load(), f.calls.Load(); got < calls+1 {
			t.Errorf("call %d came after only %d yields", calls+1, got)
		}
		if f.calls.Load() == 1 && failed.CompareAndSwap(false, true) {
			f.calls.Add(1)
			return nil, errors.New("hiccup")
		}
		return good(ctx, wav)
	}
	id := f.start(t, 600, 0, 5000, false) // three pieces, one retried
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if got := before.Load(); got < 4 {
		t.Fatalf("yields = %d, want one per recognizer call (4)", got)
	}
}

// A yield that fails (a daemon shutdown) stops the job before the recognizer.
func TestAFailingYieldStopsBeforeTheRecognizer(t *testing.T) {
	f := newFixture(t)
	f.r.Before = func(context.Context) error { return errors.New("yield refused") }
	id := f.start(t, 20, 0, 5000, false)
	_ = f.r.Process(context.Background(), id)
	if f.calls.Load() != 0 {
		t.Fatalf("the recognizer ran %d times after a refused yield", f.calls.Load())
	}
}

// --- 1b/1c. un-failing -------------------------------------------------------

func failedMeetingWithTranscript(t *testing.T, f *fixture) string {
	t.Helper()
	id := f.start(t, 20, 20, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if _, err := f.r.Store.Update(id, func(m *Manifest) { m.Status, m.Error = StatusFailed, "disk hiccup" }); err != nil {
		t.Fatal(err)
	}
	return id
}

// Retry resumes a failed meeting at the notes when the transcript exists.
// Mutation: internal/meeting/runner.go resumeStatus, make the first `if`
// condition `false` -> RED (the meeting is transcribed from scratch).
func TestRetryOfAFailedMeetingWithATranscriptWritesTheNotesOnly(t *testing.T) {
	f := newFixture(t)
	id := failedMeetingWithTranscript(t, f)
	before := f.calls.Load()
	m, err := f.r.Retry(id)
	if err != nil || m.Status != StatusSummarizing || m.Error != "" {
		t.Fatalf("Retry = %+v, %v; want summarizing", m, err)
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if got := f.load(t, id); got.Status != StatusDone {
		t.Fatalf("status = %s", got.Status)
	}
	if f.calls.Load() != before {
		t.Fatal("the recognizer ran again for a meeting that already had its transcript")
	}
}

// Without a transcript a failed meeting goes back to the start.
func TestRetryOfAFailedMeetingWithoutATranscriptTranscribesAgain(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 20, 20, 5000, false)
	_, _ = f.r.Store.Update(id, func(m *Manifest) { m.Status, m.Error, m.Attempts = StatusFailed, "engine crashed", 2 })
	m, err := f.r.Retry(id)
	if err != nil || m.Status != StatusQueued || m.Attempts != 0 {
		t.Fatalf("Retry = %+v, %v; want queued with the attempt count cleared", m, err)
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if got := f.load(t, id); got.Status != StatusDone {
		t.Fatalf("status = %s", got.Status)
	}
}

func TestRetryRefusesWhatCannotBeRetried(t *testing.T) {
	f := newFixture(t)
	rec, _, _ := f.r.Store.Create(Manifest{}, t0)
	if _, err := f.r.Retry(rec.ID); err == nil {
		t.Error("a recording cannot be retried")
	}
	gone := f.start(t, 20, 20, 5000, false)
	_, _ = f.r.Store.Update(gone, func(m *Manifest) { m.Status, m.AudioDeleted = StatusFailed, true })
	if _, err := f.r.Retry(gone); err == nil {
		t.Error("no transcript and no audio: nothing to retry")
	}
	if m := f.load(t, gone); m.Status != StatusFailed {
		t.Errorf("a refused retry changed the status to %s", m.Status)
	}
}

// RetryNotes keeps working for a done or transcribed meeting.
func TestRetryNotesStillRewritesTheNotes(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 20, 20, 5000, false)
	_ = f.r.Process(context.Background(), id)
	if m, err := f.r.RetryNotes(id); err != nil || m.Status != StatusSummarizing {
		t.Fatalf("RetryNotes = %+v, %v", m, err)
	}
}

// Recover puts a failed meeting back at most maxAutoRetries times and counts
// each in the manifest; a restart of the daemon does not reset the count.
// Mutation: internal/meeting/runner.go retryFailed, delete
// `m.Attempts >= maxAutoRetries ||` from the Update guard -> RED (a meeting that always fails is retried for ever).
func TestRecoverRetriesFailedMeetingsABoundedNumberOfTimes(t *testing.T) {
	f := newFixture(t)
	f.sleeps()
	f.r.Transcribe = func(context.Context, string) (*stt.Result, error) {
		f.calls.Add(1)
		return nil, errors.New("engine crashed")
	}
	id := f.start(t, 20, 0, 5000, false)
	_ = f.r.Process(context.Background(), id) // fails: the original run
	for range 6 {
		f.r.Recover()
		_ = f.r.Process(context.Background(), id)
	}
	m := f.load(t, id)
	if m.Status != StatusFailed || m.Attempts != maxAutoRetries {
		t.Fatalf("manifest = status %s, attempts %d; want failed after %d retries", m.Status, m.Attempts, maxAutoRetries)
	}
	if want := int32((1 + maxAutoRetries) * pieceAttempts); f.calls.Load() != want {
		t.Fatalf("recognizer calls = %d, want %d", f.calls.Load(), want)
	}
}

// A hiccup that outlasts the in-piece retries is cured by the next Recover.
func TestRecoverBringsAFailedMeetingToDone(t *testing.T) {
	f := newFixture(t)
	f.sleeps()
	good := f.r.Transcribe
	var down atomic.Bool
	down.Store(true)
	f.r.Transcribe = func(ctx context.Context, wav string) (*stt.Result, error) {
		if down.Load() {
			return nil, errors.New("engine down")
		}
		return good(ctx, wav)
	}
	id := f.start(t, 20, 0, 5000, false)
	_ = f.r.Process(context.Background(), id)
	down.Store(false)
	f.r = NewRunner(f.r.Deps) // the daemon restarted
	f.r.Recover()
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if m := f.load(t, id); m.Status != StatusDone || m.Attempts != 0 {
		t.Fatalf("manifest = %+v, want done with the attempt count cleared", m)
	}
}

// Notes that cannot be written (the disk) leave the transcript standing: the
// meeting reads "transcribed, notes failed", not "failed", and Retry finishes it.
// Mutation: internal/meeting/runner.go Process, replace `return r.stopNotes(ctx, id, err)`
// with `return r.stop(ctx, id, err)` -> RED (the meeting is marked failed).
func TestANotesWriteFailureKeepsTheTranscriptState(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 30, 30, 5000, false)
	dir, _ := f.r.Store.Dir(id)
	block := filepath.Join(dir, NotesMD) // a non-empty directory where the file goes
	if err := os.MkdirAll(filepath.Join(block, "x"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := f.r.Process(context.Background(), id); err == nil {
		t.Fatal("want the write failure")
	}
	m := f.load(t, id)
	if m.Status != StatusTranscribed || m.NotesPending != "failed" || m.Error == "" {
		t.Fatalf("manifest = %+v, want transcribed with the notes pending (failed)", m)
	}
	if _, err := os.Stat(filepath.Join(dir, TranscriptJSON)); err != nil {
		t.Fatal("the transcript must survive")
	}
	_ = os.RemoveAll(block)
	if _, err := f.r.Retry(id); err != nil {
		t.Fatal(err)
	}
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if got := f.load(t, id); got.Status != StatusDone {
		t.Fatalf("after the disk recovered: %+v", got)
	}
}

// --- 2. language -------------------------------------------------------------

// The meeting's language is read from what was said, and the notes prompt
// names it.
// Mutation: internal/meeting/runner.go transcribe, replace
// `lang := voices.Language(spoken.String())` with `lang := "en"` -> RED.
func TestTheMeetingLanguageComesFromTheSpeech(t *testing.T) {
	for _, tc := range []struct{ name, text, want, prompt string }{
		{"german", "Danke dass ihr alle heute dabei seid, wir gehen jetzt den Plan und die offenen Fragen durch und dann sprechen wir noch über das Budget für das nächste Quartal mit dem ganzen Team.", "de", "German"},
		{"ukrainian", "Дякую всім, що прийшли сьогодні, зараз ми пройдемося по плану і по відкритих питаннях, а потім поговоримо про бюджет на наступний квартал разом з усією командою.", "uk", "Ukrainian"},
		{"russian", "Спасибо всем, что пришли сегодня, сейчас мы пройдёмся по плану и по открытым вопросам, а потом поговорим про бюджет на следующий квартал вместе со всей командой.", "ru", "Russian"},
		{"unclear", "Благодаря на всички, че дойдохте днес, сега ще разгледаме плана и отворените въпроси, а после ще говорим за бюджета за следващото тримесечие с целия екип.", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			f.r.Transcribe = func(context.Context, string) (*stt.Result, error) {
				return &stt.Result{Words: words(1, tc.text)}, nil
			}
			id := f.start(t, 20, 0, 5000, false)
			if err := f.r.Process(context.Background(), id); err != nil {
				t.Fatal(err)
			}
			m := f.load(t, id)
			if m.Language != tc.want || m.Status != StatusDone {
				t.Fatalf("language = %q, status = %s; want %q, done", m.Language, m.Status, tc.want)
			}
			sys := f.r.Chat.(*fakeChat).reqs[0].System
			if tc.prompt != "" && !strings.Contains(sys, "Write every field in "+tc.prompt+".") {
				t.Errorf("the prompt does not name %s:\n%s", tc.prompt, sys)
			}
			if tc.prompt == "" && !strings.Contains(sys, "same language as the transcript") {
				t.Errorf("an unclear language must keep the generic rule:\n%s", sys)
			}
		})
	}
}

// --- 4. sleep-safe recovery --------------------------------------------------

func orphanRecording(t *testing.T, f *fixture, started, lastWrite time.Time) string {
	t.Helper()
	m, dir, err := f.r.Store.Create(Manifest{}, started)
	if err != nil {
		t.Fatal(err)
	}
	writePCM(t, dir, MePCM, 10, 5000)
	old(t, dir, lastWrite)
	return m.ID
}

// After a sleep, a live recording whose files look hours old is left alone:
// its app was suspended with the Mac and writes again within moments.
// Mutation: internal/meeting/runner.go finishIfStale, delete the
// `if r.wokeAt.After(last) { last = r.wokeAt }` block -> RED (the recording is
// cut on the first tick after the wake).
func TestAMacSleepDoesNotMakeALiveRecordingLookOrphaned(t *testing.T) {
	f := newFixture(t)
	clk := &clock{t: f.now}
	f.r.Now = clk.Now
	live := orphanRecording(t, f, f.now.Add(-time.Hour), f.now.Add(-time.Minute))

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { f.r.Housekeep(ctx, 5*time.Millisecond); close(done) }()
	time.Sleep(60 * time.Millisecond) // many ordinary rounds: the recording is fresh
	if f.load(t, live).Status != StatusRecording {
		t.Fatal("a recording written a minute ago was finished")
	}

	woke := f.now.Add(time.Hour) // the Mac slept for an hour
	clk.Set(woke)
	poll(t, "the wake to be noticed", func() bool { return f.r.wokeAtTime().Equal(woke) })
	time.Sleep(60 * time.Millisecond) // more rounds, with the stale-looking files
	cancel()
	<-done
	if m := f.load(t, live); m.Status != StatusRecording {
		t.Fatalf("status = %s: a recording that only slept was finished", m.Status)
	}

	// Quiet for staleRecording after the wake: now it is an orphan, and its
	// end is the wake, not a time inside the sleep.
	clk.Set(woke.Add(staleRecording + time.Second))
	f.r.Recover()
	if m := f.load(t, live); m.Status != StatusQueued || m.Ended == nil || !m.Ended.Equal(woke) {
		t.Fatalf("manifest = %+v, want queued, ended at the wake", m)
	}
}

// ... and one whose app wrote after the wake stays live.
func TestARecordingThatWritesAfterTheWakeStaysLive(t *testing.T) {
	f := newFixture(t)
	clk := &clock{t: f.now}
	f.r.Now = clk.Now
	live := orphanRecording(t, f, f.now.Add(-time.Hour), f.now.Add(-time.Minute))
	woke := f.now.Add(time.Hour)
	f.r.mu.Lock()
	f.r.wokeAt = woke
	f.r.mu.Unlock()
	clk.Set(woke.Add(10 * time.Minute))
	dir, _ := f.r.Store.Dir(live)
	old(t, dir, woke.Add(9*time.Minute+30*time.Second)) // the app wrote 30 s ago
	f.r.Recover()
	if m := f.load(t, live); m.Status != StatusRecording {
		t.Fatalf("status = %s, want recording", m.Status)
	}
}

// The app's real end, later than the one Recover guessed, is not dropped.
// Mutation: internal/meeting/runner.go Finish, delete the second `case` of the
// switch -> RED (the tail of the recording is never transcribed).
func TestALaterFinishRequeuesAMeetingRecoverEndedEarly(t *testing.T) {
	f := newFixture(t)
	orphan := orphanRecording(t, f, t0, t0.Add(time.Minute))
	f.r.Recover()
	early := f.load(t, orphan)
	if early.Status != StatusQueued {
		t.Fatalf("setup: status = %s", early.Status)
	}
	real := t0.Add(30 * time.Minute)
	if _, err := f.r.Finish(orphan, real); err != nil {
		t.Fatal(err)
	}
	if m := f.load(t, orphan); m.Ended == nil || !m.Ended.Equal(real) || m.Status != StatusQueued {
		t.Fatalf("manifest = %+v, want the real end", m)
	}
	// An earlier or equal end changes nothing.
	if _, err := f.r.Finish(orphan, t0.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if m := f.load(t, orphan); !m.Ended.Equal(real) {
		t.Fatalf("an earlier end replaced the later one: %v", m.Ended)
	}
}

// A meeting already transcribed is re-queued only when its audio is longer
// than its transcript: a repeated Finish call is not a reason to start over.
// Mutation: internal/meeting/runner.go grewSince, replace
// `audioSeconds(dir) > m.DurationS+1` with `true` -> RED.
func TestALaterFinishOfATranscribedMeetingNeedsLongerAudio(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 20, 20, 5000, false)
	_ = f.r.Process(context.Background(), id)
	later := t0.Add(3 * time.Hour)
	if _, err := f.r.Finish(id, later); err != nil {
		t.Fatal(err)
	}
	if m := f.load(t, id); m.Status != StatusDone {
		t.Fatalf("status = %s: same audio, nothing new to transcribe", m.Status)
	}
	dir, _ := f.r.Store.Dir(id)
	writePCM(t, dir, MePCM, 60, 5000) // the app flushed the rest
	if _, err := f.r.Finish(id, later.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if m := f.load(t, id); m.Status != StatusQueued || !m.Ended.Equal(later.Add(time.Minute)) {
		t.Fatalf("manifest = %+v, want queued with the new end", m)
	}
}

// A meeting queued again while it runs goes round once more: otherwise a
// Finish that arrives mid-transcription is lost.
// Mutation: internal/meeting/runner.go Run, replace `if r.dirty[id] {` with
// `if false {` -> RED (the meeting is left queued, never processed again).
func TestAMeetingQueuedWhileRunningRunsAgain(t *testing.T) {
	f := newFixture(t)
	orphan := orphanRecording(t, f, t0, t0.Add(time.Minute))
	f.r.Recover() // queued, ended early
	real := t0.Add(30 * time.Minute)
	good := f.r.Transcribe
	var once sync.Once
	f.r.Transcribe = func(ctx context.Context, wav string) (*stt.Result, error) {
		once.Do(func() { // the app's real Finish arrives mid-transcription
			if _, err := f.r.Finish(orphan, real); err != nil {
				t.Error(err)
			}
		})
		return good(ctx, wav)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { f.r.Run(ctx); close(done) }()
	poll(t, "the meeting to be done after the second round", func() bool {
		m := f.load(t, orphan)
		return m.Status == StatusDone && f.r.Active() == 0
	})
	cancel()
	<-done
	if m := f.load(t, orphan); m.Ended == nil || !m.Ended.Equal(real) {
		t.Fatalf("ended = %v, want the real end", m.Ended)
	}
}

// --- 5a. Housekeep -----------------------------------------------------------

// Every round runs Recover and the retention sweep, and says what it deleted
// (a count and an id, never text).
// Mutation: internal/meeting/runner.go Housekeep, delete `r.Recover()` -> RED
// (the orphan stays recording); delete the `r.SweepRetention()` call (keep
// `n := 0`) -> RED (the audio stays).
func TestHousekeepRecoversAndSweepsOnEveryRound(t *testing.T) {
	f := newFixture(t)
	clk := &clock{t: f.now}
	f.r.Now = clk.Now
	var logs syncBuf
	f.logTo(&logs)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { f.r.Housekeep(ctx, 5*time.Millisecond); close(done) }()
	time.Sleep(40 * time.Millisecond) // the first rounds find nothing

	// Work that appears after the first rounds is found by a later round.
	orphan := orphanRecording(t, f, t0, t0.Add(time.Minute))
	expired := f.start(t, 20, 20, 5000, false)
	_ = f.r.Process(context.Background(), expired)
	end := f.now.Add(-40 * 24 * time.Hour)
	_, _ = f.r.Store.Update(expired, func(m *Manifest) { m.Ended = &end })

	poll(t, "Recover to finish the orphan", func() bool { return f.load(t, orphan).Status != StatusRecording })
	poll(t, "the sweep to delete the audio", func() bool { return f.load(t, expired).AudioDeleted })
	cancel()
	<-done
	got := logs.String()
	if !strings.Contains(got, "retention sweep") || !strings.Contains(got, "meetings=1") {
		t.Errorf("the sweep did not log its count:\n%s", got)
	}
	if strings.Contains(got, "thanks everyone") {
		t.Errorf("transcript text reached the log:\n%s", got)
	}
}

// --- 7. nothing private left behind ------------------------------------------

// Once the transcript is written the work directory goes: the piece caches
// hold the transcript's words a second time.
// Mutation: internal/meeting/runner.go transcribe, delete
// `_ = os.RemoveAll(work)` -> RED.
func TestWorkDirectoryIsGoneOnceTheTranscriptIsWritten(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 600, 0, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	if _, err := os.Stat(filepath.Join(dir, WorkDir)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("work/ survived a finished transcription: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, TranscriptJSON)); err != nil {
		t.Fatal("the transcript is the one thing that must stay")
	}
}

// A clip a crash left in work/ is audio outside the files retention deletes by
// name: the next run clears it.
// Mutation: internal/meeting/runner.go transcribe, delete the `stale, _ :=
// filepath.Glob(...)` loop -> RED.
func TestStaleClipsAreClearedWhenTranscriptionStarts(t *testing.T) {
	f := newFixture(t)
	f.sleeps()
	f.r.Transcribe = func(context.Context, string) (*stt.Result, error) { return nil, errors.New("engine crashed") }
	id := f.start(t, 20, 0, 5000, false)
	dir, _ := f.r.Store.Dir(id)
	_ = os.MkdirAll(filepath.Join(dir, WorkDir), 0o700)
	leftover := filepath.Join(dir, WorkDir, "me-999.wav")
	if err := os.WriteFile(leftover, []byte("RIFF"), 0o600); err != nil {
		t.Fatal(err)
	}
	_ = f.r.Process(context.Background(), id) // fails, so work/ stays
	if _, err := os.Stat(leftover); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the stale clip survived: %v", err)
	}
}

// chatHook runs fn before answering, as the app's Finish arriving mid-notes.
type chatHook struct {
	Chat
	fn func()
}

func (c chatHook) Complete(ctx context.Context, r Request) (string, error) {
	c.fn()
	return c.Chat.Complete(ctx, r)
}

// A Finish with more audio that arrives while the notes are being written must
// not be overwritten by "done": those notes are of the shorter recording.
// Mutation: internal/meeting/runner.go writeNotes, delete the
// `if requeued(m) { return }` guard -> RED (done, with notes missing the tail).
func TestALaterFinishDuringTheNotesIsNotOverwrittenByDone(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 30, 30, 5000, false)
	var once sync.Once
	f.r.Chat = chatHook{Chat: f.r.Chat, fn: func() {
		once.Do(func() {
			dir, _ := f.r.Store.Dir(id)
			writePCM(t, dir, MePCM, 90, 5000)
			if _, err := f.r.Finish(id, t0.Add(5*time.Hour)); err != nil {
				t.Error(err)
			}
		})
	}}
	_ = f.r.Process(context.Background(), id)
	if m := f.load(t, id); m.Status != StatusQueued {
		t.Fatalf("status = %s, want queued for another round", m.Status)
	}
}
