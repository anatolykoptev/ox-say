package daemon

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/meeting"
)

func shortNotesCallTimeout(t *testing.T) {
	t.Helper()
	keep := notesCallTimeout
	notesCallTimeout = 100 * time.Millisecond
	t.Cleanup(func() { notesCallTimeout = keep })
}

// A model call that outlives its own per-call deadline while the server still answers /health is the "answer too
// long for this Mac" class: llmChat wraps it in the typed mark the meeting package splits on, over the real
// ox-llm wiring — spawn, key, health and all.
// Mutation: internal/daemon/meetings.go llmChat.Complete, return the raw error instead of the
// AnswerTimeoutError -> RED (errors.As finds no *meeting.AnswerTimeoutError).
func TestACallTimeoutOnALiveEngineIsMarkedTooLong(t *testing.T) {
	d, _ := startNotesFake(t)
	t.Setenv("OXSAY_FAKE_LLM_HANG_MS", "30000") // answers long after the caller's deadline; /health stays instant
	shortNotesCallTimeout(t)
	_, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"})
	var overtime *meeting.AnswerTimeoutError
	if !errors.As(err, &overtime) {
		t.Fatalf("err = %v (%T), want the too-long mark the meeting splits on", err, err)
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want it to stay a deadline error underneath", err)
	}
}

// The same deadline on a server that is NOT producing — its /health hangs too — is engine-down, never the
// too-long mark: a hung call must not be split into halves that each burn the whole deadline.
// Mutation: internal/daemon/meetings.go llmChat.Complete, mark the deadline too-long without probing the
// engine's health -> RED (the too-long mark shows instead of engine-down).
func TestACallTimeoutOnAHungEngineIsEngineDown(t *testing.T) {
	d, _ := startNotesFake(t)
	t.Setenv("OXSAY_FAKE_LLM_HANG_MS", "30000")
	t.Setenv("OXSAY_FAKE_LLM_HEALTH_HANG_AFTER", "1") // the start's health wait passes; the probe's hangs
	shortNotesCallTimeout(t)
	keep := notesAliveProbe
	notesAliveProbe = 100 * time.Millisecond
	t.Cleanup(func() { notesAliveProbe = keep })
	_, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"})
	var overtime *meeting.AnswerTimeoutError
	if errors.As(err, &overtime) {
		t.Fatalf("err = %v, a hung engine must never carry the too-long mark", err)
	}
	var down *meeting.EngineDownError
	if !errors.As(err, &down) || down.Reason != meeting.FailNotesEngineTimeout {
		t.Fatalf("err = %v (%T), want the engine-down error with %s", err, err, meeting.FailNotesEngineTimeout)
	}
}

// A generation wedged so its HTTP loop still answers is engine-down, not
// "too long": /slots shows a slot claiming to process while its decode
// counter does not move between two reads. And a retry that re-asked the
// same wedged process would just fail again — the daemon stops the child,
// so the retry Compose makes lands on a fresh spawn.
// Mutation: internal/daemon/meetings.go llmChat.Complete, return the
// AnswerTimeoutError without the progress probe -> RED (the wedge is split,
// not restarted); drop the Stop -> RED (the second call's spawn count
// stays 1).
func TestAComputeWedgedEngineIsDownAndRestarted(t *testing.T) {
	d, dir := startNotesFake(t)
	t.Setenv("OXSAY_FAKE_LLM_HANG_MS", "30000") // the request outlives the caller's deadline
	t.Setenv("OXSAY_FAKE_LLM_SLOTS_STALL", "1") // and its decode never moves: a compute wedge
	shortNotesCallTimeout(t)
	keep := notesAliveProbe
	notesAliveProbe = 100 * time.Millisecond
	t.Cleanup(func() { notesAliveProbe = keep })
	keepGap := notesProgressProbe
	notesProgressProbe = 10 * time.Millisecond
	t.Cleanup(func() { notesProgressProbe = keepGap })
	_, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"})
	var down *meeting.EngineDownError
	if !errors.As(err, &down) || down.Reason != meeting.FailNotesEngineTimeout {
		t.Fatalf("err = %v (%T), want the engine-down error with %s", err, err, meeting.FailNotesEngineTimeout)
	}
	if !down.Retryable {
		t.Fatal("the wedge should spend the run's one restart, not kill it")
	}
	t.Setenv("OXSAY_FAKE_LLM_SLOTS_STALL", "")
	t.Setenv("OXSAY_FAKE_LLM_HANG_MS", "")
	if _, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"}); err != nil {
		t.Fatalf("the retry after the wedge: %v", err)
	}
	if n := len(spawnArgvs(t, dir)); n != 2 {
		t.Fatalf("spawns = %d, want 2 — the wedged child was replaced before the retry", n)
	}
}
