package daemon

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// A notes server that keeps failing its key check is retried a few times and
// then given up on: /status reads "failed" with the cause and a plain reason,
// a call fails at once with the cause, and no further model load happens.
// (The meeting-level record of this error is TestUserRetryProbesOnce….)
// Mutation: internal/daemon/meetings.go notesStatus, delete the
// `out.State, out.LastErr = st.State, st.LastErr` line -> RED (/status says
// stopped with no error).
// Mutation: internal/daemon/meetings.go llmChat.Complete, wrap with
// errors.New("the notes model failed to start") (drop %w) -> RED (the
// runner's error hides the give-up).
func TestNotesGiveUpReachesStatusAndTheRunner(t *testing.T) {
	d, dir := startNotesFake(t)
	t.Setenv("OXSAY_FAKE_LLM_OPEN", "1")
	req := meeting.Request{System: "s", User: "u"}
	var err error
	for i := 0; i < 6; i++ {
		if _, err = (llmChat{d: d}).Complete(context.Background(), req); err != nil && strings.Contains(err.Error(), "gave up") {
			break
		}
	}
	if err == nil || !strings.Contains(err.Error(), "gave up") || !strings.Contains(err.Error(), "running open") {
		t.Fatalf("runner-visible error = %v, want the give-up and its cause", err)
	}
	n := d.Status().Notes
	if n.State != engine.StateFailed || n.LastErr == "" || !strings.Contains(n.Reason, "stopped retrying") ||
		n.ReasonCode != "notes_engine_failed" || n.RetryInS <= 0 {
		t.Fatalf("notes status = %+v, want state failed with last_error, reason, reason_code and retry_in_s", n)
	}
	if !n.Available {
		t.Fatalf("notes status = %+v: a failed engine is not 'unsupported'", n)
	}
	before := len(spawnStamps(t, dir))
	t0 := time.Now()
	if _, err := (llmChat{d: d}).Complete(context.Background(), req); err == nil || time.Since(t0) > 2*time.Second {
		t.Fatalf("a call in the failed state = %v after %s, want an immediate error", err, time.Since(t0))
	}
	if after := len(spawnStamps(t, dir)); after != before || before != 3 {
		t.Fatalf("spawns: %d then %d, want 3 and no more", before, after)
	}
}

func notesSettled(t *testing.T, d *Daemon, id string, spawns int, dir string) meeting.Manifest {
	t.Helper()
	var m *meeting.Manifest
	testutil.WaitFor(t, 15*time.Second, func() bool {
		var err error
		if m, err = d.Meet.Store.Load(id); err != nil {
			return false
		}
		return m.Status == meeting.StatusTranscribed && m.NotesPending == "failed" && len(spawnStamps(t, dir)) == spawns
	}, "the notes run to fail")
	return *m
}

// One notes run of a long transcript spends one strike, not one per chunk.
// Mutation: internal/meeting/notes.go Compose, skip the EngineDownError
// return -> RED (the second chunk starts the engine again: 2 spawns).
func TestOneNotesRunOfTwoChunksSpendsOneStrike(t *testing.T) {
	d, dir := startNotesFake(t)
	t.Setenv("OXSAY_FAKE_LLM_OPEN", "1")
	text := strings.Repeat("word ", meeting.ChunkChars/5*2)
	_, err := meeting.Composer{Chat: llmChat{d: d}}.Compose(context.Background(), text, meeting.Labels{}, "en")
	var down *meeting.EngineDownError
	if !errors.As(err, &down) || !strings.Contains(err.Error(), "running open") {
		t.Fatalf("compose err = %v, want the engine-down error with its cause", err)
	}
	if n := len(spawnStamps(t, dir)); n != 1 {
		t.Fatalf("spawns = %d, want exactly 1 for a 2-chunk run", n)
	}
}

// Through the runner: three failed notes runs give up; the user's Retry then
// gets exactly one probe start inside the cool-down, an automatic re-run and
// a direct engine call get none, and the meeting records the give-up.
// Mutation: internal/daemon/meetings_http.go handleMeetingNotes, delete the
// `d.LLMSup.AllowProbe()` call -> RED (the user's retry spawns nothing).
// Mutation: internal/daemon/meetings.go llmChat.Complete, call
// `c.d.LLMSup.AllowProbe()` before EnsureReady -> RED (the automatic re-run
// spawns: 4 starts where 3 are allowed).
func TestUserRetryProbesOnceAutomaticStaysBlocked(t *testing.T) {
	d, dir := startNotesFake(t)
	t.Setenv("OXSAY_FAKE_LLM_OPEN", "1")
	d.Meet.Chat = llmChat{d: d}
	mux := http.NewServeMux()
	d.Routes(mux)
	d.StartMeetings()
	id := finishedMeeting(t, d)

	m := notesSettled(t, d, id, 1, dir)
	if !strings.Contains(m.Error, "running open") {
		t.Fatalf("meeting error = %q, want the cause", m.Error)
	}
	userRetry := func() {
		t.Helper()
		if rec := call(t, mux, "POST", "/v1/meetings/"+id+"/notes", ""); rec.Code != http.StatusAccepted {
			t.Fatalf("retry = %d %s", rec.Code, rec.Body)
		}
	}
	userRetry()
	notesSettled(t, d, id, 2, dir)
	userRetry()
	notesSettled(t, d, id, 3, dir) // third strike: the engine gave up

	// An automatic re-run (what a speakers edit does) gets no probe.
	if _, err := d.Meet.Retry(id); err != nil {
		t.Fatal(err)
	}
	m = notesSettled(t, d, id, 3, dir)
	if !strings.Contains(m.Error, "gave up") {
		t.Fatalf("meeting error = %q, want the give-up recorded", m.Error)
	}
	// The user's Retry inside the cool-down: exactly one more start.
	userRetry()
	notesSettled(t, d, id, 4, dir)
	// Nothing else gets through.
	if _, err := d.LLMSup.EnsureReady(context.Background()); !errors.Is(err, engine.ErrGaveUp) {
		t.Fatalf("an automatic call after the probe = %v, want ErrGaveUp", err)
	}
	if n := len(spawnStamps(t, dir)); n != 4 {
		t.Fatalf("spawns = %d, want 4", n)
	}
}
