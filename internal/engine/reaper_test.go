package engine

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// The start token must be an opaque but stable identity of a process's
// start instant: two reads of one process agree, and two processes spawned
// 50 ms apart disagree. Linux stamps clock ticks (HZ >= 100, so 50 ms is
// several ticks); darwin stamps "<sec>.<usec>".
func TestProcessStartTimeStableAndDistinct(t *testing.T) {
	tok1, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if tok1 == "" {
		t.Fatal("empty start token")
	}
	tok2, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if tok1 != tok2 {
		t.Fatalf("start token not stable across reads: %q then %q", tok1, tok2)
	}

	spawnSleeper := func() *exec.Cmd {
		t.Helper()
		c := exec.Command("sleep", "30")
		if err := c.Start(); err != nil {
			t.Fatal(err)
		}
		return c
	}
	a := spawnSleeper()
	defer func() {
		_ = a.Process.Kill()
		_ = a.Wait()
	}()
	time.Sleep(50 * time.Millisecond)
	b := spawnSleeper()
	defer func() {
		_ = b.Process.Kill()
		_ = b.Wait()
	}()
	tokA, err := processStartTime(a.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	tokB, err := processStartTime(b.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	if tokA == tokB {
		t.Fatalf("two processes spawned 50ms apart share start token %q", tokA)
	}
}

// fakeOrphan starts the test binary re-exec'd as the fake engine, so its
// exec path matches Config.Bin in a test supervisor — the same pattern
// TestReapOrphan uses.
func fakeOrphan(t *testing.T, port int) *exec.Cmd {
	t.Helper()
	c := exec.Command(os.Args[0], "--port", strconv.Itoa(port))
	c.Env = os.Environ()
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	return c
}

func reapTestDir(t *testing.T) (dir, pidPath string) {
	t.Helper()
	dir = t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "run"), 0o755); err != nil {
		t.Fatal(err)
	}
	return dir, filepath.Join(dir, "run", "engine.pid")
}

// The pidfile names a live process running the configured binary but its
// recorded start token is not the process's own — the signature of a pid
// recycled onto a same-binary process (a hand-started tts-server, a second
// home sharing the binary). The process must be left running.
// Mutation: drop the start-token comparison in reapOrphan -> RED.
func TestReapOrphanWrongStartToken(t *testing.T) {
	dir, pidPath := reapTestDir(t)
	fakeEnv(t, dir)

	orphan := fakeOrphan(t, testutil.FreePort(t))
	// A killed-but-unwaited child is a zombie and kill(pid,0) still reports
	// it alive — survival must be asserted on Wait not returning, not on
	// processAlive.
	waitDone := make(chan struct{})
	go func() { _ = orphan.Wait(); close(waitDone) }()
	defer func() {
		_ = orphan.Process.Kill()
		<-waitDone
	}()
	token, err := processStartTime(orphan.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	// The process's own token perturbed — guaranteed to differ while still
	// looking like a real token.
	wrong := token + "0"
	if err := os.WriteFile(pidPath,
		[]byte(fmt.Sprintf("%d %s\n", orphan.Process.Pid, wrong)), 0o644); err != nil {
		t.Fatal(err)
	}

	_ = newTestSupervisor(t, dir, func(c *Config) { c.Port = testutil.FreePort(t) })
	// The fake child does not trap SIGTERM, so a kill would surface here
	// within milliseconds; 500ms leaves ample slack on a loaded box.
	select {
	case <-waitDone:
		t.Fatal("reaper killed a process whose pidfile start token did not match")
	case <-time.After(500 * time.Millisecond):
	}
}

// The same pidfile carrying the process's OWN start token is a real orphan:
// killed at New().
func TestReapOrphanMatchingStartToken(t *testing.T) {
	dir, pidPath := reapTestDir(t)
	fakeEnv(t, dir)

	orphan := fakeOrphan(t, testutil.FreePort(t))
	token, err := processStartTime(orphan.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pidPath,
		[]byte(fmt.Sprintf("%d %s\n", orphan.Process.Pid, token)), 0o644); err != nil {
		t.Fatal(err)
	}
	waitDone := make(chan struct{})
	go func() { _ = orphan.Wait(); close(waitDone) }()

	_ = newTestSupervisor(t, dir, func(c *Config) { c.Port = testutil.FreePort(t) })
	testutil.WaitFor(t, 3*time.Second, func() bool {
		return !processAlive(orphan.Process.Pid)
	}, "orphan kill")
	<-waitDone
}

// Backwards compatibility: a pidfile written by v0.1.6 or earlier is a bare
// pid with no token. For those the exe-only rule is kept so an upgrade
// still reaps the previous version's orphaned engine.
func TestReapOrphanOldFormatPidfile(t *testing.T) {
	dir, pidPath := reapTestDir(t)
	fakeEnv(t, dir)

	orphan := fakeOrphan(t, testutil.FreePort(t))
	if err := os.WriteFile(pidPath,
		[]byte(strconv.Itoa(orphan.Process.Pid)), 0o644); err != nil {
		t.Fatal(err)
	}
	waitDone := make(chan struct{})
	go func() { _ = orphan.Wait(); close(waitDone) }()

	_ = newTestSupervisor(t, dir, func(c *Config) { c.Port = testutil.FreePort(t) })
	testutil.WaitFor(t, 3*time.Second, func() bool {
		return !processAlive(orphan.Process.Pid)
	}, "orphan kill on an old-format pidfile")
	<-waitDone
}

// The supervisor stamps the token itself: a pidfile written by a real spawn
// names the child and carries the child's own start token. Every reaper test
// above writes its pidfile by hand, so without this one the write side could
// drop the token, and #6 would reopen through the bare-pid fallback, with
// every test green.
// Mutation: drop `content += " " + token` in writePidFile -> RED.
func TestSpawnWritesTheStartToken(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	sup := newTestSupervisor(t, dir, nil)
	if _, err := sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, "run", "engine.pid"))
	if err != nil {
		t.Fatal(err)
	}
	pid, token, ok := parsePidFile(data)
	if !ok {
		t.Fatalf("pidfile %q does not parse", data)
	}
	if want := sup.Status().PID; pid != want {
		t.Fatalf("pidfile names pid %d, the child is %d", pid, want)
	}
	if token == "" {
		t.Fatalf("pidfile %q carries no start token", data)
	}
	want, err := processStartTime(pid)
	if err != nil {
		t.Fatal(err)
	}
	if token != want {
		t.Fatalf("pidfile token %q, the child's own is %q", token, want)
	}
}
