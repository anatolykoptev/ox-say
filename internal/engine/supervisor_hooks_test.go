package engine

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

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

// Backoff exposes the restart cool-down a NEW EnsureReady caller would
// sleep out: 0 before the first start, >0 inside the window after a failed
// start, and 0 again once the engine is Ready. The daemon's STT path
// consults it to take the CLI fallback instead of paying the wait.
// Mutation: stub Backoff to always return 0 -> RED ("Backoff right after a
// failed start" stays 0); drop the Ready/Starting/child guard and return
// the raw time.Until -> RED (a caller mid-start would see a positive wait).
func TestBackoff(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.Bin = falseBin(t) // spawns, exits instantly, never serves /health
		c.StartupTimeout = 3 * time.Second
	})

	if got := sup.Backoff(); got != 0 {
		t.Fatalf("Backoff on a fresh supervisor = %s, want 0", got)
	}
	if _, err := sup.EnsureReady(context.Background()); err == nil {
		t.Fatal("EnsureReady with a failing binary returned no error")
	}
	if got := sup.Backoff(); got <= 0 {
		t.Fatalf("Backoff right after a failed start = %s, want > 0", got)
	}

	// A working child past the window commits Ready and the cool-down ends.
	sup.cfg.Bin = os.Args[0]
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatalf("restart after backoff: %v", err)
	}
	if sup.State() != StateReady {
		t.Fatalf("state = %s, want ready", sup.State())
	}
	if got := sup.Backoff(); got != 0 {
		t.Fatalf("Backoff once ready = %s, want 0", got)
	}
}

// Issue #7: a caller that enters EnsureReady while a start attempt is in
// flight must receive that attempt's error even when the attempt concludes
// before the caller first takes s.mu — it overlapped the attempt, so it is
// a waiter, not a post-failure arrival that retries after the backoff. A
// caller entering only after the conclusion still retries: the recorded
// error is not consumed, the backoff is slept out, and a new attempt runs.
// ensureEntryHook parks the two callers between their entry stamp and the
// first s.mu acquisition — exactly the window the bug lives in — so the
// interleaving needs no sleeps.
// Mutation: drop the `!enteredAt.After(s.attemptDoneAt)` disjunct in
// EnsureReady's default branch (attemptGen == waitGen alone decides) ->
// RED: the parked callers sleep out the backoff and launch a second
// attempt instead of returning attempt 1's error, so they are still
// inside that attempt's wait when the receive deadline hits.
func TestEnsureReadyEnteredDuringStartGetsError(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	// /health stays 503: the attempt is in flight until the test kills the
	// child, which is what makes the parking below exact rather than timed.
	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "120000")
	pidPath := filepath.Join(dir, "run", "engine.pid")
	sup := newTestSupervisor(t, dir, func(c *Config) {
		c.StartupTimeout = 60 * time.Second // backstop only; the test kills each child
	})

	var gate sync.Mutex
	park := false
	entered := make(chan struct{}, 4)
	release := make(chan struct{})
	sup.ensureEntryHook = func() {
		gate.Lock()
		p := park
		gate.Unlock()
		if !p {
			return
		}
		entered <- struct{}{}
		<-release
	}

	// Attempt 1 launches and stays in flight (child alive, never healthy).
	launcherErr := make(chan error, 1)
	go func() {
		_, err := sup.EnsureReady(context.Background())
		launcherErr <- err
	}()
	testutil.WaitFor(t, 10*time.Second, func() bool {
		data, err := os.ReadFile(pidPath)
		return err == nil && len(data) > 0
	}, "attempt 1 pidfile")

	// Two callers enter and park before their first s.mu acquisition.
	gate.Lock()
	park = true
	gate.Unlock()
	errs := make(chan error, 2)
	for range 2 {
		go func() {
			_, err := sup.EnsureReady(context.Background())
			errs <- err
		}()
	}
	<-entered
	<-entered

	// Attempt 1 concludes while both callers sit between their entry stamp
	// and their first lock; the launcher's returned error proves the
	// conclusion was recorded.
	pid := childPid(t, pidPath)
	if err := syscall.Kill(pid, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	if err := <-launcherErr; err == nil {
		t.Fatal("the launching caller got no error from the killed start")
	}
	close(release)

	// Both overlapped the attempt and must get its error, not a retry.
	for range 2 {
		select {
		case err := <-errs:
			if err == nil {
				t.Fatal("a caller parked across the conclusion got no error")
			}
			if !strings.Contains(err.Error(), "start failed") {
				t.Fatalf("parked caller's error = %v, want the start failure", err)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("a caller that overlapped the failed attempt slept out the backoff instead of getting its error")
		}
	}
	if got := sup.Status().Starts; got != 1 {
		t.Fatalf("starts = %d, want 1 — an overlapped caller launched a new attempt", got)
	}

	// A caller entering only now — after attempt 1 concluded — must not
	// consume its error: it waits out the backoff and launches attempt 2.
	gate.Lock()
	park = false
	gate.Unlock()
	lateErr := make(chan error, 1)
	go func() {
		_, err := sup.EnsureReady(context.Background())
		lateErr <- err
	}()
	testutil.WaitFor(t, 10*time.Second, func() bool {
		return sup.Status().Starts == 2
	}, "the post-failure caller to launch a second attempt after the backoff")
	// The pidfile is briefly absent between onExit's removal and the next
	// spawn's write — read it inside the poll, never t.Fatal there.
	var pid2 int
	testutil.WaitFor(t, 10*time.Second, func() bool {
		pid2 = readPidfile(pidPath)
		return pid2 > 0 && pid2 != pid
	}, "attempt 2 pidfile to carry a new pid")
	if err := syscall.Kill(pid2, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-lateErr:
		if err == nil {
			t.Fatal("the post-failure caller's retried attempt returned no error")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the post-failure caller's retried attempt did not conclude")
	}
}

// childPid reads the pid the supervisor's pidfile currently names.
func childPid(t *testing.T, pidPath string) int {
	t.Helper()
	if pid := readPidfile(pidPath); pid > 0 {
		return pid
	}
	t.Fatalf("cannot read pidfile %s", pidPath)
	return -1
}

// readPidfile returns the pid named by the pidfile, or -1 when the file is
// missing or unparsable — safe to poll: onExit removes the file before the
// next spawn rewrites it.
func readPidfile(pidPath string) int {
	data, err := os.ReadFile(pidPath)
	if err != nil {
		return -1
	}
	pid, _, ok := parsePidFile(data)
	if !ok {
		return -1
	}
	return pid
}
