package cli

import (
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	mcpserver "github.com/anatolykoptev/go-mcpserver"
	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/daemon"
	"github.com/anatolykoptev/ox-say/internal/testutil"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// An OX_SAY_DIAR_ENGINE the daemon does not know (the installer carries the plist value over on every update) does
// not stop `ox-say serve`: it starts on the default engine and says so once in the log, with the raw value.
// Mutation: internal/cli/cli.go cmdServe, delete the `if cfg.DiarEngineIgnored != ""` Warn -> RED (nothing logged).
func TestServeLogsAnUnknownDiarEngineAndStarts(t *testing.T) {
	home := t.TempDir()
	ports := testutil.FreePorts(t, 3)
	t.Setenv("OX_SAY_HOME", home)
	t.Setenv("OX_SAY_ADDR", "127.0.0.1:"+strconv.Itoa(ports[0]))
	t.Setenv("OX_SAY_ENGINE_LOG_DIR", filepath.Join(home, "logs"))
	t.Setenv("OX_SAY_ENGINE_PORT", strconv.Itoa(ports[1]))
	t.Setenv("OX_SAY_STT_PORT", strconv.Itoa(ports[2]))
	t.Setenv("OX_SAY_DIAR_ENGINE", "nemotorn")

	logFile, err := os.CreateTemp(t.TempDir(), "stderr")
	if err != nil {
		t.Fatal(err)
	}
	realStderr := os.Stderr
	os.Stderr = logFile
	defer func() { os.Stderr = realStderr }()

	oldNew, oldServe := newDaemon, serve
	defer func() { newDaemon, serve = oldNew, oldServe }()
	var engine string
	newDaemon = func(cfg *config.Config, l *slog.Logger) (*daemon.Daemon, error) {
		engine = cfg.Engine()
		return daemon.New(cfg, l)
	}
	serve = func(_ *mcp.Implementation, cfg mcpserver.Config, _ func(*mcp.Server)) error {
		cfg.OnShutdown()
		return nil
	}
	var out, errb strings.Builder
	code := Run([]string{"serve"}, &out, &errb, "test")
	os.Stderr = realStderr
	if code != 0 {
		t.Fatalf("serve exited %d: %s", code, errb.String())
	}
	if engine != config.DefaultDiarEngine {
		t.Errorf("engine = %q, want the default", engine)
	}
	raw, _ := os.ReadFile(logFile.Name())
	if n := strings.Count(string(raw), "OX_SAY_DIAR_ENGINE not recognised"); n != 1 || !strings.Contains(string(raw), "nemotorn") {
		t.Errorf("want one log line naming the value, got %d:\n%s", n, raw)
	}
}
