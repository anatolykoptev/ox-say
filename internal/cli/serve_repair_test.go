package cli

import (
	"context"
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
	"github.com/anatolykoptev/ox-say/internal/voices"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// `ox-say serve` repairs a stored voice whose transcript runs past its audio,
// once the listener is up. The serve path is the production cmdServe with
// go-mcpserver's Serve replaced by a stub that binds the configured address
// and waits for the repair; the STT is the one seam injected.
// Mutation: internal/cli/cli.go cmdServe — delete `d.StartVoiceRepair()` ->
// RED (the voice is never repaired).
func TestServeRepairsBrokenVoice(t *testing.T) {
	home := t.TempDir()
	port := testutil.FreePort(t)
	t.Setenv("OX_SAY_HOME", home)
	t.Setenv("OX_SAY_ADDR", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	t.Setenv("OX_SAY_ENGINE_LOG_DIR", filepath.Join(home, "logs"))
	t.Setenv("OX_SAY_ENGINE_PORT", strconv.Itoa(testutil.FreePort(t)))
	t.Setenv("OX_SAY_STT_PORT", strconv.Itoa(testutil.FreePort(t)))

	vdir := filepath.Join(home, "voices")
	if err := os.MkdirAll(vdir, 0o755); err != nil {
		t.Fatal(err)
	}
	long := strings.TrimSpace(strings.Repeat("word ", 90))
	if err := os.WriteFile(filepath.Join(vdir, "snakes.wav"), testutil.SilentWAV(20), 0o644); err != nil {
		t.Fatal(err)
	}
	meta := `{"name":"snakes","ref_text":"` + long + `","created":"2026-10-04T14:28:00Z"}`
	if err := os.WriteFile(filepath.Join(vdir, "snakes.json"), []byte(meta), 0o644); err != nil {
		t.Fatal(err)
	}

	words := make([]voices.Word, 60)
	for i := range words {
		tok := "w" + strconv.Itoa(i)
		if i%6 == 5 {
			tok += "."
		}
		words[i] = voices.Word{W: tok, S: float64(i) * 0.4, E: float64(i)*0.4 + 0.3}
	}
	oldNew, oldServe := newDaemon, serve
	defer func() { newDaemon, serve = oldNew, oldServe }()
	newDaemon = func(cfg *config.Config, l *slog.Logger) (*daemon.Daemon, error) {
		d, err := daemon.New(cfg, l)
		if err == nil {
			d.Store.SetTranscriber(func(context.Context, string) ([]voices.Word, error) { return words, nil })
		}
		return d, err
	}
	repaired := false
	serve = func(_ *mcp.Implementation, cfg mcpserver.Config, _ func(*mcp.Server)) error {
		ln, err := net.Listen("tcp", net.JoinHostPort(cfg.Host, cfg.Port))
		if err != nil {
			return err
		}
		defer ln.Close()
		defer cfg.OnShutdown()
		store, err := voices.New(vdir)
		if err != nil {
			return err
		}
		for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
			if v, err := store.Get("snakes"); err == nil && v.RefText != long {
				repaired = true
				return nil
			}
		}
		return nil
	}

	var out, errb strings.Builder
	if code := Run([]string{"serve"}, &out, &errb, "test"); code != 0 {
		t.Fatalf("serve exit %d: %s", code, errb.String())
	}
	if !repaired {
		t.Fatal("serve never repaired the broken voice")
	}
	if _, err := os.Stat(filepath.Join(vdir, "snakes.orig.json")); err != nil {
		t.Fatalf("no backup beside the repaired voice: %v", err)
	}
}
