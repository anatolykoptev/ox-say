package engine

import (
	"context"
	"errors"
	"syscall"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// The lease itself: one token; Try fails while held; Wait parks until
// released or ctx ends; WaitOr also wakes on abort.
func TestGPULeasePrimitive(t *testing.T) {
	l := NewGPULease()
	if !l.Try() {
		t.Fatal("Try on a free lease failed")
	}
	if !l.Held() {
		t.Fatal("Held = false right after Try")
	}
	if l.Try() {
		t.Fatal("Try on a held lease succeeded")
	}
	l.Release()
	if l.Held() {
		t.Fatal("Held = true after Release")
	}

	// Wait parks: a caller on a held lease must surface in Waiters and
	// only proceed once released.
	if !l.Try() {
		t.Fatal("re-take failed")
	}
	got := make(chan error, 1)
	go func() { got <- l.Wait(context.Background()) }()
	testutil.WaitFor(t, 5*time.Second, func() bool { return l.Waiters() == 1 }, "waiter to park")
	select {
	case err := <-got:
		t.Fatalf("Wait returned %v while the lease was held", err)
	default:
	}
	l.Release()
	if err := <-got; err != nil {
		t.Fatalf("Wait after release: %v", err)
	}
	l.Release() // the Wait above now owns the token

	// WaitOr returns (false, nil) on abort, ctx error on a deadline.
	if !l.Try() {
		t.Fatal("re-take failed")
	}
	abort := make(chan struct{})
	okCh := make(chan bool, 1)
	go func() {
		ok, err := l.WaitOr(context.Background(), abort)
		if err != nil {
			t.Errorf("WaitOr: %v", err)
		}
		okCh <- ok
	}()
	testutil.WaitFor(t, 5*time.Second, func() bool { return l.Waiters() == 1 }, "WaitOr waiter to park")
	close(abort)
	if ok := <-okCh; ok {
		t.Fatal("WaitOr acquired on abort")
	}
	if !l.Held() {
		t.Fatal("lease lost the token across WaitOr's aborted wait")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	if ok, err := l.WaitOr(ctx, nil); ok || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("WaitOr on a held lease = (%v, %v), want (false, DeadlineExceeded)", ok, err)
	}
	l.Release()
	if err := l.Wait(context.Background()); err != nil {
		t.Fatal(err)
	}
	l.Release()
}

// A start attempt must hold the GPU lease before the engine spawns, and a
// caller parked on the lease must produce no child until it frees.
// Mutation: drop the lease wait from EnsureReady's start branch -> RED
// (the child spawns while the lease is still held / Waiters never fills).
func TestStartWaitsForGPULease(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	lease := NewGPULease()
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.GPU = lease
	})
	if !lease.Try() { // stand-in for a GPU transcription in flight
		t.Fatal("could not hold the lease")
	}

	ready := make(chan error, 1)
	go func() {
		_, err := sup.EnsureReady(context.Background())
		ready <- err
	}()
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return lease.Waiters() == 1
	}, "EnsureReady to park on the held lease")
	if got := testutil.SpawnStamps(t, dir); got != 0 {
		t.Fatalf("engine spawned %d times while the GPU lease was held", got)
	}
	if st := sup.State(); st != StateStopped {
		t.Fatalf("state = %s while parked on the lease, want stopped", st)
	}

	lease.Release()
	select {
	case err := <-ready:
		if err != nil {
			t.Fatalf("EnsureReady: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("EnsureReady did not proceed once the lease freed")
	}
	if got := testutil.SpawnStamps(t, dir); got != 1 {
		t.Fatalf("spawn stamps = %d, want 1", got)
	}
	// A Ready engine still holds the GPU: the lease must read held.
	if !lease.Held() {
		t.Fatal("lease free while the engine is ready")
	}
}

// A caller parked on the lease is bounded by its own context: the wait
// ends with the ctx error and spawns nothing.
// Mutation: wait on the lease without the ctx case -> RED (the call outlives
// its deadline; the test's own timeout trips it).
func TestGPULeaseWaitBoundByCallerCtx(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	lease := NewGPULease()
	sup := newTestSupervisor(t, dir, func(c *Config) { c.GPU = lease })
	if !lease.Try() {
		t.Fatal("could not hold the lease")
	}
	defer lease.Release()

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := sup.EnsureReady(ctx)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("EnsureReady on a held lease = %v, want context.DeadlineExceeded", err)
	}
	if took := time.Since(start); took > 5*time.Second {
		t.Fatalf("the lease wait outlived its caller's deadline by %s", took-500*time.Millisecond)
	}
	if got := testutil.SpawnStamps(t, dir); got != 0 {
		t.Fatalf("engine spawned %d times for a caller whose lease wait expired", got)
	}
}

// Shutdown must abort a parked lease wait: the broadcast closes s.change,
// WaitOr's abort case fires, and the caller re-checks into s.dead.
// Mutation: wait on the lease without the abort channel -> RED (the caller
// stays parked past Shutdown and the receive deadline trips).
func TestGPULeaseWaitAbortedByShutdown(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	lease := NewGPULease()
	sup := newTestSupervisor(t, dir, func(c *Config) { c.GPU = lease })
	if !lease.Try() {
		t.Fatal("could not hold the lease")
	}
	defer lease.Release()

	done := make(chan error, 1)
	go func() {
		_, err := sup.EnsureReady(context.Background())
		done <- err
	}()
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return lease.Waiters() == 1
	}, "EnsureReady to park on the held lease")
	sup.Shutdown()
	select {
	case err := <-done:
		if !errors.Is(err, ErrShutdown) {
			t.Fatalf("EnsureReady aborted by Shutdown = %v, want ErrShutdown", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a caller parked on the lease did not observe Shutdown")
	}
}

// The idle-stop window: the supervisor commits Stopped before the child has
// exited, so "the engine holds the GPU" must be the lease, not the state.
// A SIGTERM-ignoring child keeps the window open deterministically — it
// cannot exit before the grace SIGKILL.
// Mutation: release the lease at the Stopped commit (idle loop) instead of
// at child exit -> RED (Try succeeds while the child still lives).
func TestGPULeaseHeldUntilChildExit(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_IGNORE_SIGTERM", "1")
	lease := NewGPULease()
	var pidPath string
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.GPU = lease
		c.IdleStop = 300 * time.Millisecond
		c.IdleTick = 20 * time.Millisecond
		// Long grace: the ignored SIGTERM keeps the child provably alive
		// through the assertions; the test kills it before Shutdown runs.
		c.KillGrace = 30 * time.Second
		pidPath = c.PidPath
	})
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !lease.Held() {
		t.Fatal("lease not held with a ready engine")
	}
	pid := childPid(t, pidPath)
	// End the grace wait whatever the outcome: the SIGTERM-ignoring child
	// would otherwise keep the Shutdown cleanup waiting in killChild for
	// the full KillGrace. Runs before Shutdown (cleanups are LIFO).
	t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) })

	testutil.WaitFor(t, 5*time.Second, func() bool {
		return sup.State() == StateStopped
	}, "idle stop commit")
	if !processAlive(pid) {
		t.Fatal("the stopping child exited before its grace deadline")
	}
	if lease.Try() {
		t.Fatal("lease acquirable while the stopping child still holds the GPU")
	}

	_ = syscall.Kill(pid, syscall.SIGKILL)
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return !processAlive(pid)
	}, "child exit")
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return !lease.Held()
	}, "lease release on child exit")

	// The lease is reusable: the next start takes it and reaches Ready.
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatalf("restart after teardown: %v", err)
	}
	if sup.State() != StateReady {
		t.Fatalf("state = %s, want ready", sup.State())
	}
	if !lease.Held() {
		t.Fatal("lease not held by the restarted engine")
	}
	// The restarted child also ignores SIGTERM: free it before Shutdown's
	// killChild waits out the grace.
	pid2 := childPid(t, pidPath)
	t.Cleanup(func() { _ = syscall.Kill(pid2, syscall.SIGKILL) })
}

// A crash release follows the same rule: the lease is freed when the exit
// is observed, and the next start re-acquires it.
// Mutation: never release on crash exit -> RED ("lease release on the
// crashed child's exit" times out).
func TestGPULeaseReleasedOnCrash(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_EXIT_MS", "300")
	t.Setenv("OXSAY_FAKE_EXIT_ONCE", "1")
	lease := NewGPULease()
	sup := newTestSupervisor(t, dir, func(c *Config) { c.GPU = lease })

	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return sup.State() == StateCrashed
	}, "crash detection")
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return !lease.Held()
	}, "lease release on the crashed child's exit")

	// The restart path re-acquires: while a GPU transcription holds the
	// lease the post-crash start must wait out the backoff AND the lease.
	if !lease.Try() {
		t.Fatal("could not hold the lease")
	}
	ready := make(chan error, 1)
	go func() {
		_, err := sup.EnsureReady(context.Background())
		ready <- err
	}()
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return lease.Waiters() == 1
	}, "the post-crash restart to park on the lease")
	lease.Release()
	select {
	case err := <-ready:
		if err != nil {
			t.Fatalf("restart after crash: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("post-crash restart did not proceed after release")
	}
	if got := testutil.SpawnStamps(t, dir); got != 2 {
		t.Fatalf("spawn stamps = %d, want 2", got)
	}
}
