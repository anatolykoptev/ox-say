package daemon

import (
	"context"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func shortSpeechBudget(t *testing.T, b time.Duration) {
	t.Helper()
	old := speechLeaseBudget
	speechLeaseBudget = b
	t.Cleanup(func() { speechLeaseBudget = old })
}

// #482.1: on Intel a speech request parked behind a cleanup gets the typed 503 after the short budget, not when its
// own (long) deadline ends. Mutation: speak.go speechOn, replace `d.boundCleanupWait(ctx)` with `ctx, func() {}` -> RED.
func TestSpeechDuringACleanupFailsAfterTheBudgetNotTheCallerDeadline(t *testing.T) {
	d, _, _ := newCleanDaemonOn(t, "exit 0", false)
	shortSpeechBudget(t, 200*time.Millisecond)
	if !d.gpu.TryAs("clean") {
		t.Fatal("lease")
	}
	defer d.gpu.Release()
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	start := time.Now()
	_, err := d.speechOn(ctx, d.Sup, map[string]any{"input": "hello"})
	if el := time.Since(start); el > 2*time.Second {
		t.Fatalf("took %v, want about the 200ms budget", el)
	}
	var sbe *speechBlockedError
	if !errors.As(err, &sbe) {
		t.Fatalf("got %v", err)
	}
	rec := httptest.NewRecorder()
	writeSynthErr(rec, err)
	if rec.Code != 503 || !strings.Contains(rec.Body.String(), "gpu_busy_cleanup") {
		t.Errorf("%d %s", rec.Code, rec.Body)
	}
}

// A lease held by anything else is not bounded by the budget: the request waits for its own deadline.
func TestSpeechBudgetDoesNotApplyToOtherLeaseHolders(t *testing.T) {
	d, _, _ := newCleanDaemonOn(t, "exit 0", false)
	shortSpeechBudget(t, 100*time.Millisecond)
	if !d.gpu.TryAs("transcription") {
		t.Fatal("lease")
	}
	defer d.gpu.Release()
	ctx, cancel := context.WithTimeout(t.Context(), 600*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := d.speechOn(ctx, d.Sup, map[string]any{"input": "hello"})
	var sbe *speechBlockedError
	if err == nil || errors.As(err, &sbe) {
		t.Fatalf("got %v", err)
	}
	if el := time.Since(start); el < 500*time.Millisecond {
		t.Errorf("gave up after %v, before the caller's deadline", el)
	}
}

// #482.2: the caller's context error stays in the chain. Mutation: clean.go speechBlockedError.Unwrap, drop e.err -> RED.
func TestSpeechBlockedErrorKeepsTheContextError(t *testing.T) {
	d, _, _ := newCleanDaemonOn(t, "exit 0", false)
	if !d.gpu.TryAs("clean") {
		t.Fatal("lease")
	}
	defer d.gpu.Release()
	ctx, cancel := context.WithTimeout(t.Context(), 200*time.Millisecond)
	defer cancel()
	_, err := d.speechOn(ctx, d.Sup, map[string]any{"input": "hello"})
	if !errors.Is(err, context.DeadlineExceeded) || !errors.Is(err, errEngineStart) {
		t.Fatalf("chain lost: %v", err)
	}
}

// #482.3: stopIdleTTS matches the quiet gate. Mutation: clean.go stopIdleTTS, `d.quietBusy() > 0` back to
// `d.busy().Speaking > 0` -> RED.
func TestStopIdleTTSKeepsTheChildWhileOtherGPUWorkRuns(t *testing.T) {
	d, _, _ := newCleanDaemonOn(t, "exit 0", false)
	if _, err := d.Sup.EnsureReady(t.Context()); err != nil {
		t.Fatal(err)
	}
	pid := d.Sup.Status().PID
	if pid <= 0 || d.gpu.Owner() != "tts" {
		t.Fatalf("pid %d owner %q", pid, d.gpu.Owner())
	}
	d.designing.Add(1)
	d.stopIdleTTS(t.Context())
	if !alive(pid) || d.Sup.Status().PID != pid {
		t.Fatal("recycled while a voice design was running")
	}
	d.designing.Add(-1)
	d.inflight.Add(1)
	d.stopIdleTTS(t.Context())
	if !alive(pid) {
		t.Fatal("recycled while an interactive request was running")
	}
	d.inflight.Add(-1)
	d.stopIdleTTS(t.Context())
	waitFor(t, "idle child recycled", func() bool { return !alive(pid) })
}
