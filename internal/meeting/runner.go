package meeting

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/anatolykoptev/ox-say/internal/pcm"
	"github.com/anatolykoptev/ox-say/internal/stt"
	"github.com/anatolykoptev/ox-say/internal/voices"
	"github.com/anatolykoptev/ox-say/internal/vproject"
)

const (
	// minNotesWords: a transcript with fewer words is not sent to the model.
	minNotesWords = 25
	// staleRecording: a meeting still "recording" whose audio files have not
	// grown for this long lost its app (a crash, a kill): it is finished with
	// what reached the disk.
	// The daemon calls Housekeep at least every minute: staleRecording must stay
	// above twice that interval plus a flush, so a Mac sleep too short for the
	// wake detector (a gap over 2x the interval) cannot age a live recording
	// into staleness.
	staleRecording = 3 * time.Minute

	// A recognizer call that fails is tried pieceAttempts times in all, so one
	// hiccup (the engine restarting, a full queue) costs seconds, not the
	// meeting. A full queue waits busyWait; any other error backs off from
	// retryWait, doubling. No wait follows the last attempt.
	pieceAttempts = 4
	busyWait      = 5 * time.Second
	retryWait     = 2 * time.Second

	// maxAutoRetries bounds how often Recover puts a failed meeting back in
	// the queue on its own; Retry (the user) starts the count again.
	maxAutoRetries = 3
)

// retryBackoff is how long a failed meeting waits, by the number of automatic retries already spent, before Recover
// puts it back in the queue: a failure that is not instant to cure (an engine restarting, a full disk) gets time.
var retryBackoff = []time.Duration{time.Minute, 5 * time.Minute, 30 * time.Minute}

// Deps is everything the runner needs from outside. The daemon wires the
// real recognizer, model and dictation yield; tests wire fakes.
type Deps struct {
	Store *Store
	// Transcribe recognizes one 16 kHz mono WAV file.
	Transcribe func(ctx context.Context, wav string) (*stt.Result, error)
	Chat       Chat
	// NotesReady returns "" when the notes model can run, else the reason
	// code ("model_missing", "unsupported"); the transcript is then kept and
	// the notes wait.
	NotesReady func() string
	// TranscribeReady returns "" when the recognizer can run. While it
	// reports a reason a failed meeting waiting on the recognizer's model
	// (WaitingFor == WaitSTTModel) is left alone in Recover: re-queuing it
	// would fail it again at once, one wasted round-trip per housekeep
	// round. Nil: no gate.
	TranscribeReady func() string
	// Before runs ahead of every recognizer or model call; the daemon passes
	// the dictation yield. Nil: no waiting.
	Before func(ctx context.Context) error
	Now    func() time.Time
	// Sleep waits d or until ctx ends, returning ctx's error then.
	Sleep func(ctx context.Context, d time.Duration) error
	Log   *slog.Logger
	// PieceSeconds is the recognizer piece length; 0 means DefaultPieceSeconds.
	PieceSeconds int
	// Diarize runs the speaker diarizer on one 16 kHz mono s16le file (them.pcm)
	// and returns ox-diar's JSON. Nil: the far side keeps one label. It may leave the answer in work/ for the
	// length of the call (DiarizationJSON); it returns *DiarUnavailableError when the engine itself refused.
	Diarize func(ctx context.Context, pcm string) ([]byte, error)
	// DiarizeReady returns "" when Diarize can run on this Mac, else one of the DiarOSTooOld, DiarCPUUnsupported,
	// DiarEngineMissing, DiarModelsMissing codes: the meeting then gets one far-side label, WarnDiarUnavailable
	// and that reason, and the diarizer is not started.
	DiarizeReady func() string
}

// Runner takes finished meetings through transcription and notes, one at a
// time: the Mac runs one heavy model job at once.
type Runner struct {
	Deps
	mu      sync.Mutex
	pending map[string]bool
	order   []string
	running string          // the id Process is working on
	dirty   map[string]bool // queued again while running: run once more
	wokeAt  time.Time       // the last time Housekeep saw the Mac wake from sleep
	wake    chan struct{}

	retentionWarned bool // the unreadable-settings warning was logged

	speakerLocks keyedLocks // one speakers edit at a time per meeting
	// clearStale drops the notes-stale mark; nil is clearNotesStale (tests put a failure here).
	clearStale func(dir string, m Manifest, written *Notes) error
	// beforeRenameUpdate, when set, is called by Rename after its first status check and before the store update (tests).
	beforeRenameUpdate func()
	// beforeAudioDelete, when set, is called by the retention sweep after it judged a meeting expired and before it
	// takes the store lock to delete (tests make a retry land in that gap).
	beforeAudioDelete func()
}

// afterSpeakersRead is a test seam: when set, EditSpeakers and the notes writer's clear call it once they have read
// the speakers they will change. It is a package variable, not a Runner field, so a production Runner carries no
// test hook; only tests set it (setAfterSpeakersRead), and none of them runs in parallel.
var afterSpeakersRead func()

// NewRunner fills the defaults of d.
func NewRunner(d Deps) *Runner {
	if d.Now == nil {
		d.Now = time.Now
	}
	if d.Sleep == nil {
		d.Sleep = sleepCtx
	}
	if d.Log == nil {
		d.Log = slog.Default()
	}
	return &Runner{Deps: d, pending: map[string]bool{}, dirty: map[string]bool{}, wake: make(chan struct{}, 1)}
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// Enqueue schedules a meeting; a meeting already waiting in the queue is not
// queued twice. One being processed right now is run once more when it is
// done: whatever asked for it (a later Finish, a Retry) changed it after
// Process read it.
func (r *Runner) Enqueue(id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.pending[id] {
		if r.running == id {
			r.dirty[id] = true
		}
		return
	}
	r.pending[id] = true
	r.order = append(r.order, id)
	select {
	case r.wake <- struct{}{}:
	default:
	}
}

// Active is the number of meetings queued or running: /status reports it as
// busy work a daemon restart would interrupt.
func (r *Runner) Active() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.pending)
}

func (r *Runner) next() (string, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.order) == 0 {
		return "", false
	}
	id := r.order[0]
	r.order = r.order[1:]
	r.running = id
	return id, true
}

// Run processes the queue until ctx ends.
func (r *Runner) Run(ctx context.Context) {
	for {
		id, ok := r.next()
		if !ok {
			select {
			case <-ctx.Done():
				return
			case <-r.wake:
				continue
			}
		}
		if err := r.Process(ctx, id); err != nil && ctx.Err() == nil {
			r.Log.Warn("meeting: processing failed", slog.String("id", id), slog.Any("error", err))
		}
		r.mu.Lock()
		r.running = ""
		if r.dirty[id] {
			delete(r.dirty, id)
			r.order = append(r.order, id) // still pending: it goes round again
		} else {
			delete(r.pending, id)
		}
		r.mu.Unlock()
	}
}

// Finish ends a recording: it stamps the end time and queues the meeting.
// Calling it again changes nothing, with one exception: Recover may have
// finished the recording early (an app that looked dead, a Mac that slept),
// and the app's real, later end then arrives. A later end re-queues the
// meeting with it when the audio is longer than what was transcribed, so the
// tail is not lost.
func (r *Runner) Finish(id string, ended time.Time) (*Manifest, error) {
	dir, err := r.Store.Dir(id)
	if err != nil {
		return nil, err
	}
	m, err := r.Store.Update(id, func(m *Manifest) {
		switch {
		case m.Status == StatusRecording:
			m.Ended, m.Status = &ended, StatusQueued
		case m.Ended != nil && ended.After(*m.Ended) && grewSince(dir, m):
			m.Ended, m.Status, m.Error, m.NotesPending, m.FailReason = &ended, StatusQueued, "", "", ""
		}
	})
	if err != nil {
		return nil, err
	}
	r.Enqueue(id)
	return m, nil
}

// grewSince reports whether a meeting that is past recording needs its audio
// read again. One still waiting for its transcript always does; one with a
// transcript does when the files now hold more seconds than the transcript;
// that includes a failed one, whose transcript may be of a shorter recording.
func grewSince(dir string, m *Manifest) bool {
	switch m.Status {
	case StatusQueued, StatusTranscribing:
		return true
	case StatusTranscribed, StatusSummarizing, StatusDone, StatusFailed:
		return audioSeconds(dir) > m.DurationS+1
	}
	return false
}

func audioSeconds(dir string) float64 {
	var longest int64
	for _, name := range []string{MePCM, ThemPCM} {
		if st, err := os.Stat(filepath.Join(dir, name)); err == nil {
			longest = max(longest, st.Size())
		}
	}
	return float64(longest/bytesPerSample) / SampleRate
}

// Retry puts a meeting back to work from where it stopped. A failed one
// resumes at the notes when its transcript exists, else at the transcript
// (the pieces already recognized are not redone); a transcribed or done one
// writes its notes again. It also clears the automatic-retry count. This is
// what RetryNotes was: one entry point, because the user does not know (and
// should not need to) which step failed.
func (r *Runner) Retry(id string) (*Manifest, error) {
	dir, err := r.Store.Dir(id)
	if err != nil {
		return nil, err
	}
	var refuse error
	m, err := r.Store.Update(id, func(m *Manifest) {
		switch m.Status {
		case StatusFailed, StatusTranscribed, StatusDone:
		default:
			refuse = fmt.Errorf("meeting: %s cannot be retried while %s", id, m.Status)
			return
		}
		next, ok := resumeStatus(dir, m)
		if !ok {
			refuse = fmt.Errorf("meeting: %s has no transcript and its audio is gone", id)
			return
		}
		m.Status, m.NotesPending, m.Error, m.FailReason, m.Attempts, m.WaitingFor = next, "", "", "", 0, ""
	})
	if err != nil {
		return nil, err
	}
	if refuse != nil {
		return m, refuse
	}
	r.Enqueue(id)
	return m, nil
}

// RetryNotes is Retry under its first name.
func (r *Runner) RetryNotes(id string) (*Manifest, error) { return r.Retry(id) }

// resumeStatus is where a meeting that stopped goes next: the notes when a
// readable transcript is on disk and is not shorter than the audio (a stale one
// is of a recording that has since grown), the transcript while the audio is;
// false when neither is.
func resumeStatus(dir string, m *Manifest) (Status, bool) {
	if transcriptReadable(dir) && !grewSince(dir, m) {
		return StatusSummarizing, true
	}
	if m.AudioDeleted {
		return "", false
	}
	return StatusQueued, true
}

// ErrVoicesNotReady is what RetryVoices answers for a meeting whose voices are unavailable for a reason a retry can
// fix, while Deps.DiarizeReady still says this Mac cannot run the diarizer. Reason is DiarizeReady's code.
type ErrVoicesNotReady struct{ Reason string }

func (e *ErrVoicesNotReady) Error() string { return "meeting: voices are not ready: " + e.Reason }

// RetryVoices tells the far side's voices apart again for a meeting where the diarizer broke
// (WarnNoDiarization), or that was recorded while this Mac could not run it (WarnDiarUnavailable for a reason in
// retryableUnavailable) and now can (Deps.DiarizeReady, asked at this moment), and the far side's audio is still
// here: the meeting goes back to the transcript, and the notes follow from it. That is a full transcription (the
// pieces of the first pass are gone once a transcript stands, and the words are not kept), so it is its own call and
// Retry never makes it: the app calls Retry by itself, at launch, for a meeting waiting on the notes model, and that
// must stay a matter of notes. A fixable-but-not-yet-ready meeting is refused with *ErrVoicesNotReady.
func (r *Runner) RetryVoices(id string) (*Manifest, error) {
	dir, err := r.Store.Dir(id)
	if err != nil {
		return nil, err
	}
	notReady := r.diarNotReady()
	var refuse error
	m, err := r.Store.Update(id, func(m *Manifest) {
		switch m.Status {
		case StatusFailed, StatusTranscribed, StatusDone:
		default:
			refuse = fmt.Errorf("meeting: %s cannot be retried while %s", id, m.Status)
			return
		}
		if !wantsVoicesAgain(dir, m) {
			refuse = fmt.Errorf("meeting: %s has no failed diarization to retry, or its far-side audio is gone", id)
			return
		}
		if unavailableFixable(m) && notReady != "" {
			refuse = &ErrVoicesNotReady{Reason: notReady}
			return
		}
		m.Status, m.NotesPending, m.Error, m.FailReason, m.Attempts, m.WaitingFor = StatusQueued, "", "", "", 0, ""
	})
	if err != nil {
		return nil, err
	}
	if refuse != nil {
		return m, refuse
	}
	r.Enqueue(id)
	return m, nil
}

// diarNotReady is Deps.DiarizeReady's answer: "" when the diarizer can run now. Without a diarizer there is nothing
// to run, so that is not ready.
func (r *Runner) diarNotReady() string {
	if r.Diarize == nil {
		return DiarEngineMissing
	}
	if r.DiarizeReady == nil {
		return ""
	}
	return r.DiarizeReady()
}

// VoicesRetryable is whether a retry of m's voices would be accepted right now, for a meeting whose voices are
// unavailable or whose diarizer broke. It is what the served meeting reports as voices_retryable, so the app shows
// "Try Again" exactly when RetryVoices would take it (the app still keeps its own timeout rule for a failed run).
func (r *Runner) VoicesRetryable(m Manifest) bool { return r.VoicesRetryer()(m) }

// VoicesRetryer is VoicesRetryable for a list of meetings: the diarizer's readiness is asked at most once, on the
// first meeting whose answer depends on it, and that answer serves the rest of the list. A list is one moment.
func (r *Runner) VoicesRetryer() func(Manifest) bool {
	asked, notReady := false, ""
	return func(m Manifest) bool {
		if !slices.Contains(m.Warnings, WarnNoDiarization) && !unavailableFixable(&m) {
			return false
		}
		switch m.Status {
		case StatusFailed, StatusTranscribed, StatusDone:
		default:
			return false
		}
		// Readiness is asked only where RetryVoices asks it: an unavailable-and-fixable meeting. A run that broke is
		// retried whenever its audio is here.
		if unavailableFixable(&m) {
			if !asked {
				notReady, asked = r.diarNotReady(), true
			}
			if notReady != "" {
				return false
			}
		}
		dir, err := r.Store.Dir(m.ID)
		return err == nil && wantsVoicesAgain(dir, &m)
	}
}

// unavailableFixable: voices are unavailable for a reason that a later retry can fix.
func unavailableFixable(m *Manifest) bool {
	return slices.Contains(m.Warnings, WarnDiarUnavailable) && retryableUnavailable[m.DiarReason]
}

// channelLost: a channel file is missing (statErr is its Stat error) and that is a loss, not a side that never had
// audio: the meeting records its audio as deleted, or did not record this channel as silent (silent is
// WarnNoMicAudio / WarnNoSystemAudio) when it was transcribed. keepFinishedWithoutAudio and wantsVoicesAgain share
// it, so a retry is offered exactly where the transcription would not bounce it.
func channelLost(statErr error, m *Manifest, silent string) bool {
	return errors.Is(statErr, os.ErrNotExist) && (m.AudioDeleted || !slices.Contains(m.Warnings, silent))
}

// wantsVoicesAgain: the diarizer broke on this meeting, or could not run and may now, and there is far-side audio to
// try again on, and the mic side is not half-deleted. Whether it may run now is the caller's question (RetryVoices asks
// Deps.DiarizeReady).
func wantsVoicesAgain(dir string, m *Manifest) bool {
	if !slices.Contains(m.Warnings, WarnNoDiarization) && !unavailableFixable(m) {
		return false
	}
	if _, err := os.Stat(filepath.Join(dir, ThemPCM)); err != nil {
		return false
	}
	// An external half deletion (the mic file gone, the far side left) over a finished transcript is bounced by
	// keepFinishedWithoutAudio, so the retry would be accepted and then do nothing: it is not offered. A mic recorded
	// as silent never had a file; with no transcript yet the run goes on and reads the missing mic as silence.
	_, err := os.Stat(filepath.Join(dir, MePCM))
	return !(transcriptReadable(dir) && channelLost(err, m, WarnNoMicAudio))
}

// Recover queues every meeting a stopped daemon left half done, puts failed
// ones back (at most maxAutoRetries times each) and finishes the recordings
// whose app is gone. Call it once at start, then from Housekeep.
func (r *Runner) Recover() { r.recoverAt(r.Now()) }

// recoverAt is Recover judging staleness at now. Housekeep passes the instant
// it measured the sleep gap at, so a sleep that begins after that measurement
// cannot make a live recording look stale within the same round.
func (r *Runner) recoverAt(now time.Time) {
	list, err := r.Store.List()
	if err != nil {
		r.Log.Warn("meeting: cannot list meetings", slog.Any("error", err))
		return
	}
	for _, m := range list {
		switch m.Status {
		case StatusQueued, StatusTranscribing, StatusSummarizing:
			r.Enqueue(m.ID)
		case StatusRecording:
			r.finishIfStale(m, now)
		case StatusFailed:
			r.retryFailed(m)
		}
	}
}

// retryFailed puts one failed meeting back in the queue, counting the attempt
// in the manifest so a meeting that always fails is not retried forever. A
// meeting waiting for the recognizer's model is put back on every round without
// counting — but only once the model is there: while TranscribeReady reports
// it missing the meeting is left alone, or every round would re-queue it just
// to fail again at once. No number of retries is the wrong number once the
// model is installed.
func (r *Runner) retryFailed(m Manifest) {
	if m.WaitingFor == WaitSTTModel && r.TranscribeReady != nil && r.TranscribeReady() != "" {
		return
	}
	dir, err := r.Store.Dir(m.ID)
	if err != nil {
		return
	}
	queued := false
	if _, err := r.Store.Update(m.ID, func(m *Manifest) {
		next, ok := resumeStatus(dir, m)
		waiting := m.WaitingFor != ""
		if m.Status != StatusFailed || (m.Attempts >= maxAutoRetries && !waiting) || !ok {
			return
		}
		if !waiting && m.FailedAt != nil && r.Now().Sub(*m.FailedAt) < retryBackoff[min(m.Attempts, len(retryBackoff)-1)] {
			return
		}
		m.Status, m.Error, m.FailReason, m.WaitingFor = next, "", "", ""
		if !waiting {
			m.Attempts++
		}
		queued = true
	}); err != nil {
		r.Log.Warn("meeting: cannot retry a failed meeting", slog.String("id", m.ID), slog.Any("error", err))
		return
	}
	if queued {
		r.Enqueue(m.ID)
	}
}

func (r *Runner) finishIfStale(m Manifest, now time.Time) {
	dir, err := r.Store.Dir(m.ID)
	if err != nil {
		return
	}
	last := m.Started
	for _, name := range []string{MePCM, ThemPCM, ManifestFile} {
		if st, err := os.Stat(filepath.Join(dir, name)); err == nil && st.ModTime().After(last) {
			last = st.ModTime()
		}
	}
	// A recording whose files look old may only have slept with the Mac: its
	// app was suspended too and writes again within moments. Staleness counts
	// from the wake, not from the last write before it.
	r.mu.Lock()
	if r.wokeAt.After(last) {
		last = r.wokeAt
	}
	r.mu.Unlock()
	if now.Sub(last) < staleRecording {
		return
	}
	if _, err := r.Finish(m.ID, last); err != nil {
		r.Log.Warn("meeting: cannot finish an orphaned recording", slog.String("id", m.ID), slog.Any("error", err))
	}
}

// Housekeep runs Recover and the retention sweep every interval until ctx
// ends. It reads the wall clock between rounds: a gap of more than twice the
// interval means the Mac slept, and recordings are not judged orphaned until
// they have been quiet for staleRecording after the wake.
func (r *Runner) Housekeep(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	// Round(0) drops the monotonic reading: on macOS it stands still while the
	// Mac sleeps, which is exactly the gap this looks for.
	last := r.Now().Round(0)
	for {
		now := r.Now().Round(0)
		if gap := now.Sub(last); gap > 2*every {
			r.mu.Lock()
			r.wokeAt = now
			r.mu.Unlock()
			r.Log.Info("meeting: the Mac slept; recordings are judged from now", slog.Duration("gap", gap))
		}
		last = now
		r.recoverAt(now)
		if n := r.SweepRetention(); n > 0 {
			r.Log.Info("meeting: retention sweep", slog.Int("meetings", n))
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Process runs the meeting's remaining steps. A daemon shutdown (ctx) leaves
// the meeting where it was, so the next start resumes it. A transcription
// failure marks it failed with the reason and keeps its audio; a notes failure
// that is not the model's refusal (the disk) leaves the transcript standing
// and the notes pending.
func (r *Runner) Process(ctx context.Context, id string) error {
	m, err := r.Store.Load(id)
	if errors.Is(err, ErrNotFound) {
		return nil // deleted while queued
	}
	if err != nil {
		return err
	}
	if m.Status == StatusQueued || m.Status == StatusTranscribing {
		if err := r.transcribe(ctx, id); err != nil {
			return r.stop(ctx, id, err)
		}
		m, err = r.Store.Load(id)
		if errors.Is(err, ErrNotFound) {
			return nil
		}
		if err != nil {
			return err
		}
		if m.Status != StatusTranscribed {
			return nil // a later Finish queued it again: it runs once more
		}
	} else if m.Status != StatusSummarizing {
		return nil
	}
	if err := r.summarize(ctx, id); err != nil {
		if errors.Is(err, errNoTranscript) {
			return r.stop(ctx, id, err)
		}
		return r.stopNotes(ctx, id, err)
	}
	return nil
}

func (r *Runner) stop(ctx context.Context, id string, err error) error {
	if ctx.Err() != nil || errors.Is(err, ErrNotFound) {
		return err
	}
	failedAt := r.Now()
	_, uerr := r.Store.Update(id, func(m *Manifest) {
		if m.Status == StatusQueued { // a Finish queued the meeting again while this run failed: that run counts
			return
		}
		m.markFailed(err, &failedAt)
		if permanent(err) {
			m.WaitingFor = WaitSTTModel
		}
	})
	if uerr != nil {
		r.Log.Warn("meeting: cannot record a failure", slog.String("id", id), slog.Any("error", uerr))
	}
	return err
}

// stopNotes records a notes step that failed on the disk, not on the model:
// the transcript stays, the meeting reads "transcribed, notes failed" exactly
// like a model failure, and Retry writes the notes again.
func (r *Runner) stopNotes(ctx context.Context, id string, err error) error {
	if ctx.Err() != nil || errors.Is(err, ErrNotFound) {
		return err
	}
	_, uerr := r.Store.Update(id, func(m *Manifest) {
		if requeued(m) {
			return
		}
		m.markNotesFailed(err)
	})
	if uerr != nil {
		r.Log.Warn("meeting: cannot record a notes failure", slog.String("id", id), slog.Any("error", uerr))
	}
	return err
}

// errNoTranscript: the notes step found no readable transcript.json, so the
// meeting goes back to failed and Retry transcribes it again.
var errNoTranscript = errors.New("meeting: no transcript to summarize")

type channel struct {
	file  string
	label string
}

var channels = []channel{{MePCM, SpeakerMe}, {ThemPCM, SpeakerThem}}

// transcribe recognizes both channels piece by piece, caching each piece so a
// restart resumes where it stopped, then merges them into the transcript.
func (r *Runner) transcribe(ctx context.Context, id string) error {
	dir, err := r.Store.Dir(id)
	if err != nil {
		return err
	}
	if kept, err := r.keepFinishedWithoutAudio(id, dir); kept || err != nil {
		return err
	}
	m, err := r.Store.Update(id, func(m *Manifest) { m.Status = StatusTranscribing })
	if err != nil {
		return err
	}
	work := filepath.Join(dir, WorkDir)
	if err := os.MkdirAll(work, 0o700); err != nil {
		return err
	}
	// A crash mid-recognition leaves its clip behind: audio of the meeting
	// outside the files retention knows about.
	stale, _ := filepath.Glob(filepath.Join(work, "*.wav"))
	for _, f := range stale {
		_ = os.Remove(f)
	}
	words := map[string][]stt.Word{}
	var warnings []string
	var seconds float64
	for _, ch := range channels {
		w, speech, secs, err := r.channelWords(ctx, dir, ch)
		if err != nil {
			return err
		}
		words[ch.label] = w
		seconds = max(seconds, secs)
		if !speech {
			warnings = append(warnings, map[string]string{SpeakerMe: WarnNoMicAudio, SpeakerThem: WarnNoSystemAudio}[ch.label])
		}
	}
	turns := MergeTurns(words[SpeakerMe], words[SpeakerThem])
	dropped := 0
	if m.EchoRisk {
		var kept []Turn
		kept, dropped = DropEcho(turns)
		if dropped > 0 {
			// Keep the turns as they were before the drop: a turn wrongly
			// judged an echo can be put back from this file.
			raw, err := json.MarshalIndent(turns, "", " ")
			if err != nil {
				return err
			}
			if err := vproject.WriteAtomic(filepath.Join(dir, RawTranscriptJSON), raw, 0o600); err != nil {
				return err
			}
			warnings = append(warnings, WarnEchoDropped)
		}
		turns = kept
	}
	// The far side's voices, told apart after the echo gate: that gate measures
	// whole channel turns, and voice turns sit edge to edge.
	vr, err := r.voices(ctx, dir, words[SpeakerThem])
	if err != nil {
		return err
	}
	if vr.warn != "" {
		warnings = append(warnings, vr.warn)
	}
	if vr.mode != "" {
		turns = SplitByVoice(turns, vr.of)
	}
	var spoken strings.Builder // the words only: speaker names would count as Latin letters
	for _, t := range turns {
		spoken.WriteString(t.Text)
		spoken.WriteByte(' ')
	}
	// lang is "" when the speech does not say clearly: the notes then follow
	// the transcript's own language (see languageRule) under English headings.
	lang := voices.Language(spoken.String())
	script := voices.Script(spoken.String())
	// The recognizer reads 25 European languages; speech in another script
	// comes out as a transliteration. Say so instead of summarizing nonsense.
	if script == "" && WordCount(turns) >= minNotesWords {
		warnings = append(warnings, WarnLanguage)
	}
	// A Finish that queued the meeting again while it ran makes these turns
	// those of the shorter recording: write nothing, the next round does.
	if cur, err := r.Store.Load(id); err != nil {
		return err
	} else if cur.Status != StatusTranscribing {
		return nil
	}
	raw, err := json.MarshalIndent(turns, "", " ")
	if err != nil {
		return err
	}
	if err := vproject.WriteAtomic(filepath.Join(dir, TranscriptJSON), raw, 0o600); err != nil {
		return err
	}
	shown := *m
	shown.VoiceMode, shown.Voices = vr.mode, vr.voices
	st, err := LoadSpeakers(dir)
	if err != nil {
		return err
	}
	shown, display := Present(shown, st, turns)
	if err := vproject.WriteAtomic(filepath.Join(dir, TranscriptMD), []byte(TranscriptMarkdown(shown, display)), 0o600); err != nil {
		return err
	}
	superseded := false
	if _, err = r.Store.Update(id, func(m *Manifest) {
		if m.Status != StatusTranscribing {
			superseded = true // a later Finish queued it again while it ran
			return
		}
		m.Status, m.Language, m.DurationS, m.Warnings, m.EchoDropped = StatusTranscribed, lang, seconds, warnings, dropped
		m.VoiceMode, m.Voices, m.DiarReason = vr.mode, vr.voices, vr.reason
	}); err != nil {
		return err
	}
	if !superseded {
		// transcript.json holds everything the notes need. The piece caches
		// only serve a resumed transcription, and they are the transcript's
		// words a second time: nothing of the audio's text stays behind in
		// work/ once the meeting has moved past this step.
		_ = os.RemoveAll(work)
	}
	return nil
}

// keepFinishedWithoutAudio stops a transcription that is missing part of its recording from blanking (or halving) a
// meeting that already has a transcript. A missing channel file reads as a silent one (a capture that heard
// nothing), so without this a queued run over deleted audio would overwrite transcript.json with an empty one, and
// over a half-deleted pair (one file left by a crash or a failed unlink) with one that lacks a side's turns. The
// transcript, the notes and the speakers stay as they are; the meeting goes back to done (or to transcribed when it
// never got notes, and the run then goes on to write them) with AudioDeleted set when no channel file remains (else the retention sweep finishes the removal), and no failure is recorded: the
// meeting did not fail, it just cannot be transcribed again. The reason is in the log.
//
// A channel counts as gone when its file is missing and the meeting either records its audio as deleted or did not
// record that channel as silent when it was transcribed (WarnNoMicAudio / WarnNoSystemAudio): a side that never
// had audio is not a loss. kept is false, with no error, for every meeting this does not concern.
func (r *Runner) keepFinishedWithoutAudio(id, dir string) (kept bool, err error) {
	if !transcriptReadable(dir) {
		return false, nil
	}
	m, err := r.Store.Load(id)
	if err != nil {
		return false, err
	}
	gone, left := false, false // a channel lost, and a channel file still here
	for _, ch := range []struct{ file, silent string }{{MePCM, WarnNoMicAudio}, {ThemPCM, WarnNoSystemAudio}} {
		_, err := os.Stat(filepath.Join(dir, ch.file))
		if err == nil {
			left = true
		}
		if channelLost(err, m, ch.silent) {
			gone = true
		}
	}
	if !gone {
		return false, nil // present, or never there, or unknowable: transcribe as asked
	}
	notes, _ := os.ReadFile(filepath.Join(dir, NotesMD))
	_, err = r.Store.Update(id, func(m *Manifest) {
		m.Status = StatusTranscribed
		if len(notes) > 0 {
			m.Status = StatusDone
		}
		// Only when nothing of the recording is left: a surviving file must stay visible to the retention sweep
		// (expired is false for a meeting marked deleted), or it would outlive the user's retention period.
		m.AudioDeleted = !left
		m.Error, m.FailReason = "", ""
	})
	if err != nil {
		return false, err
	}
	r.Log.Warn("meeting: a queued transcription found the recording incomplete; kept the transcript and notes", slog.String("id", id))
	return true, nil
}

// channelWords recognizes one channel file. speech is false when the file is
// missing, empty or silent throughout — the sign of a capture that heard nothing.
func (r *Runner) channelWords(ctx context.Context, dir string, ch channel) (words []stt.Word, speech bool, seconds float64, err error) {
	f, err := os.Open(filepath.Join(dir, ch.file))
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, 0, nil
	}
	if err != nil {
		return nil, false, 0, err
	}
	defer func() { _ = f.Close() }()
	st, err := f.Stat()
	if err != nil {
		return nil, false, 0, err
	}
	spans, err := Spans(f, st.Size(), r.PieceSeconds)
	if err != nil {
		return nil, false, 0, err
	}
	for _, sp := range spans {
		w, loud, err := r.pieceWords(ctx, dir, f, ch, sp)
		if err != nil {
			return nil, false, 0, err
		}
		words = append(words, w...)
		speech = speech || loud
	}
	return words, speech, float64(st.Size()/bytesPerSample) / SampleRate, nil
}

// pieceCache is one recognized piece on disk: the words, and whether the
// audio held speech at all. A loud piece can yield no words (music, a cough);
// caching only the words would read it back as silence on a resume and warn
// about a channel that actually spoke.
type pieceCache struct {
	Words []stt.Word `json:"words"`
	Loud  bool       `json:"loud"`
}

func (r *Runner) pieceWords(ctx context.Context, dir string, f io.ReaderAt, ch channel, sp Span) ([]stt.Word, bool, error) {
	cache := filepath.Join(dir, WorkDir, fmt.Sprintf("%s-%d-%d.json", ch.label, sp.From, sp.To))
	if raw, err := os.ReadFile(cache); err == nil {
		var pc pieceCache
		if json.Unmarshal(raw, &pc) == nil {
			return pc.Words, pc.Loud, nil
		}
	}
	clip, err := ReadClip(f, sp)
	if err != nil {
		return nil, false, err
	}
	var words []stt.Word
	loud := !Silent(clip)
	if loud {
		if words, err = r.recognize(ctx, dir, ch, sp, clip); err != nil {
			return nil, false, err
		}
	}
	raw, _ := json.Marshal(pieceCache{Words: words, Loud: loud})
	if err := vproject.WriteAtomic(cache, raw, 0o600); err != nil {
		return nil, false, err
	}
	return words, loud, nil
}

func (r *Runner) recognize(ctx context.Context, dir string, ch channel, sp Span, clip pcm.Clip) ([]stt.Word, error) {
	wav := filepath.Join(dir, WorkDir, fmt.Sprintf("%s-%d.wav", ch.label, sp.From))
	if err := os.WriteFile(wav, clip.Encode(), 0o600); err != nil {
		return nil, err
	}
	defer func() { _ = os.Remove(wav) }()
	res, err := r.transcribePiece(ctx, wav)
	if err != nil {
		return nil, err
	}
	offset := float64(sp.From) / SampleRate
	out := make([]stt.Word, len(res.Words))
	for i, w := range res.Words {
		w.S += offset
		w.E += offset
		out[i] = w
	}
	return out, nil
}

// transcribePiece is one recognizer call with its retries. A daemon shutdown
// and a missing model are not retried; everything else (the engine restarting,
// a full queue, a timeout) gets pieceAttempts tries, with the dictation yield
// ahead of each and a wait between, but none after the last.
func (r *Runner) transcribePiece(ctx context.Context, wav string) (*stt.Result, error) {
	for attempt := 1; ; attempt++ {
		if r.Before != nil {
			if err := r.Before(ctx); err != nil {
				return nil, err
			}
		}
		res, err := r.Transcribe(ctx, wav)
		if err == nil && res == nil {
			err = errors.New("meeting: the recognizer returned no result")
		}
		if err == nil {
			return res, nil
		}
		if ctx.Err() != nil || permanent(err) || attempt >= pieceAttempts {
			return nil, err
		}
		wait := retryWait << (attempt - 1)
		if errors.Is(err, stt.ErrBusy) {
			wait = busyWait
		}
		if serr := r.Sleep(ctx, wait); serr != nil {
			return nil, serr
		}
	}
}

// permanent reports an error a retry cannot cure.
func permanent(err error) bool {
	var model *stt.ModelError
	return errors.As(err, &model)
}

// summarize writes the notes, or leaves the transcript waiting for them.
func (r *Runner) summarize(ctx context.Context, id string) error {
	m, err := r.Store.Load(id)
	if err != nil {
		return err
	}
	dir, err := r.Store.Dir(id)
	if err != nil {
		return err
	}
	var turns []Turn
	raw, err := os.ReadFile(filepath.Join(dir, TranscriptJSON))
	if err == nil {
		err = json.Unmarshal(raw, &turns)
	}
	if err != nil {
		return fmt.Errorf("%w: %w", errNoTranscript, err)
	}
	if WordCount(turns) < minNotesWords {
		return r.writeNotes(id, dir, ShortNotesMarkdown(*m, m.Language), nil)
	}
	if r.NotesReady != nil {
		if code := r.NotesReady(); code != "" {
			_, err := r.Store.Update(id, func(m *Manifest) {
				if requeued(m) {
					return
				}
				m.Status, m.NotesPending = StatusTranscribed, code
			})
			return err
		}
	}
	// A Finish may have queued the meeting again since it was read: these
	// notes would be of the shorter recording, and the next round starts over.
	superseded := false
	if _, err := r.Store.Update(id, func(m *Manifest) {
		if requeued(m) {
			superseded = true
			return
		}
		m.Status, m.NotesPending, m.Error, m.FailReason = StatusSummarizing, "", "", ""
	}); err != nil {
		return err
	}
	if superseded {
		return nil
	}
	st, err := LoadSpeakers(dir)
	if err != nil {
		return err
	}
	shown, display := Present(*m, st, turns)
	notes, err := Composer{Chat: r.Chat, Before: r.Before, Log: r.Log}.Compose(ctx, PromptText(shown, display), shown.Labels, m.Language)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		_, uerr := r.Store.Update(id, func(m *Manifest) {
			if requeued(m) {
				return
			}
			m.markNotesFailed(err)
		})
		return uerr
	}
	notes.Labels = labelMap(*m, st, turns)
	return r.writeNotes(id, dir, NotesMarkdown(*m, notes, m.Language), &notes)
}

func (r *Runner) writeNotes(id, dir, md string, n *Notes) error {
	if n != nil {
		raw, err := json.MarshalIndent(n, "", " ")
		if err != nil {
			return err
		}
		if err := vproject.WriteAtomic(filepath.Join(dir, NotesJSON), raw, 0o600); err != nil {
			return err
		}
	}
	if err := vproject.WriteAtomic(filepath.Join(dir, NotesMD), []byte(md), 0o600); err != nil {
		return err
	}
	m, err := r.Store.Update(id, func(m *Manifest) {
		if requeued(m) {
			return
		}
		m.Status, m.NotesPending, m.Error, m.FailReason, m.Attempts = StatusDone, "", "", "", 0
	})
	if err != nil {
		return err
	}
	// After the status: the notes are written and the meeting is done whatever becomes of the mark. A mark that
	// stays only makes the next speakers edit queue the notes again.
	clear := r.clearStale
	if clear == nil {
		clear = r.clearNotesStale
	}
	// Under the meeting's speakers lock: the meeting is done, so a speakers edit may be running, and the clear
	// reads speakers.json and saves it whole. No caller of writeNotes holds the lock (only EditSpeakers takes it, and
	// it does not write notes).
	unlock := r.speakerLocks.lock(id)
	cerr := clear(dir, *m, n)
	unlock()
	if cerr != nil {
		r.Log.Warn("meeting: cannot drop the notes-stale mark", slog.String("id", id), slog.Any("error", cerr))
	}
	return nil
}

// requeued reports a meeting a later Finish sent back to the start while its
// notes were being written: those notes are of the shorter recording, and the
// meeting must stay queued so the next round redoes it.
func requeued(m *Manifest) bool {
	return m.Status == StatusQueued || m.Status == StatusTranscribing
}

// keyedLocks is a mutex per key that exists only while somebody holds or awaits it.
type keyedLocks struct {
	mu sync.Mutex
	m  map[string]*keyedLock
}

type keyedLock struct {
	mu   sync.Mutex
	refs int
}

// lock takes the key's lock and returns the function that releases it.
func (k *keyedLocks) lock(key string) (unlock func()) {
	k.mu.Lock()
	if k.m == nil {
		k.m = map[string]*keyedLock{}
	}
	l := k.m[key]
	if l == nil {
		l = &keyedLock{}
		k.m[key] = l
	}
	l.refs++
	k.mu.Unlock()
	l.mu.Lock()
	return func() {
		l.mu.Unlock()
		k.mu.Lock()
		if l.refs--; l.refs == 0 {
			delete(k.m, key)
		}
		k.mu.Unlock()
	}
}

// size is the number of keys with a lock (tests).
func (k *keyedLocks) size() int {
	k.mu.Lock()
	defer k.mu.Unlock()
	return len(k.m)
}
