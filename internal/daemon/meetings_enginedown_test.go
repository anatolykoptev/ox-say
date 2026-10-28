package daemon

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// A notes server that fails its key check shows in /status as "failed" with
// the cause, a reason_code and a plain reason; the next successful start
// clears all of it.
// Mutation: internal/daemon/meetings.go notesStatus, delete the
// `out.State, out.LastErr = st.State, st.LastErr` line -> RED.
// Mutation: same function, make the StateFailed block `if false` -> RED.
func TestNotesVerifyFailureShowsInStatusAndClears(t *testing.T) {
	d, _ := startNotesFake(t)
	t.Setenv("OXSAY_FAKE_LLM_OPEN", "1")
	req := meeting.Request{System: "s", User: "u"}
	_, err := (llmChat{d: d}).Complete(context.Background(), req)
	var down *meeting.EngineDownError
	if !errors.As(err, &down) || !strings.Contains(err.Error(), "running open") {
		t.Fatalf("err = %v, want the engine-down error with its cause", err)
	}
	n := d.Status().Notes
	if n.State != engine.StateFailed || n.LastErr == "" || n.ReasonCode != "notes_engine_failed" ||
		!strings.Contains(n.Reason, "Retry the notes") || !n.Available {
		t.Fatalf("notes status = %+v, want failed with last_error, reason_code and reason", n)
	}
	t.Setenv("OXSAY_FAKE_LLM_OPEN", "") // the server now requires its key
	if out, err := (llmChat{d: d}).Complete(context.Background(), req); err != nil || out == "" {
		t.Fatalf("a retry after the cause is gone = %q, %v", out, err)
	}
	if n := d.Status().Notes; n.State != engine.StateReady || n.LastErr != "" || n.Reason != "" || n.ReasonCode != "" {
		t.Fatalf("notes status = %+v, want ready with the failure cleared", n)
	}
}

func notesSettled(t *testing.T, d *Daemon, id string, spawns int, dir string) meeting.Manifest {
	t.Helper()
	var m *meeting.Manifest
	testutil.WaitFor(t, 20*time.Second, func() bool {
		var err error
		if m, err = d.Meet.Store.Load(id); err != nil {
			return false
		}
		return m.Status == meeting.StatusTranscribed && m.NotesPending == "failed" && len(spawnStamps(t, dir)) == spawns
	}, "the notes run to fail")
	return *m
}

// One notes run of a long transcript costs one start, not one per chunk and
// attempt.
// Mutation: internal/meeting/notes.go Compose, skip the EngineDownError
// return -> RED (the second chunk starts the engine again).
// A verify refusal repeats, so it is never retried: 1 spawn per run.
func TestOneNotesRunOfTwoChunksCostsOneStart(t *testing.T) {
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

// Through the runner, against a server that never verifies: N notes runs make
// exactly N starts (no multiplier), and the user's Retry always gets a real
// start — nothing blocks it beyond the short backoff (at most 30 s).
// Mutation: internal/engine/supervisor.go EnsureReady, refuse the start when
// s.state == StateFailed -> RED (the second run spawns nothing).
func TestEveryNotesRunGetsExactlyOneRealStart(t *testing.T) {
	d, dir := startNotesFake(t)
	t.Setenv("OXSAY_FAKE_LLM_OPEN", "1")
	d.Meet.Chat = llmChat{d: d}
	mux := http.NewServeMux()
	d.Routes(mux)
	d.StartMeetings()
	id := finishedMeeting(t, d)
	for run := 1; run <= 4; run++ {
		if run > 1 {
			if rec := call(t, mux, "POST", "/v1/meetings/"+id+"/notes", ""); rec.Code != http.StatusAccepted {
				t.Fatalf("retry = %d %s", rec.Code, rec.Body)
			}
		}
		m := notesSettled(t, d, id, run, dir)
		if !strings.Contains(m.Error, "running open") {
			t.Fatalf("run %d: meeting error = %q, want the cause", run, m.Error)
		}
	}
}

// notesCold gives the daemon a notes supervisor whose health wait is short, so
// a fake that never becomes healthy times out in well under a second.
func notesCold(t *testing.T, d *Daemon, neverHealthy int) {
	t.Helper()
	t.Setenv("OXSAY_FAKE_LLM_LOADING_SPAWNS", strconv.Itoa(neverHealthy))
	t.Setenv("OXSAY_FAKE_LLM_JSON", `{"summary":"A planning call.","decisions":["Ship Friday"],"action_items":[],"open_questions":[],"numbers":[]}`)
	cfg := notesEngineConfig(d.Cfg, d.log)
	cfg.StartupTimeout, cfg.KillGrace = 600*time.Millisecond, 2*time.Second
	sup, err := engine.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	d.LLMSup.Shutdown()
	d.LLMSup = sup
	t.Cleanup(sup.Shutdown)
}

// A cold start that times out on health gets exactly one more start in the
// same run (the second load is from the page cache), and the notes are written.
// Mutation: internal/daemon/meetings.go llmChat.Complete, `Retryable:` set to
// false -> RED (one spawn, no notes).
func TestAColdStartTimeoutGetsOneMoreStartInTheSameRun(t *testing.T) {
	d, dir := startNotesFake(t)
	notesCold(t, d, 1)
	n, err := meeting.Composer{Chat: llmChat{d: d}}.Compose(context.Background(), "hello there everyone", meeting.Labels{}, "en")
	if err != nil || n.Summary == "" {
		t.Fatalf("notes = %+v, err = %v, want notes after the second start", n, err)
	}
	if got := len(spawnStamps(t, dir)); got != 2 {
		t.Fatalf("spawns = %d, want 2", got)
	}
}

// A server that times out twice stops the run after exactly 2 starts, with
// the cause, even for a transcript of several chunks.
// Mutation: internal/meeting/notes.go Compose, disable the EngineDownError
// return -> RED (the second chunk starts the engine again: 3 spawns).
func TestAColdStartThatTimesOutTwiceStopsTheRunAfterTwoStarts(t *testing.T) {
	d, dir := startNotesFake(t)
	notesCold(t, d, 9)
	text := strings.Repeat("word ", meeting.ChunkChars/5*2)
	_, err := meeting.Composer{Chat: llmChat{d: d}}.Compose(context.Background(), text, meeting.Labels{}, "en")
	var down *meeting.EngineDownError
	if !errors.As(err, &down) || !strings.Contains(err.Error(), "healthy") {
		t.Fatalf("err = %v, want the engine-down error naming the health timeout", err)
	}
	if got := len(spawnStamps(t, dir)); got != 2 {
		t.Fatalf("spawns = %d, want 2", got)
	}
}
