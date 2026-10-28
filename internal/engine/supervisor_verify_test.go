package engine

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
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

func giveUp(t *testing.T, sup *Supervisor) error {
	t.Helper()
	for i := 0; i < 6; i++ {
		_, err := sup.EnsureReady(context.Background())
		if errors.Is(err, ErrGaveUp) {
			return err
		}
		if err == nil {
			t.Fatal("EnsureReady succeeded although Verify always fails")
		}
	}
	t.Fatalf("no give-up after 6 starts; starts=%d state=%s", sup.Status().Starts, sup.State())
	return nil
}

// A child that runs but fails Verify every time is retried MaxVerifyFailures
// times, then the supervisor stops: terminal state, last error kept, no spawn.
// Mutation: supervisor.go finishStart, delete the
// `s.verifyFails >= s.cfg.MaxVerifyFailures` branch (no cap) -> RED (never
// gives up; spawns keep coming).
func TestPersistentVerifyFailureGivesUp(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.MaxVerifyFailures = 2
		c.Verify = func(context.Context, string) error { return errors.New("server runs open") }
	})
	err := giveUp(t, sup)
	st := sup.Status()
	if st.State != StateFailed || st.Starts != 2 {
		t.Fatalf("status = %+v, want failed after exactly 2 starts", st)
	}
	if st.LastErr == "" || st.RetryInS <= 0 {
		t.Fatalf("status = %+v, want last_error and retry_in_s", st)
	}
	if got := err.Error(); !strings.Contains(got, "server runs open") {
		t.Fatalf("give-up error %q hides the cause", got)
	}
	t0 := time.Now()
	if _, err := sup.EnsureReady(context.Background()); !errors.Is(err, ErrGaveUp) || time.Since(t0) > time.Second {
		t.Fatalf("EnsureReady in the failed state = %v after %s, want an immediate ErrGaveUp", err, time.Since(t0))
	}
	if sup.Status().Starts != 2 {
		t.Fatalf("a start was spawned in the failed state: %+v", sup.Status())
	}
	if sup.Backoff() <= 0 {
		t.Fatal("Backoff must report the cool-down while failed")
	}
}

// After the cool-down one probe start is made: failing again re-enters the
// failed state after a single spawn; passing makes the engine Ready.
// Mutation: supervisor.go EnsureReady, delete the cool-down expiry (always
// return ErrGaveUp) -> RED (no probe start).
func TestFailedStateResumesAfterTheCooldown(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	var ok atomic.Bool
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.MaxVerifyFailures = 2
		c.GiveUpCooldown = 400 * time.Millisecond
		c.Verify = func(context.Context, string) error {
			if ok.Load() {
				return nil
			}
			return errors.New("server runs open")
		}
	})
	giveUp(t, sup)
	time.Sleep(450 * time.Millisecond)
	if _, err := sup.EnsureReady(context.Background()); err == nil || errors.Is(err, ErrGaveUp) && sup.Status().Starts != 3 {
		t.Fatalf("probe: err=%v starts=%d, want one more spawn", err, sup.Status().Starts)
	}
	if sup.State() != StateFailed || sup.Status().Starts != 3 {
		t.Fatalf("after a failed probe: %+v, want failed with 3 starts", sup.Status())
	}
	ok.Store(true)
	time.Sleep(450 * time.Millisecond)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatalf("probe with a passing verify: %v", err)
	}
	if sup.State() != StateReady {
		t.Fatalf("state = %s, want ready", sup.State())
	}
}
