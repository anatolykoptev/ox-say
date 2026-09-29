package engine

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

func TestMain(m *testing.M) {
	testutil.FakeChildMain()
	os.Exit(m.Run())
}

// newTestSupervisor builds a Supervisor whose "engine binary" is the test
// binary itself, re-exec'd as the fake child (OXSAY_FAKE_CHILD=1).
func newTestSupervisor(t *testing.T, dir string, mutate func(*Config)) *Supervisor {
	t.Helper()
	cfg := Config{
		Bin:            os.Args[0],
		Model:          "talker.gguf",
		Codec:          "codec.gguf",
		Port:           testutil.FreePort(t),
		MaxBatch:       1,
		StartupTimeout: 15 * time.Second,
		HealthPoll:     10 * time.Millisecond,
		KillGrace:      2 * time.Second,
		LogDir:         filepath.Join(dir, "logs"),
		PidPath:        filepath.Join(dir, "run", "engine.pid"),
	}
	if mutate != nil {
		mutate(&cfg)
	}
	sup, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(sup.Shutdown)
	return sup
}

func fakeEnv(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("OXSAY_FAKE_CHILD", "1")
	t.Setenv("OXSAY_FAKE_DIR", dir)
}

// T1 — idle stop: Ready with no guards and a 1s idle limit must reach Stopped
// within 5s, and the child process must be gone.
// Mutation: in idleLoop replace `time.Since(s.lastActivity) >= s.cfg.IdleStop`
// with `false` -> RED.
func TestIdleStop(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.IdleStop = time.Second
		c.IdleTick = 25 * time.Millisecond
	})
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	if sup.State() != StateReady {
		t.Fatalf("state = %s, want ready", sup.State())
	}
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return sup.State() == StateStopped
	}, "idle stop")
	if got := testutil.SpawnStamps(t, dir); got != 1 {
		t.Fatalf("spawn stamps = %d, want 1", got)
	}
}

// T2 — a held Guard blocks idle stop past the limit.
// Mutation: drop `s.guards == 0` from the idle condition -> RED.
func TestGuardBlocksIdleStop(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.IdleStop = 300 * time.Millisecond
		c.IdleTick = 25 * time.Millisecond
	})
	base, err := sup.EnsureReady(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	g := sup.Acquire()
	defer g.Release()
	// Engine stays up well past the idle limit while the guard is held.
	time.Sleep(900 * time.Millisecond)
	if sup.State() != StateReady {
		t.Fatalf("state = %s, want ready (guard held)", sup.State())
	}
	resp, err := http.Get(base + "/health")
	if err != nil {
		t.Fatalf("child not serving while guard held: %v", err)
	}
	_ = resp.Body.Close()
}

// T3 — single-flight: 10 concurrent EnsureReady calls on a stopped
// supervisor must spawn exactly one child, even with a slow (500ms) start.
// Mutation: remove the single-flight/lock around start -> RED.
func TestSingleFlightStart(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "500")
	sup := newTestSupervisor(t, dir, nil)

	const n = 10
	var wg sync.WaitGroup
	errs := make([]error, n)
	urls := make([]string, n)
	for i := range n {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			u, err := sup.EnsureReady(context.Background())
			urls[i], errs[i] = u, err
		}(i)
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("EnsureReady[%d]: %v", i, err)
		}
	}
	for i, u := range urls {
		want := fmt.Sprintf("http://127.0.0.1:%d", sup.cfg.Port)
		if u != want {
			t.Fatalf("url[%d] = %q, want %q", i, u, want)
		}
	}
	if got := testutil.SpawnStamps(t, dir); got != 1 {
		t.Fatalf("spawn stamps = %d, want exactly 1", got)
	}
	if sup.Status().Starts != 1 {
		t.Fatalf("starts = %d, want 1", sup.Status().Starts)
	}
}

// T4 — crash then restart: a child that exits on its own leaves the
// supervisor Crashed; the next EnsureReady spawns again and reaches Ready.
// Mutation: make EnsureReady return an error when state is Crashed -> RED.
func TestCrashThenRestart(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_EXIT_MS", "300")
	t.Setenv("OXSAY_FAKE_EXIT_ONCE", "1")
	sup := newTestSupervisor(t, dir, nil)

	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return sup.State() == StateCrashed
	}, "crash detection")

	// Next EnsureReady must restart (after ~1s backoff) and reach Ready.
	base, err := sup.EnsureReady(context.Background())
	if err != nil {
		t.Fatalf("restart after crash: %v", err)
	}
	if sup.State() != StateReady {
		t.Fatalf("state = %s, want ready", sup.State())
	}
	resp, err := http.Get(base + "/health")
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if got := testutil.SpawnStamps(t, dir); got != 2 {
		t.Fatalf("spawn stamps = %d, want 2", got)
	}
	if sup.Status().Restarts != 1 {
		t.Fatalf("restarts = %d, want 1", sup.Status().Restarts)
	}
}

// A start that fails (binary exits instantly / cannot serve) must return an
// error to the caller — this is what the HTTP layer maps to 503 — while the
// next call may still retry after backoff.
func TestFailedStartReturnsError(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.Bin = "/bin/false" // spawns, exits instantly, never serves /health
		c.StartupTimeout = 3 * time.Second
	})
	_, err := sup.EnsureReady(context.Background())
	if err == nil {
		t.Fatal("EnsureReady with a failing engine returned no error")
	}
	if sup.State() != StateStopped {
		t.Fatalf("state = %s, want stopped", sup.State())
	}
	if sup.Status().LastErr == "" {
		t.Fatal("Status.LastErr is empty after a failed start")
	}
}

// Shutdown racing an in-flight start must not leave the just-spawned child
// running: it would hold the engine port (and, on the real engine, ~2 GB of
// GPU). Probe: after Shutdown returns, the child's port is bindable again.
func TestShutdownDuringStartupKillsChild(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "800") // widen the race window
	var port int
	sup := newTestSupervisor(t, dir, func(c *Config) {
		port = c.Port
	})
	done := make(chan error, 1)
	go func() {
		_, err := sup.EnsureReady(context.Background())
		done <- err
	}()
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return sup.State() == StateStarting
	}, "engine starting")
	sup.Shutdown()
	if err := <-done; err == nil {
		t.Fatal("EnsureReady succeeded despite shutdown")
	}
	testutil.WaitFor(t, 5*time.Second, func() bool {
		ln, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port))
		if err != nil {
			return false
		}
		_ = ln.Close()
		return true
	}, "engine port freed after shutdown")
}

// Orphan reap: a live pidfile process whose exe is the configured binary is
// killed at New(); a pidfile naming a *different* executable is left alone.
func TestReapOrphan(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	runDir := filepath.Join(dir, "run")
	if err := os.MkdirAll(runDir, 0o755); err != nil {
		t.Fatal(err)
	}
	pidPath := filepath.Join(runDir, "engine.pid")
	port := testutil.FreePort(t)

	// Positive: fake child started by hand, pidfile written, Bin == test binary.
	orphan := exec.Command(os.Args[0], "--port", strconv.Itoa(port))
	orphan.Env = os.Environ()
	if err := orphan.Start(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(orphan.Process.Pid)), 0o644); err != nil {
		t.Fatal(err)
	}
	// Reap concurrently: until Wait runs the killed orphan is a zombie and
	// kill(pid,0) still reports it alive.
	waitDone := make(chan struct{})
	go func() { _ = orphan.Wait(); close(waitDone) }()
	sup := newTestSupervisor(t, dir, func(c *Config) { c.Port = port })
	defer sup.Shutdown()
	testutil.WaitFor(t, 3*time.Second, func() bool {
		return !processAlive(orphan.Process.Pid)
	}, "orphan kill")
	<-waitDone

	// Negative: pidfile names a live process that is NOT the engine binary.
	sleeper := exec.Command("sleep", "5")
	if err := sleeper.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = sleeper.Process.Kill()
		_ = sleeper.Wait()
	}()
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(sleeper.Process.Pid)), 0o644); err != nil {
		t.Fatal(err)
	}
	sup2 := newTestSupervisor(t, dir, func(c *Config) { c.Port = testutil.FreePort(t) })
	defer sup2.Shutdown()
	time.Sleep(200 * time.Millisecond)
	if !processAlive(sleeper.Process.Pid) {
		t.Fatal("unrelated process was killed by orphan reap")
	}
}
