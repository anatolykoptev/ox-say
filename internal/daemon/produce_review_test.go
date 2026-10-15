package daemon

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

const cancelWithin = 2 * time.Second

// A resume sent while a cancel is pending is refused (409, plain words)
// instead of answering "running" for a job that ends cancelled. Refusing, not
// clearing the flag: the user asked to stop, and a checkpoint may already have
// acted on that.
// Mutation: produce_ops.go resume, delete the `cur.cancel.Load()` refusal -> RED.
func TestResumeWhileCancellingIsRefused(t *testing.T) {
	f := newFakePorts(t)
	f.block, f.started = make(chan struct{}), make(chan struct{}, 8)
	d, mux := produceMux(t, f)
	s, err := d.prod.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	<-f.started
	if err := d.prod.cancel(s.ID); err != nil {
		t.Fatal(err)
	}
	rec := do(mux, http.MethodPost, "/v1/produce/"+s.ID+"/resume", `{}`)
	if rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), "still cancelling") {
		t.Fatalf("resume while cancelling: %d %s", rec.Code, rec.Body)
	}
	close(f.block)
	if got := waitTerminal(t, d.prod, s.ID); got.Status != vproject.StatusCancelled {
		t.Fatalf("%+v", got)
	}
}

// A cancel ends a wait for dictation or for AC power within a moment, not at
// the end of the wait.
// Mutation: produce_ops.go cancel, delete `p.cur.stopWait()` -> the 30 s wait runs on -> RED.
func TestCancelEndsWaits(t *testing.T) {
	for name, setup := range map[string]func(*fakePorts){
		"dictation": func(f *fakePorts) { f.quietWait = 30 * time.Second },
		"battery":   func(f *fakePorts) { f.onBattery = true },
	} {
		t.Run(name, func(t *testing.T) {
			f := newFakePorts(t)
			setup(f)
			p := startedProducer(t, f)
			s, err := p.create(reelInput(t))
			if err != nil {
				t.Fatal(err)
			}
			time.Sleep(150 * time.Millisecond)
			start := time.Now()
			if err := p.cancel(s.ID); err != nil {
				t.Fatal(err)
			}
			got := waitTerminal(t, p, s.ID)
			if got.Status != vproject.StatusCancelled || time.Since(start) > cancelWithin {
				t.Fatalf("%s after %s", got.Status, time.Since(start))
			}
		})
	}
}

// A wedged engine becomes a failed job in plain words; a port that ignores
// its context cannot hold the job either.
// Mutation: produce_take.go renderWithin, call the port with ctx and no deadline/select -> the job runs forever -> RED.
func TestWedgedRenderFailsTheJob(t *testing.T) {
	old := renderDeadline
	renderDeadline = func(int) time.Duration { return 150 * time.Millisecond }
	t.Cleanup(func() { renderDeadline = old })
	for name, setup := range map[string]func(*fakePorts){
		"ignores its context": func(f *fakePorts) { f.hang = make(chan struct{}); t.Cleanup(func() { close(f.hang) }) },
		"honours its context": func(f *fakePorts) { f.block = make(chan struct{}) },
	} {
		t.Run(name, func(t *testing.T) {
			f := newFakePorts(t)
			setup(f)
			p := startedProducer(t, f)
			s, err := p.create(reelInput(t))
			if err != nil {
				t.Fatal(err)
			}
			got := waitTerminal(t, p, s.ID)
			if got.Status != vproject.StatusFailed || !strings.Contains(got.Error, "did not answer in time") {
				t.Fatalf("%+v", got)
			}
		})
	}
}

// renderDeadline grows with the text and never drops below its floor.
func TestRenderDeadlineScalesWithTheText(t *testing.T) {
	if renderDeadline(10) != renderFloor {
		t.Fatalf("short text: %s", renderDeadline(10))
	}
	if renderDeadline(400) <= renderFloor || renderDeadline(4000) <= renderDeadline(400) {
		t.Fatalf("400 chars %s, 4000 chars %s", renderDeadline(400), renderDeadline(4000))
	}
}

// An unusable output folder setting is refused at create time, before any
// render, in plain words.
// Mutation: produce_ops.go outputPath, delete the IsAbs check -> renders happen, then the job fails -> RED.
func TestRelativeOutputRootRefusedBeforeRendering(t *testing.T) {
	for _, root := range []string{"Movies/ox-say", "~/Movies/ox-say"} {
		f := newFakePorts(t)
		f.outRoot = root
		_, mux := produceMux(t, f)
		rec := do(mux, http.MethodPost, "/v1/produce", `{"script":"Привет."}`)
		if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "OX_SAY_PRODUCE_OUT_DIR") {
			t.Errorf("%q: %d %s", root, rec.Code, rec.Body)
		}
		if len(f.renders) != 0 {
			t.Errorf("%q: rendered before refusing", root)
		}
		if entries, _ := os.ReadDir(filepath.Join(f.home, produceDir)); len(entries) != 0 {
			t.Errorf("%q: a project was created", root)
		}
	}
}

// An empty body is {}; data after the JSON object is a 400; a title is capped
// like the derived one.
// Mutation: produce_http.go decodeStrict, delete the io.EOF case -> RED.
// Mutation: produce_http.go decodeStrict, delete the trailing-token check -> RED.
// Mutation: produce_ops.go title, return the user's title uncut -> RED.
func TestProduceHTTPBodyEdges(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	const unknownID = "20261015-120000-abcdef"
	if rec := do(mux, http.MethodPost, "/v1/produce/"+unknownID+"/resume", ""); rec.Code != http.StatusNotFound {
		t.Errorf("empty resume body: %d %s", rec.Code, rec.Body)
	}
	if rec := do(mux, http.MethodPost, "/v1/produce", `{"script":"Привет."}{"x":1}`); rec.Code != http.StatusBadRequest {
		t.Errorf("trailing object: %d %s", rec.Code, rec.Body)
	}
	long := strings.Repeat("я", 500)
	rec := do(mux, http.MethodPost, "/v1/produce", `{"script":"Привет.","title":"`+long+`"}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	if n := utf8.RuneCountInString(extractTitle(rec.Body.String())); n == 0 || n > titleRunes {
		t.Errorf("title has %d runes, want 1..%d", n, titleRunes)
	}
}

func extractTitle(body string) string {
	_, rest, _ := strings.Cut(body, `"title":"`)
	t, _, _ := strings.Cut(rest, `"`)
	return t
}

// D12 on the producer's real path: every render and every transcription is
// immediately preceded by a wait for quiet (#149.5, review round 1).
// Mutation: produce_take.go gate, delete the pre-Hear t.quiet call -> RED.
// Mutation: produce_take.go render, delete the pre-Render t.quiet call -> RED.
func TestEveryRenderAndHearFollowsAQuietWait(t *testing.T) {
	f := newFakePorts(t)
	p := startedProducer(t, f)
	s, err := p.create(reelInput(t))
	if err != nil {
		t.Fatal(err)
	}
	waitTerminal(t, p, s.ID)
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.events) == 0 {
		t.Fatal("no events")
	}
	for i, e := range f.events {
		if (e == "render" || e == "hear") && (i == 0 || f.events[i-1] != "quiet") {
			t.Fatalf("%s at %d not preceded by a quiet wait: %v", e, i, f.events)
		}
	}
}

// The wiring in produce_wire.go is the real one: a stub for the dictation
// yield or the power reader would leave every fake-port test green.
// Mutation: produce_wire.go, `quiet: d.waitQuiet` -> `quiet: func(context.Context, func()) error { return nil }` -> RED.
func TestRealPortsQuietWaitsForDictation(t *testing.T) {
	d := newTestDaemon(t, t.TempDir(), nil)
	interactiveQuiet = 20 * time.Millisecond
	t.Cleanup(func() { interactiveQuiet = 3 * time.Second })
	ports := d.producePorts()
	d.inflight.Add(1)
	done := make(chan error, 1)
	go func() { done <- ports.Quiet(context.Background(), func() {}) }()
	select {
	case <-done:
		t.Fatal("Quiet returned while a dictation request was in flight")
	case <-time.After(200 * time.Millisecond):
	}
	d.inflight.Add(-1)
	d.lastInteractiveEnd.Store(time.Now().UnixNano())
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(cancelWithin):
		t.Fatal("Quiet did not return after the dictation request ended")
	}
}

// Mutation: produce_wire.go, `power: powerState` -> `power: func(context.Context) (bool, bool) { return false, false }` -> RED.
func TestRealPortsPowerReadsPmset(t *testing.T) {
	d := newTestDaemon(t, t.TempDir(), nil)
	old := pmsetOutput
	t.Cleanup(func() { pmsetOutput = old })
	pmsetOutput = func(_ context.Context, args ...string) ([]byte, error) {
		if len(args) == 2 && args[1] == "batt" {
			return []byte(pmsetBatt), nil
		}
		return []byte(pmsetLow), nil
	}
	if onBattery, low := d.producePorts().Power(context.Background()); !onBattery || !low {
		t.Fatalf("battery=%v low=%v, want both", onBattery, low)
	}
	pmsetOutput = func(context.Context, ...string) ([]byte, error) { return []byte(pmsetACBatt), nil }
	if onBattery, low := d.producePorts().Power(context.Background()); onBattery || low {
		t.Fatalf("AC power read as battery=%v low=%v", onBattery, low)
	}
}

// A failed engine read is not remembered: the next job tries again.
// Mutation: produce_wire.go engineID, cache the error with the id (sync.Once) -> RED.
func TestEngineIDErrorIsNotCached(t *testing.T) {
	dir := t.TempDir()
	d := newTestDaemon(t, dir, nil)
	d.Cfg.VoxCPM2Bin, d.Cfg.VoxCPM2Model = filepath.Join(dir, "audiocpp_server"), filepath.Join(dir, "m.gguf")
	ports := d.producePorts()
	if _, err := ports.EngineID(); err == nil {
		t.Fatal("a missing engine was identified")
	}
	for _, f := range []string{d.Cfg.VoxCPM2Bin, d.Cfg.VoxCPM2Model} {
		if err := os.WriteFile(f, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	id, err := ports.EngineID()
	if err != nil || id == "" {
		t.Fatalf("the failure was cached: %q %v", id, err)
	}
	if again, _ := ports.EngineID(); again != id {
		t.Fatalf("identity changed: %q vs %q", again, id)
	}
}
