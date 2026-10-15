package cli

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
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

// `ox-say serve` starts the voiceover producer before serving and stops it
// after: a producer whose start was never called answers 503 to a create.
// The serve path is the production cmdServe with go-mcpserver's Serve replaced
// by a stub that asks the daemon's own routes.
// Mutation: internal/cli/cli.go cmdServe - delete `d.StartProducer()` -> RED (503 while serving).
// Mutation: internal/cli/cli.go cmdServe - delete `d.StopProducer()` -> RED (still answers after).
func TestServeStartsAndStopsTheProducer(t *testing.T) {
	home := t.TempDir()
	t.Setenv("OX_SAY_HOME", home)
	t.Setenv("OX_SAY_ADDR", "127.0.0.1:"+strconv.Itoa(testutil.FreePort(t)))
	t.Setenv("OX_SAY_ENGINE_LOG_DIR", filepath.Join(home, "logs"))
	t.Setenv("OX_SAY_ENGINE_PORT", strconv.Itoa(testutil.FreePort(t)))
	t.Setenv("OX_SAY_STT_PORT", strconv.Itoa(testutil.FreePort(t)))

	oldNew, oldServe := newDaemon, serve
	defer func() { newDaemon, serve = oldNew, oldServe }()
	var d *daemon.Daemon
	newDaemon = func(cfg *config.Config, l *slog.Logger) (*daemon.Daemon, error) {
		var err error
		d, err = daemon.New(cfg, l)
		return d, err
	}
	create := func(mux *http.ServeMux) int {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/v1/produce", strings.NewReader(`{"script":"Привет."}`))
		req.Header.Set("Content-Type", "application/json")
		mux.ServeHTTP(rec, req)
		return rec.Code
	}
	var mux *http.ServeMux
	whileServing := 0
	serve = func(_ *mcp.Implementation, cfg mcpserver.Config, _ func(*mcp.Server)) error {
		mux = http.NewServeMux()
		cfg.Routes(mux)
		whileServing = create(mux)
		return nil // no OnShutdown: only cmdServe's own StopProducer can stop it
	}
	var out, errb strings.Builder
	if code := Run([]string{"serve"}, &out, &errb, "test"); code != 0 {
		t.Fatalf("serve exit %d: %s", code, errb.String())
	}
	if whileServing == http.StatusServiceUnavailable {
		t.Fatal("the producer was not started before serving")
	}
	if after := create(mux); after != http.StatusServiceUnavailable {
		t.Fatalf("a create after serve returned answered %d, want 503 (producer stopped)", after)
	}
	d.Shutdown()
}
