package engine

import (
	"context"
	"errors"
	"syscall"
	"testing"
	"time"
)

func processGone(pid int) bool { return syscall.Kill(pid, 0) != nil }

// Stop frees the engine's memory before it returns (the process is gone), is not terminal (the next EnsureReady
// spawns a fresh child), and is a no-op on an engine that is not running.
// Mutation: supervisor.go Stop, replace the `return s.recycleKill(ctx, c)` stop branch with `return nil` -> the child
// keeps running -> RED.
func TestStopFreesTheChildAndIsNotTerminal(t *testing.T) {
	sup := recycleSup(t, 5*time.Second)
	if err := sup.Stop(context.Background()); err != nil {
		t.Fatalf("Stop of a never-started engine: %v", err)
	}
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	old := sup.Status().PID
	if err := sup.Stop(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !processGone(old) {
		t.Fatalf("pid %d still alive after Stop returned", old)
	}
	if st := sup.State(); st != StateStopped {
		t.Fatalf("state after Stop = %s, want stopped", st)
	}
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatalf("EnsureReady after Stop (Stop must not be terminal): %v", err)
	}
	if st := sup.Status(); st.PID == old || st.Starts != 2 {
		t.Fatalf("after Stop+EnsureReady: pid %d (old %d) starts %d", st.PID, old, st.Starts)
	}
}

// A held Guard keeps Stop waiting: a request in flight is never killed.
// Mutation: supervisor.go Stop, drop `&& s.guards == 0` from the stop branch -> the child dies under the guard -> RED.
func TestStopWaitsForAGuardAndNeverKillsARequest(t *testing.T) {
	sup := recycleSup(t, 10*time.Second)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := sup.Status().PID
	g := sup.Acquire()
	done := make(chan error, 1)
	go func() { done <- sup.Stop(context.Background()) }()
	select {
	case err := <-done:
		t.Fatalf("Stop returned %v while a guard was held", err)
	case <-time.After(400 * time.Millisecond):
	}
	if processGone(pid) || sup.State() != StateReady {
		t.Fatal("child touched under a guard")
	}
	g.Release()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Stop did not proceed after the guard was released")
	}
	if !processGone(pid) {
		t.Fatal("child still alive after the guard released and Stop returned")
	}
}

// A guard that never releases bounds the wait: ErrRecycleBusy, child intact.
// Mutation: supervisor.go Stop, delete the `case <-timer.C: return ErrRecycleBusy` arm -> the call parks until the test
// binary times out -> RED.
func TestStopGivesUpOnAStuckGuard(t *testing.T) {
	sup := recycleSup(t, 200*time.Millisecond)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := sup.Status().PID
	g := sup.Acquire()
	defer g.Release()
	if err := sup.Stop(context.Background()); !errors.Is(err, ErrRecycleBusy) {
		t.Fatalf("err = %v, want ErrRecycleBusy", err)
	}
	if processGone(pid) || sup.State() != StateReady {
		t.Fatal("a refused Stop touched the child")
	}
}

// After Shutdown, Stop is a no-op (nothing to free, nothing to wait for).
func TestStopAfterShutdownIsANoOp(t *testing.T) {
	sup := recycleSup(t, time.Second)
	sup.Shutdown()
	if err := sup.Stop(context.Background()); err != nil {
		t.Fatal(err)
	}
}

// An idle-only guard keeps the idle loop off the child but does not hold Stop; a hard guard does.
// Mutation: supervisor.go Stop, `s.guards-s.softGuards == 0` -> `s.guards == 0` -> Stop waits for the idle-only guard
// -> RED. supervisor.go Release, drop the `softGuards--` -> a later Stop keeps counting a released guard -> RED.
func TestStopDoesNotWaitForAnIdleOnlyGuard(t *testing.T) {
	sup := recycleSup(t, 200*time.Millisecond)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	g := sup.AcquireIdleOnly()
	if err := sup.Stop(context.Background()); err != nil {
		t.Fatalf("Stop with only an idle-only guard held: %v", err)
	}
	g.Release()
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	hard := sup.Acquire()
	defer hard.Release()
	if err := sup.Stop(context.Background()); !errors.Is(err, ErrRecycleBusy) {
		t.Fatalf("Stop with a hard guard (after an idle-only one was released) = %v, want ErrRecycleBusy", err)
	}
}

// The idle loop does honour an idle-only guard.
func TestIdleOnlyGuardKeepsTheIdleLoopOff(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	sup := newTestSupervisor(t, dir, func(c *Config) { c.IdleStop = 150 * time.Millisecond; c.IdleTick = 20 * time.Millisecond })
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	g := sup.AcquireIdleOnly()
	time.Sleep(600 * time.Millisecond)
	if st := sup.State(); st != StateReady {
		t.Fatalf("state under an idle-only guard = %s, want ready", st)
	}
	g.Release()
	deadline := time.Now().Add(5 * time.Second)
	for sup.State() != StateStopped && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if sup.State() != StateStopped {
		t.Fatal("the idle loop never stopped the child after the guard was released")
	}
}
