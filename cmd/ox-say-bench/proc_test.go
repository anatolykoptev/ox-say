package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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
	a, b := pidPath("tts"), pidPath("tts")
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
	unlock, err := lockRun()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lockRun(); err == nil || !strings.Contains(err.Error(), "already running") {
		t.Fatalf("a second lock was granted or its error is unclear: %v", err)
	}
	unlock()
	again, err := lockRun()
	if err != nil {
		t.Fatalf("the lock was not released: %v", err)
	}
	again()
}
