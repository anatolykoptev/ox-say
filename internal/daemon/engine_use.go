package daemon

import (
	"context"
	"log/slog"
	"sync"
	"sync/atomic"
)

// engineUse rides a producer render's context. speechOn fills it with the pid
// of the engine child the request was sent to; the producer reads it back when
// the render gets no answer, to recycle exactly that child (#156.12b). Its
// presence also marks the request as the producer's own, not interactive
// (#156.7).
type engineUse struct {
	pid atomic.Int64
	// seq is the request's send stamp (engine.Guard.MarkSent): the recycle
	// ignores requests sent after it, queued behind it (#338.1). speechOn
	// stores seq BEFORE pid, so a reader that sees pid > 0 sees the stamp; a
	// zero stamp makes the recycle conservative (every request blocks it).
	seq atomic.Uint64
}

type engineUseKey struct{}

func withEngineUse(ctx context.Context) (context.Context, *engineUse) {
	u := &engineUse{}
	return context.WithValue(ctx, engineUseKey{}, u), u
}

func engineUseOf(ctx context.Context) *engineUse {
	u, _ := ctx.Value(engineUseKey{}).(*engineUse)
	return u
}

// qosGate keeps the shared VoxCPM2 child at background priority while a
// producer job runs, EXCEPT while an interactive request is using it: the
// process has one priority, so the interactive speak would otherwise run at the
// producer's lowered one (#156.7). Every method is safe on a nil gate.
type qosGate struct {
	mu          sync.Mutex
	background  bool // a producer job wants the child lowered
	interactive int  // interactive requests using the child right now
	lowPID      int  // the child this gate has lowered; 0: none
	pid         func() int
	set         func(pid int, on bool) error
	log         *slog.Logger
}

// setBackground records whether a producer job is running and applies it.
func (g *qosGate) setBackground(on bool) {
	if g == nil {
		return
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.background = on
	g.applyLocked()
}

// apply re-evaluates the child's QoS: the producer calls it around a render
// because the child may have been (re)started since.
func (g *qosGate) apply() {
	if g == nil {
		return
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.applyLocked()
}

// beginInteractive registers an interactive request and lifts the child to
// normal; the returned func ends it and, if a job is still running, lowers the
// child again. The end func is idempotent.
func (g *qosGate) beginInteractive() (end func()) {
	if g == nil {
		return func() {}
	}
	g.mu.Lock()
	g.interactive++
	g.applyLocked()
	g.mu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			g.mu.Lock()
			g.interactive--
			g.applyLocked()
			g.mu.Unlock()
		})
	}
}

// applyLocked lowers or restores the current child to match the wanted state.
// A child this gate never lowered needs no restore (a fresh child starts at
// normal), and a failed set is retried by the next event, never cached as done.
func (g *qosGate) applyLocked() {
	pid := g.pid()
	if g.background && g.interactive == 0 {
		if pid > 0 && g.lowPID != pid {
			if err := g.set(pid, true); err != nil {
				g.log.Warn("produce: cannot set the engine's priority", "error", err)
				return
			}
			g.lowPID = pid
		}
		return
	}
	if g.lowPID == 0 {
		return
	}
	if g.lowPID == pid {
		if err := g.set(pid, false); err != nil {
			g.log.Warn("produce: cannot restore the engine's priority", "error", err)
			return
		}
	}
	g.lowPID = 0
}
