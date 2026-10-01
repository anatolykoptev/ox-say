//go:build darwin

package engine

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// The orphan reaper must kill only a pid whose exec path exactly matches
// the configured engine binary. A pidfile naming a live process with a
// different exec path — a reused pid — must be left alone, even if the
// process's argv[0] happens to look like the engine's name.
func TestReapOrphanExeMatch(t *testing.T) {
	dir := t.TempDir()
	pidPath := filepath.Join(dir, "engine.pid")

	newSup := func(bin string) *Supervisor {
		s, err := New(Config{
			Bin:       bin,
			Port:      43210,
			PidPath:   pidPath,
			KillGrace: 200 * time.Millisecond,
		})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(s.Shutdown)
		return s
	}

	// Negative: /bin/sleep under a pidfile while the configured engine is
	// something else must survive.
	sleeper := exec.Command("/bin/sleep", "30")
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
	newSup("/bin/sh")
	time.Sleep(300 * time.Millisecond)
	if !processAlive(sleeper.Process.Pid) {
		t.Fatal("orphan reaper killed a process whose exec path did not match")
	}

	// Positive: a live process whose exec path IS the configured binary is
	// killed at New().
	victim := exec.Command("/bin/sleep", "30")
	if err := victim.Start(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(victim.Process.Pid)), 0o644); err != nil {
		t.Fatal(err)
	}
	waitDone := make(chan struct{})
	go func() { _ = victim.Wait(); close(waitDone) }()
	newSup("/bin/sleep")
	deadline := time.Now().Add(3 * time.Second)
	for processAlive(victim.Process.Pid) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if processAlive(victim.Process.Pid) {
		t.Fatal("orphan reaper left a matching process alive")
	}
	<-waitDone
}

// The darwin start token is kern.proc.pid's p_starttime rendered
// "<sec>.<usec>" with the usec field zero-padded to 6 digits.
func TestProcessStartTimeFormat(t *testing.T) {
	tok, err := processStartTime(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	sec, usec, ok := strings.Cut(tok, ".")
	if !ok {
		t.Fatalf("start token %q is not <sec>.<usec>", tok)
	}
	if _, err := strconv.ParseUint(sec, 10, 64); err != nil {
		t.Fatalf("start token %q: bad sec field: %v", tok, err)
	}
	if len(usec) != 6 {
		t.Fatalf("start token %q: usec field is not 6 digits", tok)
	}
	if _, err := strconv.ParseUint(usec, 10, 32); err != nil {
		t.Fatalf("start token %q: bad usec field: %v", tok, err)
	}

	// A dead pid has no start time to read.
	c := exec.Command("true")
	if err := c.Run(); err != nil {
		t.Fatal(err)
	}
	if _, err := processStartTime(c.Process.Pid); err == nil {
		t.Fatal("start token read for a reaped process")
	}
}
