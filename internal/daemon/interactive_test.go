package daemon

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// Every registered interactive pattern stamps; a non-interactive one does
// not. Mutation: register "POST /v1/audio/transcriptions/sessions/{id}/audio"
// without the wrapper -> RED.
func TestInteractiveRoutesStamp(t *testing.T) {
	d := newTestDaemon(t, t.TempDir(), nil)
	mux := http.NewServeMux()
	d.Routes(mux)
	for _, pat := range interactiveRoutes {
		method, path, _ := strings.Cut(pat, " ")
		path = strings.ReplaceAll(path, "{id}", strings.Repeat("a", 32))
		before := d.lastInteractiveEnd.Load()
		time.Sleep(time.Millisecond)
		mux.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(method, path, strings.NewReader(`{}`)))
		if d.lastInteractiveEnd.Load() == before || d.inflight.Load() != 0 {
			t.Errorf("%s did not stamp (or leaked in-flight)", pat)
		}
	}
	before := d.lastInteractiveEnd.Load()
	mux.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/status", nil))
	if d.lastInteractiveEnd.Load() != before {
		t.Error("/status stamped")
	}
	produceBefore := d.lastInteractiveEnd.Load()
	mux.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/v1/produce", nil))
	if d.lastInteractiveEnd.Load() != produceBefore {
		t.Error("a produce route stamped: the producer would starve itself")
	}
}

// The producer's own STT calls (voiceWords -> Transcribe, no HTTP) never stamp.
// Mutation: produce_wire.go, route hear through d.interactive-wrapped HTTP -> n/a; this
// pins the call path: stamping inside voiceWords -> RED.
func TestProducerSTTDoesNotStamp(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	sttSetup(t, d, dir)
	t.Setenv("OXSAY_FAKE_STT_JSON", `{"engine":"parakeet","language":"en","duration_s":1,"elapsed_s":0.1,"text":"hi","segments":[],"words":[{"w":"hi","s":0,"e":0.5,"p":0.9}]}`)
	wire := d.producePorts()
	clip := testutil.WriteTinyWAV(t, dir, "in.wav")
	before := d.lastInteractiveEnd.Load()
	if _, err := wire.Hear(context.Background(), clip); err != nil {
		t.Fatal(err)
	}
	if d.lastInteractiveEnd.Load() != before || d.inflight.Load() != 0 {
		t.Fatal("producer transcription stamped interactive traffic")
	}
}

// Quiet waits for zero in flight and 3 s since the last end; the bound
// releases a starved producer.
// Mutation: interactive.go waitQuiet, drop the maxYield branch -> never returns -> RED.
// Mutation: drop the interactiveQuiet comparison -> returns at once -> RED.
func TestWaitQuiet(t *testing.T) {
	d := newTestDaemon(t, t.TempDir(), nil)
	interactiveQuiet, maxYield, waitingAfter = 50*time.Millisecond, 200*time.Millisecond, 0
	t.Cleanup(func() { interactiveQuiet, maxYield, waitingAfter = 3*time.Second, 120*time.Second, 2*time.Second })
	d.inflight.Add(1)
	waited := false
	start := time.Now()
	if err := d.waitQuiet(context.Background(), func() { waited = true }); err != nil {
		t.Fatal(err)
	}
	if el := time.Since(start); el < 200*time.Millisecond || !waited {
		t.Fatalf("starvation bound not applied: %s waited=%v", el, waited)
	}
	d.inflight.Add(-1)
	d.lastInteractiveEnd.Store(time.Now().UnixNano())
	start = time.Now()
	_ = d.waitQuiet(context.Background(), func() {})
	if el := time.Since(start); el < 40*time.Millisecond {
		t.Fatalf("did not wait for quiet: %s", el)
	}
}

// Dictation stays fast (S5, D12): a transcription arriving while a producer
// render is in flight is answered at once - STT never waits on a render.
// Mutation: interactive.go interactive, call d.waitQuiet before h(w, r) -> the
// request waits for its own in-flight count -> RED.
func TestDictationNeverWaitsForARender(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	sttSetup(t, d, dir)
	t.Setenv("OXSAY_FAKE_STT_JSON", `{"engine":"parakeet","language":"en","duration_s":1,"elapsed_s":0.1,"text":"hi","segments":[],"words":[]}`)
	f := newFakePorts(t)
	f.block, f.started = make(chan struct{}), make(chan struct{}, 8)
	d.prod = newProducer(f)
	d.StartProducer()
	t.Cleanup(d.StopProducer)
	srv := transcriptionServer(t, d)

	in := reelInput(t)
	if _, err := d.prod.create(in); err != nil {
		t.Fatal(err)
	}
	<-f.started // a slow render is in flight and stays so
	start := time.Now()
	type answer struct {
		code int
		err  error
	}
	got := make(chan answer, 1)
	go func() {
		resp := postTranscription(t, srv.URL+"/v1/audio/transcriptions", testutil.TinyWAV(), nil)
		_, err := io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		got <- answer{resp.StatusCode, err}
	}()
	select {
	case a := <-got:
		t.Logf("transcribe during a blocked render: %s", time.Since(start))
		if a.code != http.StatusOK {
			t.Fatalf("status %d", a.code)
		}
	case <-time.After(dictationBudget):
		close(f.block)
		t.Fatalf("a transcription made no answer within %s while a render was in flight", dictationBudget)
	}
	close(f.block)
}

// dictationBudget is generous for a fake child on a loaded CI box; a wait on
// the producer would run to the render's end, which here never comes.
const dictationBudget = 5 * time.Second

// #156.8: the MCP speak and transcribe tools are interactive like their HTTP
// routes: in flight while they run, and their end is stamped so the producer
// waits out the quiet window.
// Mutation: mcp.go toolSpeak, delete `defer d.beginInteractive()()` -> RED;
// transcribe.go toolTranscribe, likewise -> RED.
func TestMCPToolsAreInteractive(t *testing.T) {
	for name, call := range map[string]func(d *Daemon){
		"speak":      func(d *Daemon) { _, _, _ = d.toolSpeak(context.Background(), nil, speakToolIn{}) },
		"transcribe": func(d *Daemon) { _, _, _ = d.toolTranscribe(context.Background(), nil, transcribeToolIn{}) },
	} {
		d, _, _ := voxFixture(t, nil)
		if d.lastInteractiveEnd.Load() != 0 {
			t.Fatalf("%s: stamp not zero at start", name)
		}
		call(d)
		if d.lastInteractiveEnd.Load() == 0 {
			t.Errorf("%s: the end of the call was not stamped as interactive", name)
		}
		if n := d.inflight.Load(); n != 0 {
			t.Errorf("%s: %d still counted in flight after the call", name, n)
		}
	}
}
