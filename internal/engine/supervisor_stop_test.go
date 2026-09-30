package engine

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// Stop on a Ready supervisor must wait for in-flight guards: while a guard
// is held the child stays alive and Stop does not return; once the guard
// is released the child is stopped and the state settles at Stopped.
// Mutation: in Stop, delete the guard-drain wait -> RED
// ("Stop returned ... while a guard was held").
func TestStopDrainsGuards(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	sup := newTestSupervisor(t, dir, nil)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	g := sup.Acquire()
	pid := sup.Status().PID

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stopped := make(chan error, 1)
	go func() { stopped <- sup.Stop(ctx) }()

	time.Sleep(300 * time.Millisecond)
	select {
	case err := <-stopped:
		t.Fatalf("Stop returned %v while a guard was held", err)
	default:
	}
	if !processAlive(pid) {
		t.Fatal("child died while a guard was held")
	}

	g.Release()
	select {
	case err := <-stopped:
		if err != nil {
			t.Fatalf("Stop: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Stop did not return after the guard was released")
	}
	if processAlive(pid) {
		t.Fatal("child still alive after Stop")
	}
	if st := sup.State(); st != StateStopped {
		t.Fatalf("state = %s, want stopped", st)
	}
}

// The guard drain in Stop is bounded by ctx: a guard that is never released
// cannot hold the child past the deadline — Stop cuts the in-flight work
// off and kills the child anyway.
// Mutation: ignore ctx in the drain wait -> RED (Stop never returns; the
// test's own deadline fails first).
func TestStopDrainIsBounded(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	sup := newTestSupervisor(t, dir, nil)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	g := sup.Acquire()
	defer g.Release()
	pid := sup.Status().PID

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	stopped := make(chan error, 1)
	go func() { stopped <- sup.Stop(ctx) }()

	select {
	case <-stopped:
		// The drain deadline fired; the stop proceeded anyway.
	case <-time.After(300*time.Millisecond + 2*time.Second + time.Second): // ctx + KillGrace + margin
		t.Fatal("Stop did not return after ctx expiry and kill grace")
	}
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return !processAlive(pid)
	}, "child exit after bounded drain")
	if st := sup.State(); st != StateStopped {
		t.Fatalf("state = %s, want stopped", st)
	}
}

// Stop must not charge restart backoff: a clean stop leaves failCount and
// nextAttempt untouched, so the next EnsureReady spawns immediately.
// Mutation: in the clean-stop helper set
//
//	s.failCount++; s.nextAttempt = time.Now().Add(s.backoffLocked())
//
// -> RED ("restart took ... want < 1s").
func TestStopThenRestartHasNoBackoff(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	sup := newTestSupervisor(t, dir, nil)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := sup.Stop(ctx); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	if got := testutil.SpawnStamps(t, dir); got != 1 {
		t.Fatalf("spawn stamps = %d, want 1", got)
	}

	start := time.Now()
	base, err := sup.EnsureReady(context.Background())
	if err != nil {
		t.Fatalf("EnsureReady after Stop: %v", err)
	}
	if d := time.Since(start); d > time.Second {
		t.Fatalf("restart took %s, want < 1s (no backoff after Stop)", d)
	}
	resp, err := http.Get(base + "/health")
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if got := testutil.SpawnStamps(t, dir); got != 2 {
		t.Fatalf("spawn stamps = %d, want 2", got)
	}
}

// Stop must abort an in-flight start without committing Ready: the spawned
// child is killed, the EnsureReady waiters of that generation get an error
// wrapping ErrStopped, the attempt is recorded cleanly (no crash, no last
// error), and a later EnsureReady restarts with no backoff.
// Mutation: in finishStart, drop the stop-request check -> RED
// ("EnsureReady error = ... want ErrStopped").
func TestStopDuringStartup(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "3000")
	sup := newTestSupervisor(t, dir, nil)

	ensured := make(chan error, 1)
	go func() {
		_, err := sup.EnsureReady(context.Background())
		ensured <- err
	}()
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return sup.State() == StateStarting && testutil.SpawnStamps(t, dir) == 1
	}, "starting with a spawned child")
	pid := sup.Status().PID

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stopped := make(chan error, 1)
	go func() { stopped <- sup.Stop(ctx) }()
	select {
	case err := <-stopped:
		if err != nil {
			t.Fatalf("Stop: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Stop did not return within 2s during startup")
	}
	if err := <-ensured; !errors.Is(err, ErrStopped) {
		t.Fatalf("EnsureReady error = %v, want ErrStopped", err)
	}
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return !processAlive(pid)
	}, "child exit")
	if st := sup.State(); st != StateStopped {
		t.Fatalf("state = %s, want stopped", st)
	}
	if lastErr := sup.Status().LastErr; lastErr != "" {
		t.Fatalf("last error = %q, want empty after a stopped start", lastErr)
	}

	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "0")
	start := time.Now()
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatalf("restart after Stop: %v", err)
	}
	if d := time.Since(start); d > time.Second {
		t.Fatalf("restart took %s, want < 1s", d)
	}
	if got := testutil.SpawnStamps(t, dir); got != 2 {
		t.Fatalf("spawn stamps = %d, want 2", got)
	}
}

// A Stop requested before spawn must prevent the spawn entirely: no child
// process is created (no spawn stamp) and the EnsureReady waiter gets
// ErrStopped.
// Mutation: drop the stop-request check in spawn -> RED
// ("spawn stamps = 1, want 0").
func TestStopBeforeSpawn(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	entered := make(chan struct{})
	release := make(chan struct{})
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.BeforeStart = func(context.Context) error {
			close(entered)
			<-release
			return nil
		}
	})
	ensured := make(chan error, 1)
	go func() {
		_, err := sup.EnsureReady(context.Background())
		ensured <- err
	}()
	<-entered // BeforeStart is blocked; no spawn can have happened yet

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stopped := make(chan error, 1)
	go func() { stopped <- sup.Stop(ctx) }()
	// Wait until the stop request is recorded for this start generation so
	// the spawn below cannot slip past it.
	testutil.WaitFor(t, 5*time.Second, func() bool {
		sup.mu.Lock()
		defer sup.mu.Unlock()
		return sup.stopGen == sup.startGen
	}, "stop request to land")
	close(release)

	select {
	case err := <-stopped:
		if err != nil {
			t.Fatalf("Stop: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Stop did not return")
	}
	if err := <-ensured; !errors.Is(err, ErrStopped) {
		t.Fatalf("EnsureReady error = %v, want ErrStopped", err)
	}
	if got := testutil.SpawnStamps(t, dir); got != 0 {
		t.Fatalf("spawn stamps = %d, want 0", got)
	}
	if got := sup.Status().Starts; got != 0 {
		t.Fatalf("starts = %d, want 0 (spawn must have been prevented)", got)
	}
	if _, err := os.Stat(filepath.Join(dir, "logs", "engine.log")); !os.IsNotExist(err) {
		t.Fatalf("engine.log exists (err=%v) although spawn was prevented", err)
	}
	if st := sup.State(); st != StateStopped {
		t.Fatalf("state = %s, want stopped", st)
	}
}

// BeforeStart gates the spawn: a refusal must fail the attempt like a
// spawn error — nothing is spawned (starts stays 0, no child log is even
// opened) and the waiter gets the hook's error.
// Mutation: call BeforeStart after spawn() in run() -> RED
// ("starts = 1, want 0"; a stamp may not be left because the child dies
// before it can write one, so stamps alone cannot prove the mutation).
func TestBeforeStartRefusal(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	refusal := errors.New("GPU held by stt child")
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.BeforeStart = func(context.Context) error { return refusal }
	})
	if _, err := sup.EnsureReady(context.Background()); !errors.Is(err, refusal) {
		t.Fatalf("EnsureReady error = %v, want the BeforeStart refusal", err)
	}
	if got := sup.Status().Starts; got != 0 {
		t.Fatalf("starts = %d, want 0 (spawn must not run on refusal)", got)
	}
	if _, err := os.Stat(filepath.Join(dir, "logs", "engine.log")); !os.IsNotExist(err) {
		t.Fatalf("engine.log exists (err=%v) although spawn was refused", err)
	}
	if got := testutil.SpawnStamps(t, dir); got != 0 {
		t.Fatalf("spawn stamps = %d, want 0", got)
	}
}

// Args replaces the default tts-server argv and LogName renames the child
// log file. The Args function here intentionally binds a port other than
// cfg.Port so a supervisor that ignored Args (and spawned the default argv
// on cfg.Port) is caught: the child must listen on the Args port. The
// supervisor itself never reaches Ready in this test — it health-checks
// cfg.Port, which the child deliberately does not bind — so readiness is
// probed on the child directly.
// Mutation: ignore Args in spawn -> RED ("child listening on the Args
// port" times out: the default argv bound cfg.Port instead).
func TestArgsAndLogName(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	argsPort := testutil.FreePort(t)
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.LogName = "stt.log"
		c.Args = func(int) []string {
			return []string{"--port", strconv.Itoa(argsPort)}
		}
	})
	ensured := make(chan error, 1)
	go func() {
		_, err := sup.EnsureReady(context.Background())
		ensured <- err
	}()

	argsBase := fmt.Sprintf("http://127.0.0.1:%d", argsPort)
	testutil.WaitFor(t, 5*time.Second, func() bool {
		resp, err := http.Get(argsBase + "/health")
		if err != nil {
			return false
		}
		_ = resp.Body.Close()
		return resp.StatusCode == http.StatusOK
	}, "child listening on the Args port")

	if _, err := os.Stat(filepath.Join(dir, "logs", "stt.log")); err != nil {
		t.Fatalf("stt.log: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "logs", "engine.log")); !os.IsNotExist(err) {
		t.Fatalf("engine.log exists (err=%v) although LogName=stt.log", err)
	}

	sup.Shutdown()
	if err := <-ensured; !errors.Is(err, ErrShutdown) {
		t.Fatalf("EnsureReady after Shutdown = %v, want ErrShutdown", err)
	}
}
