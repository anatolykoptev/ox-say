package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/engine"
)

// #115: the engine children's pidfiles live in one directory per user, not in
// the run's scratch directory. A bench that is SIGKILLed leaves its children
// running; the supervisor's reaper finds them on the next start only through
// the pidfile, and a directory that is new every run is never looked in again.
// Mutation: proc.go pidDir, return a fresh MkdirTemp directory per call (the
// old per-run "run" directory under the scratch dir) -> RED.
func TestPidfilesLiveInOneStableDirectory(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", "")
	dir, err := pidDir()
	if err != nil {
		t.Fatal(err)
	}
	a, b := pidPath(dir, "tts"), pidPath(dir, "tts")
	if a != b {
		t.Fatalf("pidfile path differs between calls: %s vs %s", a, b)
	}
	if filepath.Base(a) != "tts.pid" {
		t.Fatalf("pidfile %s is not named after the child", a)
	}
	if !strings.HasPrefix(a, os.Getenv("HOME")) {
		t.Fatalf("pidfile %s is not under the user's cache", a)
	}
	st, err := os.Stat(filepath.Dir(a))
	if err != nil || st.Mode().Perm() != 0o700 {
		t.Fatalf("pidfile dir: %v %v, want a 0700 directory", st, err)
	}
}

// #115: two benches at once would each reap the other's live children from the
// shared pidfile directory, so the second one refuses to start.
// Mutation: proc.go lockRun, return nil without taking the lock -> RED.
func TestSecondBenchRefusesToStart(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", "")
	unlock, err := lockRun(pidDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lockRun(pidDir()); err == nil || !strings.Contains(err.Error(), "already running") {
		t.Fatalf("a second lock was granted or its error is unclear: %v", err)
	}
	unlock()
	again, err := lockRun(pidDir())
	if err != nil {
		t.Fatalf("the lock was not released: %v", err)
	}
	again()
}

// The entry point goes through the lock: a bench that finds it held does not run.
// Mutation: main.go runLocked, `unlock, err := lockRun(pidDir())` -> a no-op lock -> RED.
func TestRunLockedDoesNotRunWhileAnotherBenchHoldsTheLock(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", "")
	unlock, err := lockRun(pidDir())
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	ran := false
	err = runLocked(context.Background(), options{}, func(context.Context, options) error { ran = true; return nil })
	if ran || err == nil || !strings.Contains(err.Error(), "already running") {
		t.Fatalf("ran=%v err=%v, want a refusal", ran, err)
	}
}

// startChild fills its config through childConfig: the pidfile is the stable one.
// Mutation: proc.go childConfig, `cfg.PidPath = pidPath(name)` -> the old
// filepath.Join(work, "run", name+".pid") -> RED.
func TestChildConfigPutsThePidfileInTheStableDirectory(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", "")
	work := t.TempDir()
	cfg := childConfig(work, mustPidDir(t), "tts", 4242, engine.Config{})
	if cfg.PidPath != pidPath(mustPidDir(t), "tts") || strings.HasPrefix(cfg.PidPath, work) || cfg.Port != 4242 || cfg.Name != "tts" {
		t.Fatalf("config %+v", cfg)
	}
}

// Only EWOULDBLOCK means another bench is running; other flock errors are shown
// as they are.
// Mutation: proc.go lockRun, drop the errors.Is(err, syscall.EWOULDBLOCK) test
// (every failure is "already running") -> RED.
func TestLockRunTellsContentionFromOtherErrors(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", "")
	orig := flock
	defer func() { flock = orig }()
	flock = func(int, int) error { return syscall.ENOLCK }
	_, err := lockRun(pidDir())
	if err == nil || strings.Contains(err.Error(), "already running") || !errors.Is(err, syscall.ENOLCK) {
		t.Fatalf("ENOLCK: %v", err)
	}
	flock = func(int, int) error { return syscall.EWOULDBLOCK }
	if _, err := lockRun(pidDir()); err == nil || !strings.Contains(err.Error(), "already running") {
		t.Fatalf("EWOULDBLOCK: %v", err)
	}
}

// A cache directory that cannot be made does not stop the bench: no lock, no
// pidfile (so no reaping), a warning.
// Mutation: proc.go lockRun, return the pidDir error instead of a no-op lock
// -> RED; pidPath, return a path under "" -> RED.
func TestUnusableCacheDirectoryRunsWithoutLockOrReaping(t *testing.T) {
	blocker := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(blocker, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", blocker) // a cache dir under a regular file cannot be made
	t.Setenv("XDG_CACHE_HOME", filepath.Join(blocker, "c"))
	if p := pidPath("", "tts"); p != "" {
		t.Fatalf("pidPath %q, want none", p)
	}
	unlock, err := lockRun(pidDir())
	if err != nil || unlock == nil {
		t.Fatalf("lockRun: %v", err)
	}
	unlock()
	if cfg := childConfig(t.TempDir(), "", "tts", 1, engine.Config{}); cfg.PidPath != "" {
		t.Fatalf("PidPath %q, want none", cfg.PidPath)
	}
}

func mustPidDir(t *testing.T) string {
	t.Helper()
	dir, err := pidDir()
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

// #115.c5: runLocked resolves the pidfile directory once and hands it to the
// lock and, through the options, to every child's pidfile; evaluating it per
// use could put the lock and the pidfiles in different directories.
// Mutation: main.go runLocked, drop `o.pidDir = dir` -> the run sees "" -> RED.
// Mutation: main.go runLocked, lockRun(dir, derr) -> lockRun(pidDir()) -> a
// second evaluation -> RED.
func TestRunLockedResolvesThePidDirOnce(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", "")
	orig := resolvePidDir
	defer func() { resolvePidDir = orig }()
	calls := 0
	resolvePidDir = func() (string, error) { calls++; return orig() }
	want := mustPidDir(t)
	var got string
	err := runLocked(context.Background(), options{}, func(_ context.Context, o options) error {
		got = o.pidDir
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Errorf("pidDir evaluated %d times, want once", calls)
	}
	if got != want || got == "" {
		t.Errorf("the run saw pidDir %q, want %q", got, want)
	}
}
