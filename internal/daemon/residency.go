package daemon

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/anatolykoptev/ox-say/internal/engine"
)

// residency makes the large GPU engines (the fast voice, the studio voice, the notes model) take turns on an Apple
// Silicon Mac that cannot hold two of them: Metal wires about 2/3 of RAM, VoxCPM2 peaks near 7.5 GB, the fast voice
// holds about 5 GB and the notes model about 7 GB (issue #501). Only one of them is resident at a time. The resident
// STT server is small and is never part of it, so dictation and a meeting recording are never evicted.
//
// The existing GPULease is not used for this. It is a mutex held for a child's whole life, so a second engine would
// wait for the first one's idle stop (minutes) instead of replacing it, and it is wired to the per-call ox-stt CLI,
// which must keep running next to a resident engine.
//
// A use enters before it takes the engine's Guard and leaves after it releases it. The first use of a different engine
// stops the others (engine.Supervisor.Stop: it waits for their Guards, so no request is killed, and returns once the
// process has exited and its memory is free) before its own engine may start. A use of another engine meanwhile waits
// for the turn to end. The nil *residency is "every engine may be resident": enter is a no-op, the case on a Mac with
// enough memory.
type residency struct {
	mu      sync.Mutex
	change  chan struct{} // closed on every transition
	active  *engine.Supervisor
	settled bool // the engines other than active have been stopped for it
	n       int  // uses in flight
	engines []*engine.Supervisor
	log     *slog.Logger
}

// newResidency returns the arbiter over engines (nil entries are skipped), or nil when fewer than two exist.
func newResidency(log *slog.Logger, engines ...*engine.Supervisor) *residency {
	r := &residency{change: make(chan struct{}), log: log}
	for _, e := range engines {
		if e != nil {
			r.engines = append(r.engines, e)
		}
	}
	if len(r.engines) < 2 {
		return nil
	}
	return r
}

// managed reports whether sup takes turns (STT, and any engine not in the set, does not).
func (r *residency) managed(sup *engine.Supervisor) bool {
	if r == nil {
		return false
	}
	for _, e := range r.engines {
		if e == sup {
			return true
		}
	}
	return false
}

// mode is /status's memory_mode.
func (r *residency) mode() string {
	if r == nil {
		return memoryModeShared
	}
	return memoryModeOneLarge
}

const (
	// memoryModeShared: every engine may be resident at once (enough memory).
	memoryModeShared = "shared"
	// memoryModeOneLarge: the large engines take turns (less than config.OneLargeEngineBelowGB).
	memoryModeOneLarge = "one_large_engine"
)

// engineBusyCode is the stable code of a request that gave up waiting for another large engine's turn.
const engineBusyCode = "engine_busy_memory"

// engineBusyError is that refusal: another large engine is working and this Mac has no room for both. It is an
// engine-start failure (503) for every caller that only looks at the status.
type engineBusyError struct{ err error } // err: why the wait ended

func (*engineBusyError) Error() string {
	return "Another voice engine is using this Mac's memory right now; try again when it has finished."
}
func (e *engineBusyError) Unwrap() []error { return []error{errEngineStart, e.err} }

// enter takes sup's turn and returns the release; call it after the engine's Guard is released. budget bounds the wait
// for another engine's turn (0: only ctx does): when it runs out while ctx is still alive the answer is the typed
// engineBusyError. A failed stop of the other engines is an error too, and sup must not be started then. An engine that
// is not managed enters at once.
func (r *residency) enter(ctx context.Context, sup *engine.Supervisor, budget time.Duration) (func(), error) {
	if !r.managed(sup) {
		return func() {}, nil
	}
	wctx := ctx
	if budget > 0 {
		var cancel context.CancelFunc
		wctx, cancel = context.WithTimeout(ctx, budget)
		defer cancel()
	}
	if err := r.take(wctx, sup); err != nil {
		if ctx.Err() == nil && wctx.Err() != nil {
			return nil, &engineBusyError{err: err}
		}
		return nil, err
	}
	var once sync.Once
	return func() { once.Do(func() { r.leave() }) }, nil
}

// take waits for sup's turn and counts one use of it.
func (r *residency) take(ctx context.Context, sup *engine.Supervisor) error {
	for {
		r.mu.Lock()
		switch {
		case r.active == sup && r.settled:
			r.n++
			r.mu.Unlock()
			return nil
		case r.n > 0: // another engine is in use, or sup's own turn is still being set up
			ch := r.change
			r.mu.Unlock()
			select {
			case <-ch:
			case <-ctx.Done():
				return ctx.Err()
			}
		default:
			// Nobody is using a large engine: claim the turn, then make room. The claim keeps every other use waiting
			// (sup's own included) until the others have exited.
			r.active, r.settled, r.n = sup, false, 1
			r.mu.Unlock()
			err := r.evictOthers(ctx, sup)
			r.mu.Lock()
			if err != nil {
				r.active, r.n = nil, 0
			} else {
				r.settled = true
			}
			r.broadcastLocked()
			r.mu.Unlock()
			return err
		}
	}
}

// evictOthers stops every managed engine but keep, waiting for each one's exit.
func (r *residency) evictOthers(ctx context.Context, keep *engine.Supervisor) error {
	for _, e := range r.engines {
		if e == keep {
			continue
		}
		if err := e.Stop(ctx); err != nil {
			if !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
				r.log.Warn("memory: could not stop a large engine to make room", slog.Any("error", err))
			}
			return fmt.Errorf("stop the other engine: %w", err)
		}
	}
	return nil
}

func (r *residency) leave() {
	r.mu.Lock()
	r.n--
	if r.n == 0 {
		r.broadcastLocked()
	}
	r.mu.Unlock()
}

func (r *residency) broadcastLocked() {
	close(r.change)
	r.change = make(chan struct{})
}
