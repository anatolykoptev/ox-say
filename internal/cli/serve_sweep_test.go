package cli

import (
	"errors"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	mcpserver "github.com/anatolykoptev/go-mcpserver"
	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/daemon"
	"github.com/anatolykoptev/ox-say/internal/testutil"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// serveSweepEnv sets up a temp dir with a stale and a fresh scratch dir, as a killed cleanup leaves them: marker file, free lock.
func serveSweepEnv(t *testing.T) (stale, fresh string, addr string) {
	t.Helper()
	home := t.TempDir()
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	t.Setenv("OX_SAY_HOME", home)
	ports := testutil.FreePorts(t, 3)
	addr = net.JoinHostPort("127.0.0.1", strconv.Itoa(ports[0]))
	t.Setenv("OX_SAY_ADDR", addr)
	t.Setenv("OX_SAY_ENGINE_LOG_DIR", filepath.Join(home, "logs"))
	t.Setenv("OX_SAY_ENGINE_PORT", strconv.Itoa(ports[1]))
	t.Setenv("OX_SAY_STT_PORT", strconv.Itoa(ports[2]))
	stale = filepath.Join(tmp, "voice-clean.abc123")
	fresh = filepath.Join(tmp, "voice-clean.def456")
	for _, p := range []string{stale, fresh} {
		if err := os.Mkdir(p, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(p, ".ox-say-voiceclean"), []byte("pid=1\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Now().Add(-7 * time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}
	oldNew := newDaemon
	t.Cleanup(func() { newDaemon = oldNew })
	newDaemon = func(cfg *config.Config, l *slog.Logger) (*daemon.Daemon, error) { return daemon.New(cfg, l) }
	return stale, fresh, addr
}

// `ox-say serve` sweeps the scratch directories of killed cleanups out of the temp directory once it is listening.
// Mutation: internal/cli/cli.go cmdServe - delete `d.StartCleanScratchSweep()` -> RED (the stale directory stays).
func TestServeSweepsStaleCleanScratchOnceListening(t *testing.T) {
	stale, fresh, _ := serveSweepEnv(t)
	oldServe := serve
	defer func() { serve = oldServe }()
	gone := false
	serve = func(_ *mcp.Implementation, cfg mcpserver.Config, _ func(*mcp.Server)) error {
		ln, err := net.Listen("tcp", net.JoinHostPort(cfg.Host, cfg.Port))
		if err != nil {
			return err
		}
		defer ln.Close()
		for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
			if _, err := os.Stat(stale); err != nil {
				gone = true
				break
			}
		}
		return nil
	}
	var out, errb strings.Builder
	if code := Run([]string{"serve"}, &out, &errb, "test"); code != 0 {
		t.Fatalf("serve exit %d: %s", code, errb.String())
	}
	if !gone {
		t.Error("the stale scratch directory was not swept")
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Error("a fresh scratch directory was removed")
	}
}

// A serve that never gets to listen sweeps nothing.
// Mutation: internal/daemon/clean.go StartCleanScratchSweep - delete the waitListening guard -> RED.
func TestServeThatNeverListensSweepsNothing(t *testing.T) {
	stale, _, _ := serveSweepEnv(t)
	oldServe := serve
	defer func() { serve = oldServe }()
	serve = func(*mcp.Implementation, mcpserver.Config, func(*mcp.Server)) error {
		time.Sleep(300 * time.Millisecond) // a sweep that did not wait for the listener would have run by now
		return errors.New("bind: address already in use")
	}
	var out, errb strings.Builder
	if code := Run([]string{"serve"}, &out, &errb, "test"); code != 1 {
		t.Fatalf("serve exit %d: %s", code, errb.String())
	}
	if _, err := os.Stat(stale); err != nil {
		t.Error("a serve that failed to bind swept the scratch directory")
	}
}
