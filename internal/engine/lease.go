package engine

import (
	"context"
	"sync/atomic"
)

// GPULease is a one-token mutex over the single GPU the daemon shares
// between the TTS engine child and a per-call ox-stt CLI run — about
// 2 GB for tts-server plus ~1.3 GB for ox-stt do not fit a 4 GB card
// (issue #11). It is in-memory only: the daemon's single-instance lock
// already keeps one ox-say per home, so a process or file lock would add
// nothing.
//
// Holders: a TTS supervisor with Config.GPU takes it in EnsureReady
// (waiting on the caller's context) before a start attempt and keeps it
// until the child's exit is observed — the supervisor reports Stopped
// before the process has actually died, so the lease, not the state, is
// "the engine holds the GPU". An STT CLI run that goes without -ng takes
// it for the whole ox-stt run: Try for auto, Wait for on; off and the
// resident server (CPU-only) never touch it.
type GPULease struct {
	sem     chan struct{}
	waiters atomic.Int32 // callers parked in Wait/WaitOr — observability for tests
}

// NewGPULease returns a free lease.
func NewGPULease() *GPULease {
	return &GPULease{sem: make(chan struct{}, 1)}
}

// Try takes the lease if it is free and reports whether it did.
func (l *GPULease) Try() bool {
	select {
	case l.sem <- struct{}{}:
		return true
	default:
		return false
	}
}

// Wait blocks for the lease until it is free or ctx ends.
func (l *GPULease) Wait(ctx context.Context) error {
	l.waiters.Add(1)
	defer l.waiters.Add(-1)
	select {
	case l.sem <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// WaitOr is Wait plus an abort channel: closing abort returns (false, nil)
// so the caller can re-check whatever the abort signals. The supervisor
// passes its change-broadcast channel so a state transition — Shutdown,
// another caller's committed start — wakes a parked caller instead of
// leaving it on the lease until ctx ends.
func (l *GPULease) WaitOr(ctx context.Context, abort <-chan struct{}) (bool, error) {
	l.waiters.Add(1)
	defer l.waiters.Add(-1)
	select {
	case l.sem <- struct{}{}:
		return true, nil
	case <-abort:
		return false, nil
	case <-ctx.Done():
		return false, ctx.Err()
	}
}

// Release returns the token. It must be called exactly once per
// acquisition: releasing a free lease blocks forever on the empty
// channel, surfacing the misuse as a hang rather than silently
// corrupting the count.
func (l *GPULease) Release() {
	<-l.sem
}

// Held reports whether the token is currently taken.
func (l *GPULease) Held() bool {
	return len(l.sem) > 0
}

// Waiters reports how many callers are parked in Wait/WaitOr.
func (l *GPULease) Waiters() int {
	return int(l.waiters.Load())
}
