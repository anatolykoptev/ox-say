package daemon

import (
	"context"
	"sync"
	"testing"
)

// qosRecorder stands in for setpriority: it remembers the last QoS set per pid.
type qosRecorder struct {
	mu    sync.Mutex
	low   map[int]bool
	calls []string
}

func (r *qosRecorder) set(pid int, on bool) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.low == nil {
		r.low = map[int]bool{}
	}
	r.low[pid] = on
	return nil
}

func (r *qosRecorder) lowered(pid int) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.low[pid]
}

// #156.7: the producer lowers the shared child's QoS for its job, but an
// interactive speak that reaches the same child runs at full speed and the
// child goes back to background when it finishes.
// Mutation: speak.go speechOn, delete the `defer d.voxQoS.beginInteractive()()`
// line -> the child stays lowered during the speak -> RED.
func TestInteractiveSpeakRunsAtFullQoSDuringARender(t *testing.T) {
	d, _, logPath := voxFixture(t, nil)
	t.Setenv("OXSAY_FAKE_VOX_DELAY_MS", "1000")
	rec := &qosRecorder{}
	d.voxQoS.set = rec.set
	if _, err := d.VoxSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := d.VoxSup.Status().PID
	ports := d.producePorts()
	ports.Background(true) // the producer job starts
	if !rec.lowered(pid) {
		t.Fatal("the producer did not lower the engine's QoS")
	}
	spoke := make(chan error, 1)
	go func() {
		_, err := d.speechOn(context.Background(), d.VoxSup, map[string]any{"model": "voxcpm2", "input": "hello there"})
		spoke <- err
	}()
	waitForFile(t, logPath) // the speak is at the engine
	if rec.lowered(pid) {
		t.Error("an interactive speak ran at the producer's lowered QoS")
	}
	if err := <-spoke; err != nil {
		t.Fatal(err)
	}
	if !rec.lowered(pid) {
		t.Error("the child was not lowered again after the interactive speak, while the job still runs")
	}
	ports.Background(false)
	if rec.lowered(pid) {
		t.Error("the child stayed lowered after the job ended")
	}
}

// The producer's own render (renderWithin marks its context) never counts as
// interactive: it must not lift the QoS it set.
// Mutation: speak.go speechOn, drop the `use == nil` condition from the
// interactive test -> the render lifts its own QoS -> RED.
func TestProducerRenderStaysLowered(t *testing.T) {
	d, _, logPath := voxFixture(t, nil)
	t.Setenv("OXSAY_FAKE_VOX_DELAY_MS", "800")
	rec := &qosRecorder{}
	d.voxQoS.set = rec.set
	if _, err := d.VoxSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := d.VoxSup.Status().PID
	ports := d.producePorts()
	ports.Background(true)
	done := make(chan error, 1)
	go func() {
		tk := &taker{ports: ports, dir: t.TempDir()}
		_, err := tk.renderWithin(context.Background(), takeSpec{Text: "hello there", Seed: 1, Cfg: 2, Steps: 10})
		done <- err
	}()
	waitForFile(t, logPath)
	if !rec.lowered(pid) {
		t.Error("the producer's render ran at full QoS")
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

// A child that restarted while the job runs is lowered too, and the old pid is
// never "restored": a fresh child starts at normal priority.
// Mutation: engine_use.go applyLocked, `g.lowPID != pid` -> `false` -> the
// restarted child is never lowered -> RED.
func TestQoSGateFollowsARestartedChild(t *testing.T) {
	rec := &qosRecorder{}
	pid := 100
	g := &qosGate{pid: func() int { return pid }, set: rec.set, log: testLogger(t)}
	g.setBackground(true)
	if !rec.lowered(100) {
		t.Fatal("first child not lowered")
	}
	pid = 200 // the engine was recycled
	g.apply()
	if !rec.lowered(200) {
		t.Fatal("restarted child not lowered")
	}
	end := g.beginInteractive()
	if rec.lowered(200) {
		t.Fatal("interactive request did not lift the child")
	}
	end()
	end() // idempotent: a double end must not unbalance the count
	if !rec.lowered(200) {
		t.Fatal("child not lowered again after the request")
	}
	g.setBackground(false)
	if rec.lowered(200) {
		t.Fatal("child left lowered after the job")
	}
}
