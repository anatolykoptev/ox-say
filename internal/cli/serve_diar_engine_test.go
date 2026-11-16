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

// OX_SAY_DIAR_ENGINE chose between the pyannote pipeline and Nemotron until the pyannote one was deleted, and an
// installer that carried the value into the LaunchAgent may have left it there. `ox-say serve` starts regardless and
// says nothing about it: the key is retired, not an error and not a log line on every start.
// Mutation: internal/config/config.go load, return an error when OX_SAY_DIAR_ENGINE is set -> RED (serve exits 2).
func TestServeStartsQuietlyWithARetiredDiarEngineSetting(t *testing.T) {
	home := t.TempDir()
	ports := testutil.FreePorts(t, 3)
	t.Setenv("OX_SAY_HOME", home)
	t.Setenv("OX_SAY_ADDR", "127.0.0.1:"+strconv.Itoa(ports[0]))
	t.Setenv("OX_SAY_ENGINE_LOG_DIR", filepath.Join(home, "logs"))
	t.Setenv("OX_SAY_ENGINE_PORT", strconv.Itoa(ports[1]))
	t.Setenv("OX_SAY_STT_PORT", strconv.Itoa(ports[2]))
	t.Setenv("OX_SAY_DIAR_ENGINE", "pyannote")

	logFile, err := os.CreateTemp(t.TempDir(), "stderr")
	if err != nil {
		t.Fatal(err)
	}
	realStderr := os.Stderr
	os.Stderr = logFile
	defer func() { os.Stderr = realStderr }()

	oldNew, oldServe := newDaemon, serve
	defer func() { newDaemon, serve = oldNew, oldServe }()
	newDaemon = func(cfg *config.Config, l *slog.Logger) (*daemon.Daemon, error) { return daemon.New(cfg, l) }
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
	raw, _ := os.ReadFile(logFile.Name())
	if strings.Contains(string(raw), "DIAR_ENGINE") || strings.Contains(string(raw), "pyannote") {
		t.Errorf("serve logged about the retired setting:\n%s", raw)
	}
}
