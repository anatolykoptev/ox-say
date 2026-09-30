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
