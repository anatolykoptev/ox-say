package engine

import (
	"context"
	"errors"
	"testing"
	"time"
)

func recycleSup(t *testing.T, wait time.Duration) *Supervisor {
	t.Helper()
	dir := t.TempDir()
	fakeEnv(t, dir)
	return newTestSupervisor(t, dir, func(c *Config) { c.RecycleWait = wait })
}

// Recycle stops the named current child and the next EnsureReady spawns a
// fresh one with another pid.
// Mutation: supervisor.go Recycle, replace the `s.guards == 0` branch's
// killChild/state change with a bare `return nil` -> pid unchanged -> RED.
func TestRecycleReplacesTheCurrentChild(t *testing.T) {
	sup := recycleSup(t, 5*time.Second)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	old := sup.Status().PID
	if err := sup.Recycle(context.Background(), old); err != nil {
		t.Fatal(err)
	}
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	st := sup.Status()
	if st.PID == old || st.State != StateReady || st.Starts != 2 {
		t.Fatalf("after recycle: pid %d (old %d) state %s starts %d", st.PID, old, st.State, st.Starts)
	}
}

// A pid that is not the current child's is a no-op: a late caller must never
// stop a healthy successor.
// Mutation: supervisor.go Recycle, drop `|| c.cmd.Process.Pid != pid` -> the
// healthy child is stopped -> RED.
func TestRecycleOfAStalePidIsANoOp(t *testing.T) {
	sup := recycleSup(t, 5*time.Second)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	cur := sup.Status().PID
	if err := sup.Recycle(context.Background(), cur+100000); err != nil {
		t.Fatal(err)
	}
	st := sup.Status()
	if st.PID != cur || st.State != StateReady || st.Starts != 1 {
		t.Fatalf("a stale pid touched the child: pid %d (was %d) state %s starts %d", st.PID, cur, st.State, st.Starts)
	}
}

// A held Guard delays the recycle; the child is not stopped until the request
// releases, and then it is.
// Mutation: supervisor.go Recycle, drop `s.guards == 0` from the stop branch
// (stop at once) -> the child dies under the guard -> RED.
func TestRecycleWaitsForAGuard(t *testing.T) {
	sup := recycleSup(t, 10*time.Second)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := sup.Status().PID
	g := sup.Acquire()
	done := make(chan error, 1)
	go func() { done <- sup.Recycle(context.Background(), pid) }()
	select {
	case err := <-done:
		t.Fatalf("Recycle returned %v while a guard was held", err)
	case <-time.After(400 * time.Millisecond):
	}
	if st := sup.Status(); st.PID != pid || st.State != StateReady {
		t.Fatalf("child touched under a guard: pid %d state %s", st.PID, st.State)
	}
	g.Release()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Recycle did not proceed after the guard was released")
	}
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	if sup.Status().PID == pid {
		t.Fatal("child was not replaced after the guard released")
	}
}

// A guard that never releases bounds the wait: ErrRecycleBusy, child intact.
// Mutation: supervisor.go Recycle, `case <-timer.C: return ErrRecycleBusy`
// -> `continue` of the wait -> the call hangs -> RED.
func TestRecycleGivesUpOnAStuckGuard(t *testing.T) {
	sup := recycleSup(t, 200*time.Millisecond)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := sup.Status().PID
	g := sup.Acquire()
	defer g.Release()
	if err := sup.Recycle(context.Background(), pid); !errors.Is(err, ErrRecycleBusy) {
		t.Fatalf("err = %v, want ErrRecycleBusy", err)
	}
	if st := sup.Status(); st.PID != pid || st.State != StateReady {
		t.Fatalf("child touched although busy: pid %d state %s", st.PID, st.State)
	}
}
