package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
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
	go func() { d.producePorts().Recycle(context.Background(), pid); close(recycled) }()
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
