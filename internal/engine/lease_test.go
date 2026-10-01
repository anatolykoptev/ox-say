package engine

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// infoLog is a slog handler recording every message — the parked-start
// line is Info, which a Warn-only recorder would drop.
type infoLog struct {
	mu   sync.Mutex
	msgs []string
}

func (h *infoLog) Enabled(context.Context, slog.Level) bool { return true }
func (h *infoLog) Handle(_ context.Context, r slog.Record) error {
	h.mu.Lock()
	h.msgs = append(h.msgs, r.Message)
	h.mu.Unlock()
	return nil
}
func (h *infoLog) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h *infoLog) WithGroup(string) slog.Handler      { return h }

func (h *infoLog) saw(sub string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, m := range h.msgs {
		if strings.Contains(m, sub) {
			return true
		}
	}
	return false
}

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

// Release on a free lease is a misuse and must panic at once — the
// supervisor's release runs under s.mu, where the old blocking receive
// would have frozen it. The wait runs in a goroutine so a regression to a
// blocking Release fails the test in 2 s instead of hanging the package.
func TestFreeLeaseReleasePanics(t *testing.T) {
	l := NewGPULease()
	done := make(chan any, 1)
	go func() {
		defer func() { done <- recover() }()
		l.Release()
	}()
	select {
	case r := <-done:
		if r == nil {
			t.Fatal("Release on a free lease returned normally")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Release on a free lease blocked instead of panicking")
	}
}

// The lease names its holder for the operator: a start parked behind a
// transcription reads "transcription" in Status (surfaced as gpu_held_by
// through /status, engine_status and `ox-say status`), the park itself is
// logged once, and once the spawned generation owns the token the owner
// reads "tts".
// Mutation: acquire the lease untagged in the supervisor (drop the owner
// argument) -> RED (GPUHeldBy stays ""); drop the park log -> RED on saw().
func TestGPUOwnerInStatus(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	lease := NewGPULease()
	rec := &infoLog{}
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.GPU = lease
		c.Logger = slog.New(rec)
	})
	if err := lease.WaitAs(context.Background(), "transcription"); err != nil {
		t.Fatal(err)
	}
	if got := lease.Owner(); got != "transcription" {
		t.Fatalf("Owner() = %q, want transcription", got)
	}

	ready := make(chan error, 1)
	go func() {
		_, err := sup.EnsureReady(context.Background())
		ready <- err
	}()
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return lease.Waiters() == 1
	}, "EnsureReady to park on the held lease")
	if got := sup.Status().GPUHeldBy; got != "transcription" {
		t.Fatalf("gpu_held_by while parked = %q, want transcription", got)
	}
	if !rec.saw("waiting for the GPU lease") {
		t.Fatalf("parked start produced no log line; got %v", rec.msgs)
	}

	lease.Release()
	select {
	case err := <-ready:
		if err != nil {
			t.Fatalf("EnsureReady after release: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("EnsureReady did not proceed once the lease freed")
	}
	if got := sup.Status().GPUHeldBy; got != "tts" {
		t.Fatalf("gpu_held_by with a ready engine = %q, want tts", got)
	}
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

// A start that fails at spawn releases the lease it took: the generation
// owned the token from the start commit, and with no live child to carry
// it, finishStart must give it back or every later GPU user parks forever.
// Mutation: drop the `} else { s.releaseGPULocked() }` release in
// finishStart -> RED (the lease stays held after the spawn error).
func TestSpawnFailureReleasesLease(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	lease := NewGPULease()
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.GPU = lease
		c.Bin = "/nonexistent/tts-server"
	})
	if _, err := sup.EnsureReady(context.Background()); err == nil {
		t.Fatal("EnsureReady with a missing binary succeeded")
	}
	testutil.WaitFor(t, 2*time.Second, func() bool { return !lease.Held() }, "lease release after spawn failure")
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
