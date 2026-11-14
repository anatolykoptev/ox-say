package daemon

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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

// A wedged engine whose stop fails (a Guard still held, so Stop gives up) is
// still up: the retry Compose would spend lands on the same process. The
// error must say so — non-retryable — instead of promising a fresh spawn (#572).
// Mutation: internal/daemon/meetings.go llmChat.Complete, Retryable: true on
// the stop-failed path -> RED (TestAWedgedEngineThatCannotBeStoppedIsNotRetryable).
func TestAWedgedEngineThatCannotBeStoppedIsNotRetryable(t *testing.T) {
	d, dir := startNotesFake(t)
	t.Setenv("OXSAY_FAKE_LLM_HANG_MS", "30000")
	t.Setenv("OXSAY_FAKE_LLM_SLOTS_STALL", "1")
	shortNotesCallTimeout(t)
	keep := notesAliveProbe
	notesAliveProbe = 100 * time.Millisecond
	t.Cleanup(func() { notesAliveProbe = keep })
	keepGap := notesProgressProbe
	notesProgressProbe = 10 * time.Millisecond
	t.Cleanup(func() { notesProgressProbe = keepGap })
	keepStop := notesStopWait
	notesStopWait = 200 * time.Millisecond
	t.Cleanup(func() { notesStopWait = keepStop })
	other := d.LLMSup.Acquire() // another user of the engine: Stop will not kill a request in flight
	defer other.Release()
	_, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"})
	var down *meeting.EngineDownError
	if !errors.As(err, &down) || down.Reason != meeting.FailNotesEngineTimeout {
		t.Fatalf("err = %v (%T), want the engine-down error with %s", err, err, meeting.FailNotesEngineTimeout)
	}
	if down.Retryable {
		t.Fatal("the child is still up after a failed stop: a retry would re-ask the same wedged process")
	}
	if n := len(spawnStamps(t, dir)); n != 1 {
		t.Fatalf("spawns = %d, want 1", n)
	}
}

// /slots answering with no rows says nothing about whether the decode moves:
// it must not read as "alive and slow" (which splits the chunk), only as
// inconclusive (#572).
// Mutation: internal/daemon/meetings.go notesProgressing, drop the len==0
// guards -> RED (TestNotesProgressingEmptySlotsIsInconclusive).
func TestNotesProgressingEmptySlotsIsInconclusive(t *testing.T) {
	d, _ := startNotesFake(t)
	if err := os.MkdirAll(d.Cfg.RunDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d.Cfg.RunDir(), notesKeyFile), []byte("k"), 0o600); err != nil {
		t.Fatal(err)
	}
	for body, want := range map[string]bool{
		`[]`:                        false,
		`null`:                      false,
		`[{"is_processing":false}]`: true, // a real idle slot: the request simply ended
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write([]byte(body))
		}))
		keepGap := notesProgressProbe
		notesProgressProbe = 5 * time.Millisecond
		got := d.notesProgressing(context.Background(), srv.URL)
		notesProgressProbe = keepGap
		srv.Close()
		if got != want {
			t.Errorf("/slots %s: notesProgressing = %v, want %v", body, got, want)
		}
	}
}
