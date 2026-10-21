package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
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

// startChild spawns an engine through engine.Supervisor — the daemon's own
// spawn, health and kill path — and starts sampling its RSS. cfg carries
// Bin and either Model/Codec (tts-server) or Args (ox-stt).
func startChild(ctx context.Context, work, name string, cfg engine.Config) (*child, error) {
	port, err := freePort()
	if err != nil {
		return nil, err
	}
	cfg.Name = name
	cfg.Port = port
	cfg.LogName = name + ".log"
	cfg.LogDir = filepath.Join(work, "logs")
	cfg.PidPath = filepath.Join(work, "run", name+".pid")
	cfg.StartupTimeout = startupTimeout
	cfg.Logger = slog.New(slog.DiscardHandler)
	sup, err := engine.New(cfg)
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
