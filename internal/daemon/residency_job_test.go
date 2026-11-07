package daemon

import (
	"context"
	"errors"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// A producer job claims the studio voice's turn once and holds it across every take, releasing it when the job ends.
// Mutation: produce.go runChunks, call the loop directly instead of through p.holdTurn -> no take sees the turn held ->
// RED.
func TestProducerJobHoldsTheTurnAcrossAllTakes(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	if got := waitTerminal(t, p, s.ID); got.Status != vproject.StatusDone {
		t.Fatalf("%+v", got)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.renders) < 2 {
		t.Fatalf("renders = %d, want a multi-take job", len(f.renders))
	}
	for i, h := range f.heldAtRender {
		if !h {
			t.Fatalf("take %d rendered without the job's turn held", i)
		}
	}
	if f.turns != 1 || f.releases != 1 || f.turnHeld {
		t.Fatalf("turns %d releases %d held %v, want one claim for the whole job, released", f.turns, f.releases, f.turnHeld)
	}
}

// A cancelled job releases its turn.
// Mutation: produce.go holdTurn, delete `defer release()` -> the cancelled job keeps the turn -> RED.
func TestCancelledProducerJobReleasesItsTurn(t *testing.T) {
	f := newFakePorts(t)
	f.block = make(chan struct{})
	f.started = make(chan struct{}, 8)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	<-f.started
	if err := p.cancel(s.ID); err != nil {
		t.Fatal(err)
	}
	close(f.block) // a render in flight is not cut by a cancel: let the take finish
	if got := waitTerminal(t, p, s.ID); got.Status != vproject.StatusCancelled {
		t.Fatalf("status %s, want cancelled", got.Status)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.turnHeld || f.releases != f.turns || f.turns == 0 {
		t.Fatalf("turns %d releases %d held %v: a cancelled job kept its turn", f.turns, f.releases, f.turnHeld)
	}
}

// A job whose turn cannot be taken fails in plain words and renders nothing; one cancelled while waiting for the turn is
// cancelled, not failed.
// Mutation: produce.go holdTurn, drop the `j.cancel.Load()` branch -> the cancel reads as a failure -> RED (second case).
func TestProducerJobTurnRefusalAndCancelWhileWaiting(t *testing.T) {
	f := newFakePorts(t)
	f.turnErr = errors.New("another engine is busy")
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	got := waitTerminal(t, p, s.ID)
	if got.Status != vproject.StatusFailed || len(f.renders) != 0 {
		t.Fatalf("status %s renders %d, want failed with no render", got.Status, len(f.renders))
	}
	j := &job{}
	j.ctx = context.Background()
	j.cancel.Store(true)
	if err := p.holdTurn(j, func() error { t.Fatal("ran without the turn"); return nil }); !errors.Is(err, errCancelled) {
		t.Fatalf("a cancelled wait = %v, want errCancelled", err)
	}
}

// holdTurn releases the turn when the job body panics.
// Mutation: produce.go holdTurn, replace `defer release()` with a release after fn() returns -> the panic skips it ->
// RED.
func TestHoldTurnReleasesOnPanic(t *testing.T) {
	f := newFakePorts(t)
	p := newProducer(f)
	j := &job{}
	j.ctx = context.Background()
	func() {
		defer func() { _ = recover() }()
		_ = p.holdTurn(j, func() error { panic("boom") })
	}()
	if f.turnHeld || f.releases != 1 {
		t.Fatalf("held %v releases %d after a panic", f.turnHeld, f.releases)
	}
}
