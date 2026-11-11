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
	// cond, when set, decides per call whether the engines take turns at all:
	// a notes model over config.NotesExclusiveBytes makes the large engines
	// exclusive on a Mac that would otherwise share them (see notesExclusive).
	// nil: managed unconditionally.
	cond func() bool
	// stop stops one engine (tests only; nil is Supervisor.Stop).
	stop func(context.Context, *engine.Supervisor) error
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

// residentEngine is one engine the daemon may have resident while another
// runs: its supervisor (nil where the feature is off or the Mac cannot run
// it), the /v1/models measure of the model bytes it holds, and whether it
// is one of the large engines this file arbitrates. The diarizer has no
// row: ox-diar runs per call (runDiarizer), it never stays resident.
type residentEngine struct {
	sup        *engine.Supervisor
	modelBytes func() int64
	large      bool
}

// residentEngines is THE list of the daemon's engine supervisors, in the
// Daemon's field order: the managed set newResidency gets and the
// own-model trial's resident-memory accounting both come from it, so an
// engine added here is counted — and, when large, managed — and neither
// consumer keeps a second list to forget it in (the accounting once
// missed the STT server exactly that way). STT is a row although it is
// never managed: the package comment rules it out of the turns, but it
// still holds its model while a trial runs.
func (d *Daemon) residentEngines() []residentEngine {
	return []residentEngine{
		{d.Sup, func() int64 { return d.qwenModelEntry().Bytes }, true},
		{d.STTSup, d.sttModelBytes, false},
		{d.VoxSup, func() int64 { return d.voxModelEntry().Bytes }, true},
		{d.LLMSup, func() int64 { return d.notesModelEntry().Bytes }, true},
	}
}

// largeEngineSups is the managed set newResidency gets: the supervisors of
// the resident engines large enough to take turns.
func (d *Daemon) largeEngineSups() []*engine.Supervisor {
	var out []*engine.Supervisor
	for _, e := range d.residentEngines() {
		if e.large {
			out = append(out, e.sup)
		}
	}
	return out
}

// managed reports whether sup takes turns (STT, and any engine not in the set, does not). When cond is set the whole
// set is managed only while it holds — the notes engine is exclusive only with a model large enough to need it.
func (r *residency) managed(sup *engine.Supervisor) bool {
	if r == nil || (r.cond != nil && !r.cond()) {
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
	if r == nil || (r.cond != nil && !r.cond()) {
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

// engineTurnWaitLog: only a turn wait at least this long gets its own line —
// the usual case is another engine mid-request, which ends in moments.
const engineTurnWaitLog = 250 * time.Millisecond

// engineBusyError is that refusal: another large engine is working and this Mac has no room for both. It is its own
// 503 (synthStatus, writeSynthErr), not an engine-start failure: nothing failed to start.
type engineBusyError struct{ err error } // err: why the wait ended

func (*engineBusyError) Error() string {
	return "Another voice or notes engine (the studio voice, the fast voice or the meeting-notes model) is using this Mac's memory right now, so this request was not started. Nothing failed: retry in a minute or two."
}
func (e *engineBusyError) Unwrap() error { return e.err }

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
	start := time.Now()
	var held *engine.Supervisor
	for {
		r.mu.Lock()
		switch {
		case r.active == sup && r.settled:
			r.n++
			r.mu.Unlock()
			r.logTurnWait(sup, held, start)
			return nil
		case r.n > 0: // another engine is in use, or sup's own turn is still being set up
			ch := r.change
			held = r.active
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
			err := r.settle(ctx, sup)
			if err == nil {
				r.logTurnWait(sup, held, start)
			}
			return err
		}
	}
}

// logTurnWait writes the wait a use stood through for a large engine's turn:
// which engine it wanted and which held the turn — the line that explains a
// stalled notes job or voice request.
func (r *residency) logTurnWait(sup, held *engine.Supervisor, start time.Time) {
	if held == nil {
		return
	}
	if d := time.Since(start); d >= engineTurnWaitLog {
		r.log.Info("memory: engine turn wait",
			slog.String("for", sup.Name()), slog.String("held_by", held.Name()),
			slog.Int64("dur_ms", d.Milliseconds()))
	}
}

// settle makes room for the claimed turn and publishes the outcome. A failure and a panic both roll the claim back:
// a claim left behind would refuse every other engine until the daemon restarts.
func (r *residency) settle(ctx context.Context, sup *engine.Supervisor) (err error) {
	completed := false
	defer func() {
		r.mu.Lock()
		if completed && err == nil {
			r.settled = true
		} else {
			r.active, r.n = nil, 0
		}
		r.broadcastLocked()
		r.mu.Unlock()
	}()
	err = r.evictOthers(ctx, sup)
	completed = true
	return err
}

// stopEngine stops one large engine and returns once its process has exited, so its memory is free. It is the one
// stop path: the arbiter's turn change and the notes turn's make-room step (makeNotesRoom) both use it. A nil
// arbiter stops with Supervisor.Stop.
func (r *residency) stopEngine(ctx context.Context, e *engine.Supervisor) error {
	if r != nil && r.stop != nil {
		return r.stop(ctx, e)
	}
	return e.Stop(ctx)
}

// evictOthers stops every managed engine but keep, waiting for each one's exit.
func (r *residency) evictOthers(ctx context.Context, keep *engine.Supervisor) error {
	for _, e := range r.engines {
		if e == keep {
			continue
		}
		if err := r.stopEngine(ctx, e); err != nil {
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
