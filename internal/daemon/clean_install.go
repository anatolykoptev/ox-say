package daemon

import (
	"bytes"
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
)

// cleanInstall is the one running download of the voice-cleanup model: the lazy, first-use fetch (plan, decision 7).
// It reuses the notes download's way of running the installed fetch-models.sh (same script lookup, own process group,
// killed with the daemon) in a smaller shape: scripts/fetch-models.sh takes no lock (#457), so the single-flight is
// here, under mu, and two concurrent cleanups start exactly one fetch.
type cleanInstall struct {
	mu      sync.Mutex
	running bool
	err     string
	code    string
	ctx     context.Context
	cancel  context.CancelFunc
	stopped bool
	wg      sync.WaitGroup
}

func (c *cleanInstall) state() (running bool, err, code string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.running, c.err, c.code
}

// cleanFetchStart starts the fetch process; a variable so a test can count starts without a script.
var cleanFetchStart = func(ctx context.Context, script, dest string, tail *bytes.Buffer) (*exec.Cmd, error) {
	cmd := exec.CommandContext(ctx, script, "--clean-only", dest)
	cmd.Stderr = tail
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	return cmd, cmd.Start()
}

// startCleanInstall is what a cleanup does when the model is missing: it starts the download unless one is running,
// and answers 503 models_downloading either way (or the reason it cannot download).
func (d *Daemon) startCleanInstall() *CleanError {
	downloading := &CleanError{Status: http.StatusServiceUnavailable, Code: CleanModelsDownloading,
		Msg: "The voice cleanup model is being downloaded (about 131 MB). Try again in a minute."}
	script := filepath.Join(d.Cfg.Home, fetchModelsScript)
	if _, err := os.Stat(script); err != nil {
		return &CleanError{Status: http.StatusServiceUnavailable, Code: CleanModelsMissing,
			Msg: "The voice cleanup model is not installed and cannot be downloaded: " + fetchModelsScript + " is missing. Reinstall OxSay."}
	}
	dest := filepath.Join(d.Cfg.Home, "models")
	c := &d.cleanInst
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.stopped {
		return &CleanError{Status: http.StatusServiceUnavailable, Code: CleanModelsMissing, Msg: "OxSay is shutting down."}
	}
	if c.running {
		return downloading
	}
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return &CleanError{Status: http.StatusServiceUnavailable, Code: CleanModelsMissing,
			Msg: "The voice cleanup model cannot be downloaded: the models folder cannot be created."}
	}
	if c.ctx == nil {
		c.ctx, c.cancel = context.WithCancel(context.Background())
	}
	var tail bytes.Buffer
	cmd, err := cleanFetchStart(c.ctx, script, dest, &tail)
	if err != nil {
		d.log.Warn("voice cleanup model download did not start", slog.Any("error", err))
		return &CleanError{Status: http.StatusServiceUnavailable, Code: CleanModelsMissing,
			Msg: "The voice cleanup model cannot be downloaded: the download did not start."}
	}
	c.running, c.err, c.code = true, "", ""
	c.wg.Add(1)
	go d.runCleanInstall(c.ctx, cmd, &tail)
	return downloading
}

func (d *Daemon) runCleanInstall(ctx context.Context, cmd *exec.Cmd, tail *bytes.Buffer) {
	c := &d.cleanInst
	defer c.wg.Done()
	err := cmd.Wait()
	c.mu.Lock()
	defer c.mu.Unlock()
	c.running = false
	if err != nil && ctx.Err() == nil {
		msg := installTail(tail.String())
		c.err, c.code = "The download failed: "+msg, installFailureCode(msg)
		d.log.Warn("voice cleanup model download failed", slog.Any("error", err), slog.String("stderr", msg))
	}
}

// StopCleanInstall ends a running model download with the daemon and waits for it. Shutdown calls it.
func (d *Daemon) StopCleanInstall() {
	c := &d.cleanInst
	c.mu.Lock()
	c.stopped = true
	if c.cancel != nil {
		c.cancel()
	}
	c.mu.Unlock()
	c.wg.Wait()
}

// cleanInstalling is 1 while the voice-cleanup model downloads.
func (d *Daemon) cleanInstalling() int {
	if running, _, _ := d.cleanInst.state(); running {
		return 1
	}
	return 0
}
