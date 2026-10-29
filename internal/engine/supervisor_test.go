package engine

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
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

// LiveURL must not hand out a child the idle loop is stopping: the stop
// commits (child.userStop, state=Stopped) under s.mu while killChild's
// SIGTERM→SIGKILL escalation still waits on the process, so s.child is set
// and dying for up to KillGrace. The fake child ignores SIGTERM, which
// holds that window open deterministically — no sleep-and-hope: the child
// cannot exit before the grace SIGKILL, and userStop is already stamped
// when Stopped is observed.
// Mutation: drop the !s.child.userStop check in LiveURL -> RED (the dying
// child's URL is returned).
func TestLiveURLSkipsStoppingChild(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_IGNORE_SIGTERM", "1")
	var pidPath string
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.IdleStop = 300 * time.Millisecond
		c.IdleTick = 20 * time.Millisecond
		// Long grace: the ignored SIGTERM leaves the child alive until the
		// SIGKILL, so it is provably still up when the assertions run.
		c.KillGrace = 30 * time.Second
		pidPath = c.PidPath
	})
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, ok := sup.LiveURL(); !ok {
		t.Fatal("LiveURL reported no child on a ready engine")
	}

	testutil.WaitFor(t, 5*time.Second, func() bool {
		return sup.State() == StateStopped
	}, "idle stop commit")

	// The stop is committed but the child cannot have exited yet (SIGTERM
	// ignored, SIGKILL 30 s out): LiveURL must refuse to hand it out.
	pid := childPid(t, pidPath)
	// End the grace wait whatever the outcome: the SIGTERM-ignoring child
	// would otherwise keep the Shutdown cleanup waiting in killChild for
	// the full KillGrace. Runs before Shutdown (cleanups are LIFO); an
	// already-dead pid just yields ESRCH.
	t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) })
	if !processAlive(pid) {
		t.Fatal("the stopping child exited before its grace deadline")
	}
	if url, ok := sup.LiveURL(); ok {
		t.Fatalf("LiveURL = %q for a child the idle loop is stopping", url)
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
	bin := falseBin(t)
	dir := t.TempDir()
	fakeEnv(t, dir)
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.Bin = bin // spawns, exits instantly, never serves /health
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

// Every caller that waited on a failed start generation gets its error —
// not just the one that happened to re-acquire the lock first — and a
// failed attempt is not re-launched per waiter.
func TestFailedStartNotifiesAllWaiters(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	bin := falseBin(t)
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.Bin = bin
		c.StartupTimeout = 3 * time.Second
	})

	const n = 5
	errs := make([]error, n)
	var wg sync.WaitGroup
	for i := range n {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, errs[i] = sup.EnsureReady(context.Background())
		}(i)
	}
	wg.Wait()
	for i, err := range errs {
		if err == nil {
			t.Fatalf("waiter %d got no error from a failed start", i)
		}
		if !strings.Contains(err.Error(), "start failed") {
			t.Fatalf("waiter %d error = %v, want a start-failed report", i, err)
		}
	}
	if got := sup.Status().Starts; got != 1 {
		t.Fatalf("starts = %d, want 1 (waiters share one attempt)", got)
	}
}

// A child that exits after /health succeeded — during the Replay step —
// must NOT be committed Ready: onExit may already have reaped it, so the
// start attempt counts as failed. And the supervisor must not wedge: the
// next EnsureReady starts a fresh child.
// Mutation: drop the s.child==c / c.done re-check in finishStart -> RED
// (Ready is committed on a dead child and EnsureReady returns a URL).
func TestExitAfterHealthFailsStart(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	var pidPath string
	var killOnce sync.Once
	var sup *Supervisor
	sup = newTestSupervisor(t, dir, func(c *Config) {
		pidPath = c.PidPath
		c.Replay = func(context.Context, string) error {
			// The first child dies right after /health passed; later
			// generations are left alone.
			killOnce.Do(func() {
				data, err := os.ReadFile(pidPath)
				if err != nil {
					return
				}
				pid, _, ok := parsePidFile(data)
				if !ok {
					return
				}
				_ = syscall.Kill(pid, syscall.SIGKILL)
			})
			// Replay returns only once the waiter has reaped the child —
			// the point of the test is the deterministic ordering:
			// finishStart must see the death instead of committing Ready.
			deadline := time.Now().Add(5 * time.Second)
			for time.Now().Before(deadline) {
				sup.mu.Lock()
				gone := sup.child == nil
				sup.mu.Unlock()
				if gone {
					return nil
				}
				time.Sleep(5 * time.Millisecond)
			}
			return fmt.Errorf("child still registered after kill")
		}
	})

	if _, err := sup.EnsureReady(context.Background()); err == nil {
		t.Fatal("EnsureReady returned success although the child died after /health")
	}
	if st := sup.State(); st != StateStopped {
		t.Fatalf("state = %s, want stopped", st)
	}

	// Not wedged: the next EnsureReady waits out the backoff and respawns.
	base, err := sup.EnsureReady(context.Background())
	if err != nil {
		t.Fatalf("restart after post-health exit: %v", err)
	}
	resp, err := http.Get(base + "/health")
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if sup.State() != StateReady {
		t.Fatalf("state = %s, want ready", sup.State())
	}
	if got := testutil.SpawnStamps(t, dir); got != 2 {
		t.Fatalf("spawn stamps = %d, want 2", got)
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

// #347: Shutdown returns only when nothing the supervisor started can still write into its data dir. EnsureReady
// returns ErrShutdown at once, so a start attempt that was still before the spawn (Prepare, the log open, exec) kept
// running after Shutdown: it created engine.log and the pidfile, spawned a child and killed it, while the owner was
// already removing the directory ("TempDir RemoveAll cleanup: directory not empty", ~1 in 3000 runs under load).
// Mutation: supervisor.go Shutdown, delete the `s.bg.Wait()` wait (the bounded wait for run and waiter goroutines)
// -> RED (Shutdown returns while Prepare is still blocked). Mutation: run(), delete the shutdown check before
// spawn -> RED (a child is spawned and engine.log created after Shutdown).
func TestShutdownWaitsForAStartBeforeSpawn(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	entered, release := make(chan struct{}), make(chan struct{})
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.Prepare = func() error {
			close(entered)
			<-release
			return nil
		}
	})
	go func() { _, _ = sup.EnsureReady(context.Background()) }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("the start attempt never reached Prepare")
	}
	returned := make(chan struct{})
	go func() {
		sup.Shutdown()
		close(returned)
	}()
	select {
	case <-returned:
		t.Fatal("Shutdown returned while a start attempt was still running")
	case <-time.After(300 * time.Millisecond):
	}
	close(release)
	select {
	case <-returned:
	case <-time.After(5 * time.Second):
		t.Fatal("Shutdown did not return after the start attempt ended")
	}
	// Nothing was spawned for a supervisor that was already shut down: no child, no log, no pidfile.
	for _, name := range []string{"logs", "run"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			t.Errorf("%s/ was created after Shutdown", name)
		}
	}
	if m, _ := filepath.Glob(filepath.Join(dir, "spawn-*")); len(m) != 0 {
		t.Errorf("a child was spawned after Shutdown: %v", m)
	}
}

// #347: the waiter's exit handler removes the pidfile after it publishes the exit, so Shutdown (which waits for the
// exit) used to return with that removal still pending. Holding the pidfile lock keeps the handler there: Shutdown
// must wait for it, and the pidfile is gone when it returns.
// Mutation: supervisor.go spawn, start the waiter without the bg.Add(1)/Done wrapper (`go s.waiter(c)`) -> RED
// (Shutdown returns while the handler is blocked).
func TestShutdownWaitsForTheExitHandler(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "800")
	sup := newTestSupervisor(t, dir, nil)
	pidPath := sup.cfg.PidPath
	go func() { _, _ = sup.EnsureReady(context.Background()) }()
	testutil.WaitFor(t, 5*time.Second, func() bool {
		sup.mu.Lock()
		defer sup.mu.Unlock()
		return sup.child != nil
	}, "child registered")
	sup.pidMu.Lock() // the exit handler's pidfile removal now blocks
	returned := make(chan struct{})
	go func() {
		sup.Shutdown()
		close(returned)
	}()
	select {
	case <-returned:
		sup.pidMu.Unlock()
		t.Fatal("Shutdown returned while the exit handler was still pending")
	case <-time.After(300 * time.Millisecond):
	}
	sup.pidMu.Unlock()
	select {
	case <-returned:
	case <-time.After(5 * time.Second):
		t.Fatal("Shutdown did not return after the exit handler finished")
	}
	if _, err := os.Stat(pidPath); err == nil {
		t.Error("the pidfile outlived Shutdown")
	}
}

// A wedged child (its exit never observed) costs Shutdown one more grace period, not two: the wait for the start
// attempt and exit handler is skipped once the exit wait has timed out.
// Mutation: supervisor.go Shutdown, delete the `if exitMissed { return }` block -> RED by assertion (the second wait is entered).
func TestShutdownWedgedChildCostsOneGrace(t *testing.T) {
	dir := t.TempDir()
	const grace = 300 * time.Millisecond
	sup := newTestSupervisor(t, dir, func(c *Config) { c.KillGrace = grace })
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
	sup.mu.Lock()
	sup.child = &child{cmd: cmd, done: make(chan struct{})} // done is never closed: the exit is never observed
	sup.mu.Unlock()
	sup.bg.Add(1) // a stuck exit handler
	t.Cleanup(sup.bg.Done)
	sup.Shutdown()
	if n := sup.bgWaits.Load(); n != 0 {
		t.Errorf("Shutdown entered the start-attempt wait %d times after the exit wait timed out, want 0", n)
	}
}

// Shutdown landing after /health — while run() sits in the Replay step —
// must still kill the child and must be reported as a shutdown, not a
// crash. Mutation: drop the s.dead check in finishStart -> RED (last
// error reports an unexpected exit instead of a shutdown).
func TestShutdownDuringReplayKillsChild(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	replayEntered := make(chan struct{})
	releaseReplay := make(chan struct{})
	var port int
	sup := newTestSupervisor(t, dir, func(c *Config) {
		port = c.Port
		c.Replay = func(context.Context, string) error {
			close(replayEntered)
			<-releaseReplay // run() waits here while Shutdown lands
			return nil
		}
	})
	done := make(chan error, 1)
	go func() {
		_, err := sup.EnsureReady(context.Background())
		done <- err
	}()
	<-replayEntered // engine is past /health, inside Replay
	sup.Shutdown()  // kills the child, waits for its exit, returns
	close(releaseReplay)
	if err := <-done; err == nil {
		t.Fatal("EnsureReady succeeded despite shutdown")
	}
	// EnsureReady may return on the dead broadcast before run()'s
	// finishStart records the outcome — wait for the start to settle.
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return sup.State() == StateStopped
	}, "shutdown-aborted start to settle")
	if lastErr := sup.Status().LastErr; !strings.Contains(lastErr, "shut down") {
		t.Fatalf("last error = %q, want a shutdown report", lastErr)
	}
	testutil.WaitFor(t, 5*time.Second, func() bool {
		ln, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port))
		if err != nil {
			return false
		}
		_ = ln.Close()
		return true
	}, "engine port freed after shutdown-during-replay")
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
	ports := testutil.FreePorts(t, 2)
	port := ports[0]

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
	sup2 := newTestSupervisor(t, dir, func(c *Config) { c.Port = ports[1] })
	defer sup2.Shutdown()
	time.Sleep(200 * time.Millisecond)
	if !processAlive(sleeper.Process.Pid) {
		t.Fatal("unrelated process was killed by orphan reap")
	}
}

// falseBin is the path of `false`: /bin/false on Linux, /usr/bin/false on macOS.
func falseBin(t *testing.T) string {
	t.Helper()
	p, err := exec.LookPath("false")
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// A child that reaches Ready and then crashes must keep escalating its
// backoff: clearing the failure count on every Ready commit would reload the
// model every second forever for an engine that dies on each request.
// Mutation: set s.failCount = 0 at the Ready commit in finishStart -> RED
// ("after crash 2 failCount = 1, want 2").
func TestCrashBackoffEscalatesAcrossReady(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_EXIT_MS", "300")
	sup := newTestSupervisor(t, dir, nil)
	for i := 1; i <= 2; i++ {
		if _, err := sup.EnsureReady(context.Background()); err != nil {
			t.Fatal(err)
		}
		testutil.WaitFor(t, 5*time.Second, func() bool {
			return sup.State() == StateCrashed
		}, "crash detection")
		sup.mu.Lock()
		got := sup.failCount
		sup.mu.Unlock()
		if got != i {
			t.Fatalf("after crash %d failCount = %d, want %d", i, got, i)
		}
	}
}

// A start that is quick to serve must not wait out a fixed health-poll
// tick: the first dictation's session create after an idle stop pays it —
// every wait landed on the second 250 ms tick (~510 ms) while the spawned
// ox-stt was already serving. A child whose /health turns 200 ~30 ms into
// the start must be reported ready well under one production tick.
// Mutation: restore `case <-time.After(250 * time.Millisecond)` as the only
// wait in waitHealthy (sleep 250 ms before the first probe) -> RED (>= 250 ms).
func TestFastStartDoesNotWaitOutHealthPoll(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "30")
	sup := newTestSupervisor(t, dir, nil)
	start := time.Now()
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	if el := time.Since(start); el >= 200*time.Millisecond {
		t.Fatalf("EnsureReady on a ~30ms-ready child took %s — it waited out a fixed health-poll tick", el)
	}
}

// A child that never answers /health still fails at the StartupTimeout
// deadline — the finer early probes must neither shorten nor skip it.
func TestNeverHealthyFailsAtStartupDeadline(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "60000") // never ready in-budget
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.StartupTimeout = 400 * time.Millisecond
	})
	start := time.Now()
	_, err := sup.EnsureReady(context.Background())
	el := time.Since(start)
	if err == nil {
		t.Fatal("EnsureReady succeeded although the child never became healthy")
	}
	if !strings.Contains(err.Error(), "did not become healthy") {
		t.Fatalf("EnsureReady error = %v, want the startup-deadline report", err)
	}
	if el < 350*time.Millisecond {
		t.Fatalf("EnsureReady failed after %s — before the %s startup deadline", el, 400*time.Millisecond)
	}
	if el > 5*time.Second {
		t.Fatalf("EnsureReady took %s — it did not honour the %s startup deadline", el, 400*time.Millisecond)
	}
}

// The resident ox-stt becomes healthy in the (250, 500] ms window — every
// cold session create in the live log lands at 509-521 ms. With the backoff
// capped at the old fixed 250 ms health poll, such readiness was only
// reported on the ~560 ms grid point, slower than the fixed wait it
// replaced. The startup probes are capped by healthProbeMax (25 ms), so a
// child whose /health turns 200 ~350 ms into the start must be reported
// under 450 ms (358-386 ms measured under -race).
// Mutation: cap the backoff at a fixed 250 ms instead of healthProbeMax
// in waitHealthy -> RED (readiness caught on the ~560 ms tick, ~578 ms).
func TestMidWindowHealthCaughtWithinProbeCap(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "350")
	sup := newTestSupervisor(t, dir, nil)
	start := time.Now()
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	if el := time.Since(start); el >= 450*time.Millisecond {
		t.Fatalf("EnsureReady on a ~350ms-ready child took %s — startup probes are not on the ≤25 ms grid", el)
	}
}

// A start that ran out of time says so in a way callers can tell from a crash or a refused check: the notes run
// records "did not answer in time" for the user, not the English text.
// Mutation: internal/engine/supervisor.go waitHealthy, return `fmt.Errorf("engine did not become healthy within %s", s.cfg.StartupTimeout)`
// in place of `&startTimeout{...}` -> RED.
func TestAHealthTimeoutIsATypedStartTimeout(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "60000")
	sup := newTestSupervisor(t, dir, func(c *Config) { c.StartupTimeout = 300 * time.Millisecond })
	_, err := sup.EnsureReady(context.Background())
	if !IsStartTimeout(err) {
		t.Fatalf("err = %v, want a start timeout", err)
	}
	if IsStartTimeout(errors.New("engine did not become healthy")) || IsStartTimeout(nil) || IsStartTimeout(&verifyFailure{errors.New("x")}) {
		t.Fatal("only the supervisor's own timeout is a start timeout")
	}
}
