package cli

import (
	"log/slog"
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

// `ox-say serve` sweeps the scratch directories of killed cleanups out of the temp directory before it serves.
// Mutation: internal/cli/cli.go cmdServe - delete `d.SweepCleanScratch()` -> RED (the stale directory stays).
func TestServeSweepsStaleCleanScratch(t *testing.T) {
	home := t.TempDir()
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	t.Setenv("OX_SAY_HOME", home)
	ports := testutil.FreePorts(t, 3)
	t.Setenv("OX_SAY_ADDR", "127.0.0.1:"+strconv.Itoa(ports[0]))
	t.Setenv("OX_SAY_ENGINE_LOG_DIR", filepath.Join(home, "logs"))
	t.Setenv("OX_SAY_ENGINE_PORT", strconv.Itoa(ports[1]))
	t.Setenv("OX_SAY_STT_PORT", strconv.Itoa(ports[2]))

	stale := filepath.Join(tmp, "voice-clean.abc123")
	fresh := filepath.Join(tmp, "voice-clean.def456")
	for _, p := range []string{stale, fresh} {
		if err := os.Mkdir(p, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Now().Add(-7 * time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}

	oldNew, oldServe := newDaemon, serve
	defer func() { newDaemon, serve = oldNew, oldServe }()
	newDaemon = func(cfg *config.Config, l *slog.Logger) (*daemon.Daemon, error) { return daemon.New(cfg, l) }
	var staleAtServe, freshAtServe bool
	serve = func(_ *mcp.Implementation, _ mcpserver.Config, _ func(*mcp.Server)) error {
		_, e1 := os.Stat(stale)
		_, e2 := os.Stat(fresh)
		staleAtServe, freshAtServe = e1 == nil, e2 == nil
		return nil
	}
	var out, errb strings.Builder
	if code := Run([]string{"serve"}, &out, &errb, "test"); code != 0 {
		t.Fatalf("serve exit %d: %s", code, errb.String())
	}
	if staleAtServe {
		t.Error("the stale scratch directory was still there when serving began")
	}
	if !freshAtServe {
		t.Error("a fresh scratch directory was removed")
	}
}
