package daemon

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// memPorts is fakePorts with the real arbiter behind Turn, so a pause is judged by what the fast voice can do.
type memPorts struct {
	*fakePorts
	d     *Daemon
	mu2   sync.Mutex
	heldN []int // the arbiter's use count at each Render
	waitN []int // ... and at the start of each dictation wait
}

func (m *memPorts) Turn(ctx context.Context) (func(), error) {
	return m.d.mem.enter(ctx, m.d.VoxSup, 0)
}

func (m *memPorts) Render(ctx context.Context, p renderParams) (*synthOut, error) {
	m.mu2.Lock()
	m.heldN = append(m.heldN, m.d.usesInFlight())
	m.mu2.Unlock()
	return m.fakePorts.Render(ctx, p)
}

func (m *memPorts) counts() (held, wait []int) {
	m.mu2.Lock()
	defer m.mu2.Unlock()
	return append([]int(nil), m.heldN...), append([]int(nil), m.waitN...)
}

func (m *memPorts) setBattery(on bool) { m.mu.Lock(); m.onBattery = on; m.mu.Unlock() }

func pausedFixture(t *testing.T) (*Daemon, *memPorts, *producer) {
	t.Helper()
	d := smallMemDaemon(t, 16)
	powerPoll = 20 * time.Millisecond
	t.Cleanup(func() { powerPoll = 30 * time.Second })
	m := &memPorts{fakePorts: newFakePorts(t), d: d}
	p := newProducer(m)
	p.start()
	t.Cleanup(func() { p.shutdown() })
	return d, m, p
}

func waitStatus(t *testing.T, p *producer, id, want string) {
	t.Helper()
	testutilWait(t, func() bool { s, _ := p.status(id); return s.Status == want }, want)
}

func testutilWait(t *testing.T, ok func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("never reached: %s", what)
}

// A voiceover paused on battery gives the turn back: the fast voice is served (and evicts the studio voice) while the
// laptop is unplugged, and after the plug-in the next take claims the turn again and renders - the fast voice is
// evicted in turn. Nothing stays claimed once the job is done.
// Mutations: produce.go waitPower, delete `j.turn.drop()` before the select -> the fast voice is refused during the
// pause -> RED; delete the `return j.turn.take()` after the loop (return nil) -> the next take renders without the turn
// -> RED.
func TestPausedOnBatteryVoiceoverGivesTheTurnBackAndTakesItAgain(t *testing.T) {
	d, m, p := pausedFixture(t)
	if err := voxSpeak(context.Background(), d); err != nil { // the studio voice is resident
		t.Fatal(err)
	}
	voxPid := d.VoxSup.Status().PID
	m.setBattery(true)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitStatus(t, p, s.ID, vproject.StatusPausedOnBattery)
	testutilWait(t, func() bool { return d.usesInFlight() == 0 }, "the paused job to give the turn back")

	old := engineTurnBudget
	engineTurnBudget = 2 * time.Second
	err = fastSpeak(t, d)
	engineTurnBudget = old
	if err != nil {
		t.Fatalf("the fast voice during a battery pause: %v", err)
	}
	if alive(voxPid) {
		t.Fatalf("studio voice child %d was not evicted for the fast voice during the pause", voxPid)
	}
	fastPid := d.Sup.Status().PID

	m.setBattery(false)
	if got := waitTerminal(t, p, s.ID); got.Status != vproject.StatusDone {
		t.Fatalf("%+v", got)
	}
	held, _ := m.counts()
	if len(held) == 0 {
		t.Fatal("no take rendered after the pause")
	}
	for i, n := range held {
		if n == 0 {
			t.Fatalf("take %d rendered without the job holding the turn after the pause", i)
		}
	}
	if alive(fastPid) {
		t.Fatalf("fast voice child %d survived the job's next take: two large engines resident", fastPid)
	}
	if n := d.usesInFlight(); n != 0 {
		t.Fatalf("%d uses still counted after the job ended", n)
	}
}

// A dictation wait gives the turn back too and the next render takes it again.
// Mutations: produce.go quiet, delete `j.turn.drop()` in the onWait callback -> the arbiter is still claimed during the
// wait -> RED; replace `return j.turn.take()` by `return nil` -> the take after the wait renders without the turn ->
// RED.
func TestDictationWaitGivesTheTurnBackAndTakesItAgain(t *testing.T) {
	d, m, p := pausedFixture(t)
	m.quietFn = func(ctx context.Context, onWait func()) error {
		onWait()
		m.mu2.Lock()
		m.waitN = append(m.waitN, d.usesInFlight())
		m.mu2.Unlock()
		select {
		case <-time.After(30 * time.Millisecond):
		case <-ctx.Done():
			return ctx.Err()
		}
		return nil
	}
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	if got := waitTerminal(t, p, s.ID); got.Status != vproject.StatusDone {
		t.Fatalf("%+v", got)
	}
	held, wait := m.counts()
	if len(wait) == 0 || len(held) == 0 {
		t.Fatalf("waits %v renders %v", wait, held)
	}
	for i, n := range wait {
		if n != 0 {
			t.Fatalf("dictation wait %d still held the turn (uses %d)", i, n)
		}
	}
	for i, n := range held {
		if n == 0 {
			t.Fatalf("take %d rendered without the turn after a dictation wait", i)
		}
	}
	if n := d.usesInFlight(); n != 0 {
		t.Fatalf("%d uses still counted after the job ended", n)
	}
}

// A cancel while paused leaves no turn held; a cancel while the job is waiting to take its turn back (the fast voice
// holds it) is a cancel, not a failure, and still leaves nothing claimed by the job.
// Mutations: produce.go turnHold.take, delete the `h.j.cancel.Load()` branch -> the second case reads as failed -> RED;
// produce.go holdTurn, delete `h.drop()` from the defer while the job is mid-take -> covered by
// TestCancelledProducerJobReleasesItsTurn.
func TestCancelWhilePausedLeavesNoTurnHeld(t *testing.T) {
	d, m, p := pausedFixture(t)
	m.setBattery(true)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitStatus(t, p, s.ID, vproject.StatusPausedOnBattery)
	if err := p.cancel(s.ID); err != nil {
		t.Fatal(err)
	}
	if got := waitTerminal(t, p, s.ID); got.Status != vproject.StatusCancelled {
		t.Fatalf("cancel while paused: %s", got.Status)
	}
	if n := d.usesInFlight(); n != 0 {
		t.Fatalf("%d uses still counted after a cancel while paused", n)
	}

	// Second job: paused, then plugged in while the fast voice holds the turn, cancelled while it waits for it.
	s2, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitStatus(t, p, s2.ID, vproject.StatusPausedOnBattery)
	testutilWait(t, func() bool { return d.usesInFlight() == 0 }, "the second job to give the turn back")
	leave, err := d.mem.enter(context.Background(), d.Sup, 0) // a fast-voice request in flight
	if err != nil {
		t.Fatal(err)
	}
	m.setBattery(false) // the job now waits for the turn
	time.Sleep(150 * time.Millisecond)
	if err := p.cancel(s2.ID); err != nil {
		t.Fatal(err)
	}
	if got := waitTerminal(t, p, s2.ID); got.Status != vproject.StatusCancelled {
		t.Fatalf("cancel while waiting for the turn: %s", got.Status)
	}
	leave()
	if n := d.usesInFlight(); n != 0 {
		t.Fatalf("%d uses still counted", n)
	}
}
