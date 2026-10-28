package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

func shortDeadline(t *testing.T, d time.Duration) {
	t.Helper()
	old := renderDeadline
	renderDeadline = func(int) time.Duration { return d }
	t.Cleanup(func() { renderDeadline = old })
}

// #156.12b: a render that gets no answer from the engine within its deadline
// asks the supervisor to recycle exactly the child it reached.
// Mutation: produce_take.go renderWithin, delete the t.recycle(...) calls ->
// no recycle is requested -> RED.
func TestRenderDeadlineRecyclesTheChildItReached(t *testing.T) {
	shortDeadline(t, 100*time.Millisecond)
	for name, setup := range map[string]func(*fakePorts){
		"honours its context": func(f *fakePorts) { f.block = make(chan struct{}) },
		"ignores its context": func(f *fakePorts) { f.hang = make(chan struct{}); t.Cleanup(func() { close(f.hang) }) },
	} {
		t.Run(name, func(t *testing.T) {
			f := newFakePorts(t)
			setup(f)
			tk := &taker{ports: f, dir: t.TempDir()}
			_, err := tk.renderWithin(context.Background(), takeSpec{Text: "hello"})
			if err == nil || !strings.Contains(err.Error(), "did not answer in time") {
				t.Fatalf("err = %v", err)
			}
			if got := f.recycled(); len(got) != 1 || got[0] != fakeEnginePID {
				t.Fatalf("recycled %v, want [%d]", got, fakeEnginePID)
			}
			// Mutation: produce_take.go recycle, pass 0 instead of use.seq.Load()
			// -> the age rule is off (every request blocks) -> RED.
			if got := f.recycledFrom(); len(got) != 1 || got[0] != fakeEngineSeq {
				t.Fatalf("recycle carried send stamps %v, want [%d]", got, fakeEngineSeq)
			}
		})
	}
}

// Only a render the engine never answered recycles. A take that came back and
// failed its checks, a render the user cancelled, an engine that answered with
// an error, and a deadline that hit before any child was reached do not.
// Mutation: produce_take.go renderWithin, call t.recycle in the success path
// or when ctx.Err() != nil -> the matching case is RED.
func TestOnlyAnUnansweredRenderRecycles(t *testing.T) {
	shortDeadline(t, 150*time.Millisecond)
	t.Run("take failed its checks", func(t *testing.T) {
		f := newFakePorts(t)
		f.silentAt = map[int]bool{}
		for i := 0; i < 50; i++ {
			f.silentAt[i] = true
		}
		p := startedProducer(t, f)
		s, err := p.create(reelInput(t))
		if err != nil {
			t.Fatal(err)
		}
		waitTerminal(t, p, s.ID)
		if len(f.renders) == 0 || len(f.recycled()) != 0 {
			t.Fatalf("renders %d, recycled %v", len(f.renders), f.recycled())
		}
	})
	t.Run("user cancels", func(t *testing.T) {
		f := newFakePorts(t)
		f.block = make(chan struct{})
		tk := &taker{ports: f, dir: t.TempDir()}
		ctx, cancel := context.WithCancel(context.Background())
		time.AfterFunc(40*time.Millisecond, cancel)
		if _, err := tk.renderWithin(ctx, takeSpec{Text: "hello"}); !errors.Is(err, context.Canceled) {
			t.Fatalf("err = %v", err)
		}
		if got := f.recycled(); len(got) != 0 {
			t.Fatalf("recycled %v after a user cancel", got)
		}
	})
	t.Run("no child reached", func(t *testing.T) {
		f := newFakePorts(t)
		f.block, f.noPID = make(chan struct{}), true
		tk := &taker{ports: f, dir: t.TempDir()}
		if _, err := tk.renderWithin(context.Background(), takeSpec{Text: "hello"}); err == nil {
			t.Fatal("want the engine timeout")
		}
		if got := f.recycled(); len(got) != 0 {
			t.Fatalf("recycled %v with no child reached", got)
		}
	})
}

func hangOnceFixture(t *testing.T) (d *Daemon, hangFile string) {
	t.Helper()
	d, dir, _ := voxFixture(t, func(c *config.Config) { c.Lang = "en" })
	hangFile = filepath.Join(dir, "hang-once")
	t.Setenv("OXSAY_FAKE_VOX_HANG_ONCE", hangFile)
	return d, hangFile
}

// The whole path against a real supervisor and a child that accepts a request
// and never answers: after the deadline the child is recycled and the next
// request is served by a fresh pid.
// Mutation: produce_wire.go portFuncs.Recycle, return before calling
// d.VoxSup.Recycle -> the wedged pid stays -> RED.
func TestWedgedChildIsReplacedAfterTheDeadline(t *testing.T) {
	d, _ := hangOnceFixture(t)
	if _, err := d.VoxSup.EnsureReady(context.Background()); err != nil { // warm: no cold-start slack
		t.Fatal(err)
	}
	wedged := d.VoxSup.Status().PID
	shortDeadline(t, 400*time.Millisecond)
	tk := &taker{ports: d.producePorts(), dir: t.TempDir()}
	spec := takeSpec{Text: "ox-say is ready", Seed: 1, Cfg: 2, Steps: 10}
	if _, err := tk.renderWithin(context.Background(), spec); err == nil || !strings.Contains(err.Error(), "did not answer in time") {
		t.Fatalf("first render: %v", err)
	}
	if _, err := tk.renderWithin(context.Background(), spec); err != nil {
		t.Fatalf("the next render after the recycle: %v", err)
	}
	if st := d.VoxSup.Status(); st.PID == wedged || st.Starts != 2 || st.State != engine.StateReady {
		t.Fatalf("pid %d (wedged %d) starts %d state %s: the wedged child was not replaced", st.PID, wedged, st.Starts, st.State)
	}
}

// Interactive speak is never killed mid-request: a recycle asked while a
// speak is in flight waits for it, the speak succeeds, and only then is the
// child replaced.
// Mutation: supervisor.go Recycle, stop the child without the `s.guards == 0`
// wait -> the speak fails -> RED.
func TestRecycleNeverKillsAnInteractiveSpeak(t *testing.T) {
	d, dir, logPath := voxFixture(t, nil)
	t.Setenv("OXSAY_FAKE_VOX_DELAY_MS", "1200")
	if _, err := d.VoxSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := d.VoxSup.Status().PID
	spoke := make(chan error, 1)
	go func() {
		_, err := d.speechOn(context.Background(), d.VoxSup, map[string]any{"model": "voxcpm2", "input": "hello there"})
		spoke <- err
	}()
	waitForFile(t, logPath) // the request reached the engine
	recycled := make(chan struct{})
	go func() { d.producePorts().Recycle(context.Background(), pid, 0); close(recycled) }()
	select {
	case <-recycled:
		t.Fatal("Recycle returned while the interactive speak was in flight")
	case err := <-spoke:
		t.Fatalf("the speak ended before the recycle could be judged: %v", err)
	case <-time.After(300 * time.Millisecond):
	}
	if err := <-spoke; err != nil {
		t.Fatalf("the interactive speak was killed: %v", err)
	}
	select {
	case <-recycled:
	case <-time.After(10 * time.Second):
		t.Fatal("Recycle never ran after the speak finished")
	}
	_ = dir
	if _, err := d.VoxSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	if d.VoxSup.Status().PID == pid {
		t.Fatal("the child was not replaced once the speak finished")
	}
}

func waitForFile(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if st, err := os.Stat(path); err == nil && st.Size() > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("%s never appeared", path)
}

// voxFixtureTuned is voxFixture with a say over the voxcpm2 supervisor.
func voxFixtureTuned(t *testing.T, tune func(*engine.Config)) (d *Daemon, logPath string) {
	t.Helper()
	dir := t.TempDir()
	fakeEnv(t, dir)
	logPath = filepath.Join(dir, "vox.log")
	t.Setenv("OXSAY_FAKE_VOX", "1")
	t.Setenv("OXSAY_FAKE_VOX_LOG", logPath)
	model := filepath.Join(dir, config.VoxCPM2ModelFile)
	if err := os.WriteFile(model, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	d = newTestDaemonVox(t, dir, func(c *config.Config) {
		c.GPUMemory = config.GPUMemoryUnified
		c.VoxCPM2Bin = os.Args[0]
		c.VoxCPM2Model = model
		c.VoxCPM2Port = testutil.FreePort(t)
		c.Lang = "en"
	}, nil, nil, tune)
	return d, logPath
}

// waitForLines waits until the file holds at least n lines.
func waitForLines(t *testing.T, path string, n int) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(path); err == nil && strings.Count(string(b), "\n") >= n {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("%s never reached %d lines", path, n)
}

func within(t *testing.T, what string, d time.Duration, ch <-chan error) error {
	t.Helper()
	select {
	case err := <-ch:
		return err
	case <-time.After(d):
		t.Fatalf("%s did not finish within %s", what, d)
		return nil
	}
}

// spyPorts wraps the daemon's producer ports to observe the recycle and to
// hold it back until the test says the scene is set - so the tests wait on
// events, never on wall-clock margins.
type spyPorts struct {
	producePorts
	gate    func()        // runs first inside Recycle; may block
	entered chan struct{} // closed when Recycle is entered
	once    sync.Once
}

func (p *spyPorts) Recycle(ctx context.Context, pid int, from uint64) {
	p.once.Do(func() { close(p.entered) })
	if p.gate != nil {
		p.gate()
	}
	p.producePorts.Recycle(ctx, pid, from)
}

// #338.1: an interactive speak queued behind a wedged child holds a Guard but
// is not being served, so it must not keep the wedged child alive. The render
// deadline replaces the child anyway, the queued speak fails with the engine
// transport error (the engine did not answer), and the next speak is served by
// the fresh child. The recycle is held until the speak has reached the child
// (the log has its line), so the speak is queued whatever the runner speed.
// Mutation: produce_wire.go portFuncs.recycle, call d.VoxSup.Recycle(ctx, pid)
// (wait for every guard) instead of RecycleWedged -> the recycle waits out
// RecycleWait (30 s) behind the queued speak -> RED.
func TestQueuedSpeakDoesNotKeepAWedgedChildAlive(t *testing.T) {
	d, logPath := voxFixtureTuned(t, nil)
	t.Setenv("OXSAY_FAKE_VOX_WEDGE_FIRST", filepath.Join(filepath.Dir(logPath), "wedged-child"))
	if _, err := d.VoxSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	wedged := d.VoxSup.Status().PID
	shortDeadline(t, time.Second)
	spy := &spyPorts{producePorts: d.producePorts(), entered: make(chan struct{})}
	spy.gate = func() { waitForLines(t, logPath, 2) } // the speak is queued behind the render
	tk := &taker{ports: spy, dir: t.TempDir()}
	rendered := make(chan error, 1)
	go func() {
		_, err := tk.renderWithin(context.Background(), takeSpec{Text: "ox-say is ready", Seed: 1, Cfg: 2, Steps: 10})
		rendered <- err
	}()
	waitForLines(t, logPath, 1) // the render is at the (now wedged) engine
	spoke := make(chan error, 1)
	go func() {
		_, err := d.speechOn(context.Background(), d.VoxSup, map[string]any{"model": "voxcpm2", "input": "hello there"})
		spoke <- err
	}()
	if err := within(t, "the render", 20*time.Second, rendered); err == nil || !strings.Contains(err.Error(), "did not answer in time") {
		t.Fatalf("render: %v", err)
	}
	var te *engineTransportError
	if err := within(t, "the queued speak", 20*time.Second, spoke); !errors.As(err, &te) {
		t.Fatalf("the queued speak: %v, want the engine-did-not-answer transport error", err)
	}
	if _, err := d.speechOn(context.Background(), d.VoxSup, map[string]any{"model": "voxcpm2", "input": "again"}); err != nil {
		t.Fatalf("the next speak after the recycle: %v", err)
	}
	if st := d.VoxSup.Status(); st.PID == wedged || st.State != engine.StateReady {
		t.Fatalf("pid %d (wedged %d) state %s: the wedged child was not replaced", st.PID, wedged, st.State)
	}
}

// A request the child is answering (slow, but answering) is never killed by a
// render's recycle, even when the render queued behind it timed out: the
// recycle waits for the older request, which succeeds, and only then replaces
// the child.
// Mutation: supervisor.go blockedLocked, `return false` at the top (guards
// ignored entirely) -> the child dies under the speak -> RED.
func TestRecycleDoesNotKillARequestBeingAnswered(t *testing.T) {
	d, logPath := voxFixtureTuned(t, nil)
	t.Setenv("OXSAY_FAKE_VOX_DELAY_MS", "1500")
	if _, err := d.VoxSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	pid := d.VoxSup.Status().PID
	spoke := make(chan error, 1)
	go func() {
		_, err := d.speechOn(context.Background(), d.VoxSup, map[string]any{"model": "voxcpm2", "input": "hello there"})
		spoke <- err
	}()
	waitForLines(t, logPath, 1)
	shortDeadline(t, 300*time.Millisecond)
	tk := &taker{ports: d.producePorts(), dir: t.TempDir()}
	if _, err := tk.renderWithin(context.Background(), takeSpec{Text: "queued behind the speak", Seed: 1, Cfg: 2, Steps: 10}); err == nil {
		t.Fatal("the render should have hit its deadline")
	}
	if err := within(t, "the speak", 10*time.Second, spoke); err != nil {
		t.Fatalf("the request being answered was killed: %v", err)
	}
	if _, err := d.VoxSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	if d.VoxSup.Status().PID == pid {
		t.Fatal("the child was not replaced once the speak finished")
	}
}

// #338.3: a user cancel while the recycle is killing the old child ends the
// job's wait at once; the kill carries on and the child still dies. The cancel
// is sent once the supervisor has marked the child stopped (the kill is under
// way, SIGTERM ignored, 6 s grace), not after a sleep.
// Mutation: produce_take.go recycle, pass context.Background() instead of ctx
// to t.ports.Recycle -> the job waits out the SIGTERM grace -> RED.
func TestCancelDuringTheRecycleKillEndsTheJobAtOnce(t *testing.T) {
	d, logPath := voxFixtureTuned(t, func(ec *engine.Config) { ec.KillGrace = 6 * time.Second })
	t.Setenv("OXSAY_FAKE_IGNORE_SIGTERM", "1")
	t.Setenv("OXSAY_FAKE_VOX_HANG_ONCE", filepath.Join(filepath.Dir(logPath), "hang-once"))
	if _, err := d.VoxSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	wedged := d.VoxSup.Status().PID
	shortDeadline(t, time.Second)
	spy := &spyPorts{producePorts: d.producePorts(), entered: make(chan struct{})}
	tk := &taker{ports: spy, dir: t.TempDir()}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	type res struct {
		err error
		at  time.Time
	}
	ended := make(chan res, 1)
	go func() {
		_, err := tk.renderWithin(ctx, takeSpec{Text: "ox-say is ready", Seed: 1, Cfg: 2, Steps: 10})
		ended <- res{err, time.Now()}
	}()
	select {
	case <-spy.entered:
	case <-time.After(20 * time.Second):
		t.Fatal("the render deadline never asked for a recycle")
	}
	for d.VoxSup.Status().State != engine.StateStopped { // userStop set: the kill is running
		select {
		case <-ended:
			t.Fatal("renderWithin returned before the kill started")
		case <-time.After(5 * time.Millisecond):
		}
	}
	cancelled := time.Now()
	cancel()
	select {
	case r := <-ended:
		if lag := r.at.Sub(cancelled); lag > 3*time.Second {
			t.Fatalf("the job ended %s after the cancel, waiting out the kill", lag)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("renderWithin never returned")
	}
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if syscall.Kill(wedged, 0) != nil {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("the wedged child survived: the kill must continue after the cancel")
}

// #338.2: the child may be cold-started by the producer's own render while the
// job already runs at background QoS. The only moment to lower it is right
// after EnsureReady, before the request goes out - the render's later apply()
// comes after the render.
// Mutation: speak.go speechOn, delete `d.voxQoS.apply()` -> the new child runs
// the whole first render at normal priority -> RED.
func TestColdStartedChildIsLoweredWhileTheFirstRenderRuns(t *testing.T) {
	d, logPath := voxFixtureTuned(t, nil)
	t.Setenv("OXSAY_FAKE_VOX_DELAY_MS", "1200")
	rec := &qosRecorder{}
	d.voxQoS.set = rec.set
	ports := d.producePorts()
	ports.Background(true) // the job starts with no child running
	done := make(chan error, 1)
	go func() {
		tk := &taker{ports: ports, dir: t.TempDir()}
		_, err := tk.renderWithin(context.Background(), takeSpec{Text: "hello there", Seed: 1, Cfg: 2, Steps: 10})
		done <- err
	}()
	waitForLines(t, logPath, 1) // the cold-started child has the request
	pid := d.VoxSup.Status().PID
	if pid <= 0 || !rec.lowered(pid) {
		t.Errorf("the cold-started child (pid %d) runs the first render at normal priority", pid)
	}
	if err := within(t, "the render", 20*time.Second, done); err != nil {
		t.Fatal(err)
	}
	ports.Background(false)
}
