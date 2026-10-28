package engine

import (
	"context"
	"errors"
	"syscall"
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

// A request sent after the wedged one is queued behind it, not being served, so
// it must not hold the recycle: RecycleWedged proceeds with it still in
// flight, and the child is replaced.
// Mutation: supervisor.go blockedLocked, replace the condition with `true`
// (every held guard blocks) -> ErrRecycleBusy after RecycleWait -> RED.
func TestRecycleWedgedIgnoresRequestsQueuedBehindIt(t *testing.T) {
	sup := recycleSup(t, 300*time.Millisecond)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := sup.Status().PID
	wedged := sup.Acquire()
	queued := sup.Acquire()
	defer wedged.Release()
	defer queued.Release()
	from := wedged.MarkSent()
	queued.MarkSent()
	if err := sup.RecycleWedged(context.Background(), pid, from); err != nil {
		t.Fatalf("RecycleWedged with only a queued request in flight: %v", err)
	}
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	if sup.Status().PID == pid {
		t.Fatal("the wedged child was not replaced")
	}
}

// A request sent BEFORE the wedged one may be the one the child is answering
// (the wedged render queued behind it): it is never killed.
// Mutation: supervisor.go blockedLocked, condition -> `false` (every guard
// ignored) -> the child dies under the older request -> RED.
func TestRecycleWedgedWaitsForAnOlderRequest(t *testing.T) {
	sup := recycleSup(t, 250*time.Millisecond)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := sup.Status().PID
	older := sup.Acquire()
	defer older.Release()
	wedged := sup.Acquire()
	defer wedged.Release()
	older.MarkSent()
	from := wedged.MarkSent()
	if err := sup.RecycleWedged(context.Background(), pid, from); !errors.Is(err, ErrRecycleBusy) {
		t.Fatalf("err = %v, want ErrRecycleBusy", err)
	}
	if st := sup.Status(); st.PID != pid || st.State != StateReady {
		t.Fatalf("child touched under an older request: pid %d state %s", st.PID, st.State)
	}
}

// Guard order is not send order. (a) A guard acquired BEFORE the wedged one
// that writes to the child AFTER it is queued behind it: it must not make the
// recycle wait out RecycleWait.
// Mutation: supervisor.go blockedLocked, condition -> `true` -> RED.
func TestRecycleWedgedIgnoresAnEarlierGuardThatSentLater(t *testing.T) {
	sup := recycleSup(t, 300*time.Millisecond)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := sup.Status().PID
	early := sup.Acquire() // acquired first, e.g. still in EnsureReady
	wedged := sup.Acquire()
	defer early.Release()
	defer wedged.Release()
	from := wedged.MarkSent()
	early.MarkSent() // reaches the child second
	if err := sup.RecycleWedged(context.Background(), pid, from); err != nil {
		t.Fatalf("an earlier-acquired guard that sent later held the recycle: %v", err)
	}
}

// (b) A guard acquired AFTER the wedged one that writes to the child BEFORE it
// is the request the child is answering: it is never killed.
// Mutation: supervisor.go blockedLocked, condition -> `false` -> the child dies
// under it -> RED.
func TestRecycleWedgedWaitsForALaterGuardThatSentFirst(t *testing.T) {
	sup := recycleSup(t, 250*time.Millisecond)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := sup.Status().PID
	wedged := sup.Acquire()
	late := sup.Acquire() // acquired second
	defer wedged.Release()
	defer late.Release()
	late.MarkSent() // but reached the child first
	from := wedged.MarkSent()
	if err := sup.RecycleWedged(context.Background(), pid, from); !errors.Is(err, ErrRecycleBusy) {
		t.Fatalf("err = %v, want ErrRecycleBusy (the child is answering the other request)", err)
	}
	if st := sup.Status(); st.PID != pid || st.State != StateReady {
		t.Fatalf("child touched under a request being answered: pid %d state %s", st.PID, st.State)
	}
}

// A guard that has not written to the child has no answer in flight: it does
// not hold the recycle.
// Mutation: supervisor.go blockedLocked, drop `g.sent != 0 &&` -> an unsent
// guard (sent 0 < from) blocks -> RED.
func TestRecycleWedgedIgnoresAGuardThatHasNotSent(t *testing.T) {
	sup := recycleSup(t, 300*time.Millisecond)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := sup.Status().PID
	unsent := sup.Acquire()
	wedged := sup.Acquire()
	defer unsent.Release()
	defer wedged.Release()
	from := wedged.MarkSent()
	if err := sup.RecycleWedged(context.Background(), pid, from); err != nil {
		t.Fatalf("a guard that never sent held the recycle: %v", err)
	}
}

// A user cancel while the old child is being killed ends the call at once;
// the kill itself carries on and the child still dies.
// Mutation: supervisor.go recycleKill, call s.killChild(c) inline instead of
// in the goroutine behind the select -> the call returns only after the
// SIGTERM grace -> RED.
func TestRecycleReturnsOnCancelWhileKilling(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_IGNORE_SIGTERM", "1")
	sup := newTestSupervisor(t, dir, func(c *Config) { c.RecycleWait = time.Second; c.KillGrace = 3 * time.Second })
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := sup.Status().PID
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(200*time.Millisecond, cancel)
	start := time.Now()
	err := sup.Recycle(ctx, pid)
	if el := time.Since(start); !errors.Is(err, context.Canceled) || el > 2*time.Second {
		t.Fatalf("Recycle = %v after %s, want context.Canceled well inside the 3 s SIGTERM grace", err, el)
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if syscall.Kill(pid, 0) != nil { // gone
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("the old child survived: the kill must continue after the cancel")
}
