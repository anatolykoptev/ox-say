package engine

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// A slow model load must not starve Verify: Verify gets its own budget, not
// what the startup context has left.
// Mutation: supervisor.go run(), call s.cfg.Verify with ctx (the startup
// context) instead of vctx -> RED (the load leaves ~300 ms, Verify needs 600).
func TestVerifyHasItsOwnBudget(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "1200")
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.StartupTimeout = 1500 * time.Millisecond
		c.Verify = func(ctx context.Context, _ string) error {
			select {
			case <-time.After(600 * time.Millisecond):
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	})
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatalf("a verify that needs 600 ms after a 1.2 s load failed: %v", err)
	}
}

// A hung Verify is cut at VerifyTimeout, not at the (much longer) startup
// timeout.
// Mutation: supervisor.go run(), pass ctx instead of vctx -> RED (the start
// hangs for the whole 30 s StartupTimeout).
func TestAHungVerifyIsBounded(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.StartupTimeout = 30 * time.Second
		c.VerifyTimeout = 300 * time.Millisecond
		c.Verify = func(ctx context.Context, _ string) error { <-ctx.Done(); return ctx.Err() }
	})
	start := time.Now()
	done := make(chan error, 1)
	go func() { _, err := sup.EnsureReady(context.Background()); done <- err }()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("a verify that never answers must fail the start")
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("still waiting after %s: the verify is not bounded", time.Since(start))
	}
}

// A Verify refusal is informational: the state reads failed with the cause,
// nothing is blocked (each EnsureReady makes a real start after the ordinary
// backoff), and a successful start clears it.
// Mutation: supervisor.go finishStart, delete the
// `s.state = StateFailed` line -> RED (state stays stopped).
// Mutation: supervisor.go EnsureReady default branch, return an error when
// s.state == StateFailed -> RED (no second start).
func TestAVerifyRefusalIsInformationalAndClears(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	var ok atomic.Bool
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.Verify = func(context.Context, string) error {
			if ok.Load() {
				return nil
			}
			return errors.New("server runs open")
		}
	})
	for want := 1; want <= 3; want++ {
		if _, err := sup.EnsureReady(context.Background()); err == nil || !strings.Contains(err.Error(), "server runs open") {
			t.Fatalf("call %d: err = %v, want the verify cause", want, err)
		}
		if st := sup.Status(); st.State != StateFailed || st.LastErr == "" || st.Starts != want {
			t.Fatalf("call %d: status = %+v, want failed with last_error and %d starts", want, st, want)
		}
	}
	ok.Store(true)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatalf("a start that passes Verify: %v", err)
	}
	if st := sup.Status(); st.State != StateReady || st.LastErr != "" {
		t.Fatalf("status = %+v, want ready with the failure cleared", st)
	}
}

// A child that dies between /health and Verify is an ordinary failed start:
// it must not be booked as the server being refused.
// Mutation: supervisor.go run(), delete the `case <-c.done:` branch (always
// wrap in verifyFailure) -> RED (the state is failed).
func TestAChildDyingDuringVerifyIsNotAVerifyFailure(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	var sup *Supervisor
	sup = newTestSupervisor(t, dir, func(c *Config) {
		c.Verify = func(context.Context, string) error {
			pid := sup.Status().PID
			_ = syscall.Kill(pid, syscall.SIGKILL)
			for sup.Status().PID != 0 { // onExit has reaped the child
				time.Sleep(10 * time.Millisecond)
			}
			return errors.New("connection reset")
		}
	})
	if _, err := sup.EnsureReady(context.Background()); err == nil {
		t.Fatalf("err = %v, want a plain start failure", err)
	}
	if st := sup.State(); st == StateFailed {
		t.Fatalf("state = %s: a dead child was counted as a refused server", st)
	}
}
