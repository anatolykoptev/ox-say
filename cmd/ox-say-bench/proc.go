package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/anatolykoptev/ox-say/internal/engine"
)

const (
	startupTimeout = 5 * time.Minute // first start compiles the Metal library
	rssPoll        = 200 * time.Millisecond
	kibPerMiB      = 1024
	footprintPeak  = "Physical footprint (peak):"
)

// freePort asks the kernel for an unused loopback port.
func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

// child is one supervised engine under measurement.
type child struct {
	sup   *engine.Supervisor
	base  string
	start time.Duration // spawn → /health OK
	rss   *rssSampler
}

// childConfig fills cfg for the child called name: its port, log and pidfile.
func childConfig(work, name string, port int, cfg engine.Config) engine.Config {
	cfg.Name = name
	cfg.Port = port
	cfg.LogName = name + ".log"
	cfg.LogDir = filepath.Join(work, "logs")
	cfg.PidPath = pidPath(name)
	cfg.StartupTimeout = startupTimeout
	cfg.Logger = slog.New(slog.DiscardHandler)
	return cfg
}

// startChild spawns an engine through engine.Supervisor — the daemon's own
// spawn, health and kill path — and starts sampling its RSS. cfg carries
// Bin and either Model/Codec (tts-server) or Args (ox-stt).
func startChild(ctx context.Context, work, name string, cfg engine.Config) (*child, error) {
	port, err := freePort()
	if err != nil {
		return nil, err
	}
	sup, err := engine.New(childConfig(work, name, port, cfg))
	if err != nil {
		return nil, err
	}
	t0 := time.Now()
	base, err := sup.EnsureReady(ctx)
	if err != nil {
		sup.Shutdown()
		return nil, fmt.Errorf("%s: %w (log: %s)", name, err, filepath.Join(cfg.LogDir, cfg.LogName))
	}
	c := &child{sup: sup, base: base, start: time.Since(t0)}
	c.rss = sampleRSS(sup.Status().PID)
	return c, nil
}

// stop ends RSS sampling, reads the peak physical footprint, stops the
// engine and returns both: peak RSS in MiB and vmmap's footprint text.
func (c *child) stop() (rssMB float64, footprint string) {
	rssMB = c.rss.stop()
	footprint = peakFootprint(c.sup.Status().PID)
	c.sup.Shutdown()
	return rssMB, footprint
}

// peakFootprint asks vmmap (built into macOS) for the process's peak
// physical footprint, which also counts Metal (IOAccelerator) memory that
// RSS can miss. "?" when vmmap cannot read the process.
func peakFootprint(pid int) string {
	out, err := exec.Command("vmmap", "--summary", strconv.Itoa(pid)).Output()
	if err != nil {
		return "?"
	}
	for _, l := range strings.Split(string(out), "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(l), footprintPeak); ok {
			return strings.TrimSpace(v)
		}
	}
	return "?"
}

// rssSampler polls a process's resident set size with ps and keeps the
// peak. RSS may not count every Metal allocation; child.stop adds vmmap's
// peak physical footprint next to it.
type rssSampler struct {
	mu   sync.Mutex
	peak int64 // KiB
	done chan struct{}
	wg   sync.WaitGroup
}

func sampleRSS(pid int) *rssSampler {
	s := &rssSampler{done: make(chan struct{})}
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		t := time.NewTicker(rssPoll)
		defer t.Stop()
		for {
			s.poll(pid)
			select {
			case <-s.done:
				return
			case <-t.C:
			}
		}
	}()
	return s
}

func (s *rssSampler) poll(pid int) {
	out, err := exec.Command("ps", "-o", "rss=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return
	}
	kib, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	if err != nil {
		return
	}
	s.mu.Lock()
	s.peak = max(s.peak, kib)
	s.mu.Unlock()
}

func (s *rssSampler) stop() float64 {
	close(s.done)
	s.wg.Wait()
	s.mu.Lock()
	defer s.mu.Unlock()
	return float64(s.peak) / kibPerMiB
}

// pidDir is where the engine children's pidfiles live: one directory per user,
// the same on every run. The supervisor reaps an orphan through its pidfile when
// it starts, so a bench that was SIGKILLed has its children reaped by the next
// one, which a per-run scratch directory could never do. When the directory
// cannot be made or written the error says why; the bench then measures without
// reaping and without the lock (see lockRun, pidPath).
func pidDir() (string, error) {
	base, err := os.UserCacheDir()
	if err != nil {
		base = os.TempDir()
	}
	dir := filepath.Join(base, "ox-say-bench", "run")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	probe, err := os.CreateTemp(dir, ".write-probe-*")
	if err != nil {
		return "", err
	}
	_ = probe.Close()
	_ = os.Remove(probe.Name())
	return dir, nil
}

// pidPath is the pidfile of the engine child called name; "" (no pidfile, so no
// reaping) when pidDir is unusable.
func pidPath(name string) string {
	dir, err := pidDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, name+".pid")
}

// flock is syscall.Flock; a test replaces it.
var flock = syscall.Flock

// lockRun takes the lock that keeps two benches apart: they share pidDir, and
// each would reap the other's live children as orphans. The lock goes with the
// process, so a killed bench never leaves it held. Only EWOULDBLOCK means
// another bench holds it; any other flock error is returned as it is. When
// pidDir is unusable there is nothing shared to protect: warn and run without
// the lock.
func lockRun() (unlock func(), err error) {
	dir, derr := pidDir()
	if derr != nil {
		fmt.Fprintf(os.Stderr, "ox-say-bench: warning: %v; running without the pidfile lock and without reaping orphaned engines\n", derr)
		return func() {}, nil
	}
	f, err := os.OpenFile(filepath.Join(dir, ".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("bench lock: %w", err)
	}
	if err := flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, errors.New("another ox-say-bench is already running (it shares the engine pidfile directory); wait for it to finish")
		}
		return nil, fmt.Errorf("bench lock: %w", err)
	}
	return func() { _ = f.Close() }, nil
}
