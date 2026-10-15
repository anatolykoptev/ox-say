package daemon

import (
	"context"
	"log/slog"
	"path/filepath"
	"sync"
	"time"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// Layout and bounds of the producer. F1-4 needs only the job and its
// lifecycle shell; F1-5 builds the state machine on the same types.
const (
	produceDir = "produce"
	stopBound  = 10 * time.Second // launchd ExitTimeOut is 20 s
)

// job is the running project.
type job struct {
	dir   string
	m     *vproject.Manifest // guarded by producer.mu
	regen map[int]int        // chunk -> extra takes requested
}

// producer runs at most one job, through ports only.
type producer struct {
	ports producePorts
	root  string
	log   *slog.Logger
	mu    sync.Mutex
	ctx   context.Context // shutdown context: renders run under it
	stop  context.CancelFunc
	wg    sync.WaitGroup
	once  sync.Once
}

func newProducer(ports producePorts) *producer {
	return &producer{ports: ports, root: filepath.Join(ports.Home(), produceDir), log: slog.Default()}
}

func (p *producer) start() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.ctx == nil {
		p.ctx, p.stop = context.WithCancel(context.Background())
	}
}

// shutdown cancels the running job (it ends interrupted) and waits up to
// stopBound; false when the bound was exceeded.
func (p *producer) shutdown() bool {
	ok := true
	p.once.Do(func() {
		p.mu.Lock()
		stop := p.stop
		p.mu.Unlock()
		if stop == nil {
			return
		}
		stop()
		done := make(chan struct{})
		go func() { p.wg.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(stopBound):
			ok = false
			p.log.Warn("produce: a job was still stopping at shutdown")
		}
	})
	return ok
}
