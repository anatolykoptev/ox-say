package daemon

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

const gib = 1 << 30

// smallMemDaemon is a daemon on a Mac that takes turns between its large engines while the studio-voice gate is
// open: the real memory is 48 GB (the gate passes) and OX_SAY_ASSUME_MEMORY_GB says 16 (the policy turns on) - the
// exact emulation a 48 GB test Mac runs. The fast voice, the studio voice and the notes engine are all wired to the
// test binary's fakes; STT is on, as in production. mem reports whether the policy is on.
func smallMemDaemon(t *testing.T, assumeGB uint64) *Daemon {
	t.Helper()
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_VOX", "1")
	t.Setenv("OXSAY_FAKE_STT", "1")
	t.Setenv("OXSAY_FAKE_VOX_LOG", filepath.Join(dir, "vox.log"))
	model := filepath.Join(dir, config.VoxCPM2ModelFile)
	notes := filepath.Join(dir, "models", config.NotesModelFile)
	_ = os.MkdirAll(filepath.Dir(notes), 0o755)
	for _, p := range []string{model, notes} {
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return newTestDaemonVox(t, dir, func(c *config.Config) {
		c.GPUMemory = config.GPUMemoryUnified
		c.VoxCPM2Bin = os.Args[0]
		c.VoxCPM2Model = model
		c.VoxCPM2Port = testutil.FreePort(t)
		c.NotesBin, c.NotesModel = os.Args[0], notes
		c.Lang = "en"
		c.HostMemoryBytes = 48 * gib
		c.AssumedMemoryBytes = assumeGB * gib
	}, nil, nil, nil)
}

func fastSpeak(t *testing.T, d *Daemon) error {
	t.Helper()
	_, err := d.speechOn(context.Background(), d.Sup, map[string]any{"input": "hi"})
	return err
}

func voxSpeak(ctx context.Context, d *Daemon) error {
	_, err := d.speechOn(ctx, d.VoxSup, map[string]any{"model": "voxcpm2", "input": "hello there"})
	return err
}

// notesCall runs one notes request on the fake ox-llm. The fakes are chosen by env at spawn, so the marker is set
// only around the call that spawns the notes child.
func notesCall(t *testing.T, d *Daemon) error {
	t.Helper()
	t.Setenv("OXSAY_FAKE_LLM", "1")
	defer t.Setenv("OXSAY_FAKE_LLM", "")
	_, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"})
	return err
}

func gone(pid int) bool { return !alive(pid) }

// Below the floor the studio voice and the fast voice take turns through the production path (speechOn, the one place
// every speech, voice-design and producer render starts an engine): starting one stops the other and waits for its
// exit, both ways. STT is untouched.
// Mutation (a): speak.go speechOn, delete the `leave, err := d.mem.enter(ctx, sup, budget)` statement (and its
// error check / defer) -> the fast voice's child is still alive after the studio voice answered -> RED.
func TestSmallMemoryVoiceEnginesTakeTurnsOnSpeech(t *testing.T) {
	d := smallMemDaemon(t, 16)
	if d.mem == nil {
		t.Fatal("OneLargeEngine on, but the daemon built no residency")
	}
	if err := fastSpeak(t, d); err != nil {
		t.Fatal(err)
	}
	fastPid := d.Sup.Status().PID
	if _, err := d.STTSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	sttPid := d.STTSup.Status().PID

	if err := voxSpeak(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	if alive(fastPid) {
		t.Fatalf("fast voice child %d is still alive after the studio voice answered: two large engines are resident", fastPid)
	}
	if d.Sup.State() != engine.StateStopped {
		t.Fatalf("fast voice state = %s, want stopped", d.Sup.State())
	}
	voxPid := d.VoxSup.Status().PID
	if voxPid == 0 || !alive(voxPid) {
		t.Fatal("the studio voice is not running after its own request")
	}

	if err := fastSpeak(t, d); err != nil {
		t.Fatal(err)
	}
	if alive(voxPid) {
		t.Fatalf("studio voice child %d is still alive after the fast voice answered", voxPid)
	}
	if st := d.STTSup.Status(); st.PID != sttPid || !alive(sttPid) || st.State != engine.StateReady {
		t.Fatalf("STT was disturbed: pid %d (was %d) state %s", st.PID, sttPid, st.State)
	}
}

// The producer's takes reach the studio voice through the same line with the producer's own context (engine use set,
// no budget): a cold start of the studio voice stops the running fast voice first.
// Mutation (b): speak.go speechOn, same statement as (a) (the producer has no other start path) -> the fast voice is
// still alive after the take -> RED.
func TestSmallMemoryProducerColdStartEvictsTheFastVoice(t *testing.T) {
	d := smallMemDaemon(t, 16)
	if err := fastSpeak(t, d); err != nil {
		t.Fatal(err)
	}
	fastPid := d.Sup.Status().PID
	if d.VoxSup.State() == engine.StateReady {
		t.Fatal("setup: the studio voice must be cold")
	}
	ctx, use := withEngineUse(context.Background())
	if _, err := d.producePorts().Render(ctx, renderParams{Text: "hello there", Seed: 1, Cfg: 2, Steps: 10}); err != nil {
		t.Fatalf("the producer's take on a cold studio voice: %v", err)
	}
	if use.pid.Load() == 0 {
		t.Fatal("the take did not reach the studio voice child")
	}
	if alive(fastPid) {
		t.Fatalf("fast voice child %d survived the producer's cold start of the studio voice", fastPid)
	}
}

// The notes model takes a turn too: a notes call stops the fast voice and the studio voice, and speech after it stops
// the notes model.
// Mutation: meetings.go llmChat.Complete, delete the `c.d.mem.enter(ctx, c.d.LLMSup, 0)` statement -> the fast voice is
// still alive during the notes call -> RED.
func TestSmallMemoryNotesModelTakesItsTurn(t *testing.T) {
	d := smallMemDaemon(t, 16)
	if err := fastSpeak(t, d); err != nil {
		t.Fatal(err)
	}
	fastPid := d.Sup.Status().PID
	if err := notesCall(t, d); err != nil {
		t.Fatal(err)
	}
	if alive(fastPid) {
		t.Fatalf("fast voice child %d survived a notes call", fastPid)
	}
	notesPid := d.LLMSup.Status().PID
	if notesPid == 0 || !alive(notesPid) {
		t.Fatal("the notes model is not running after its call")
	}
	if err := fastSpeak(t, d); err != nil {
		t.Fatal(err)
	}
	if alive(notesPid) {
		t.Fatalf("notes child %d survived a fast-voice request", notesPid)
	}
}

// Same wiring on the HTTP stream path of the fast voice (engineBase): a streamed fast-voice request stops a running
// studio voice.
// Mutation: service.go engineBase, delete the `d.mem.enter(ctx, d.Sup, engineTurnBudget)` statement -> the studio voice
// is still alive -> RED.
func TestSmallMemoryStreamedFastVoiceEvictsTheStudioVoice(t *testing.T) {
	d := smallMemDaemon(t, 16)
	if err := voxSpeak(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	voxPid := d.VoxSup.Status().PID
	mux := http.NewServeMux()
	d.Routes(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/audio/speech", strings.NewReader(`{"model":"qwen3-tts","input":"hi"}`)))
	if rec.Code != http.StatusOK {
		t.Fatalf("streamed fast voice: %d %s", rec.Code, bodyText(rec))
	}
	if alive(voxPid) {
		t.Fatalf("studio voice child %d survived a streamed fast-voice request", voxPid)
	}
}

// A request is never cut: while the studio voice renders, a fast-voice request waits its turn, gives up after the
// budget with the typed 503 (engine_busy_memory) and the render finishes untouched; once it is done the fast voice
// gets its turn.
// Mutation: residency.go take, make the `case r.n > 0:` wait fall through to the claim (drop the case) -> the fast
// voice evicts the studio voice mid-render and the render fails -> RED.
func TestSmallMemoryNeverStopsAnEngineMidRequest(t *testing.T) {
	d := smallMemDaemon(t, 16)
	old := engineTurnBudget
	engineTurnBudget = 300 * time.Millisecond
	t.Cleanup(func() { engineTurnBudget = old })
	t.Setenv("OXSAY_FAKE_VOX_DELAY_MS", "1500")
	voxDone := make(chan error, 1)
	go func() { voxDone <- voxSpeak(context.Background(), d) }()
	waitForFile(t, os.Getenv("OXSAY_FAKE_VOX_LOG")) // the request reached the engine
	voxPid := d.VoxSup.Status().PID

	start := time.Now()
	err := fastSpeak(t, d)
	var busy *engineBusyError
	if !errors.As(err, &busy) {
		t.Fatalf("fast voice during a render = %v, want the typed engineBusyError", err)
	}
	if !errors.Is(err, errEngineStart) || synthStatus(err) != http.StatusServiceUnavailable {
		t.Fatalf("busy error must map to 503, got status %d", synthStatus(err))
	}
	if el := time.Since(start); el > 5*time.Second {
		t.Fatalf("the bounded wait took %s", el)
	}
	if gone(voxPid) {
		t.Fatal("the studio voice was stopped while it was rendering")
	}
	rec := httptest.NewRecorder()
	writeSynthErr(rec, err)
	if rec.Code != http.StatusServiceUnavailable || !strings.Contains(rec.Body.String(), engineBusyCode) {
		t.Fatalf("typed answer = %d %s", rec.Code, rec.Body.String())
	}
	if err := <-voxDone; err != nil {
		t.Fatalf("the render was disturbed: %v", err)
	}
	t.Setenv("OXSAY_FAKE_VOX_DELAY_MS", "")
	if err := fastSpeak(t, d); err != nil {
		t.Fatalf("fast voice after the render finished: %v", err)
	}
	if alive(voxPid) {
		t.Fatal("the studio voice stayed resident after the fast voice took its turn")
	}
}

// usesInFlight is the arbiter's count of requests using a large engine.
func (d *Daemon) usesInFlight() int {
	d.mem.mu.Lock()
	defer d.mem.mu.Unlock()
	return d.mem.n
}

// With enough memory (or no assumption and a known 48 GB) nothing is evicted: both voices stay resident, and /status
// says so.
// Mutation (c): config.go OneLargeEngine, flip `mem < OneLargeEngineBelowGB*bytesPerGB` to `>` -> the 48 GB Mac
// evicts (and the 16 GB assumption does not) -> RED here and in TestSmallMemoryStatusReportsTheMode.
func TestLargeMemoryKeepsBothVoicesResident(t *testing.T) {
	d := smallMemDaemon(t, 0)
	if d.mem != nil {
		t.Fatal("a 48 GB Mac built a residency")
	}
	if err := fastSpeak(t, d); err != nil {
		t.Fatal(err)
	}
	fastPid := d.Sup.Status().PID
	if err := voxSpeak(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	if !alive(fastPid) {
		t.Fatal("a 48 GB Mac stopped the fast voice for the studio voice")
	}
	if got := d.Status().MemoryMode; got != memoryModeShared {
		t.Fatalf("memory_mode = %q, want %q", got, memoryModeShared)
	}
}

// /status names the mode.
func TestSmallMemoryStatusReportsTheMode(t *testing.T) {
	d := smallMemDaemon(t, 16)
	if got := d.Status().MemoryMode; got != memoryModeOneLarge {
		t.Fatalf("memory_mode = %q, want %q", got, memoryModeOneLarge)
	}
	mux := http.NewServeMux()
	d.Routes(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/status", nil))
	if !strings.Contains(rec.Body.String(), `"memory_mode":"one_large_engine"`) {
		t.Fatalf("/status lacks memory_mode: %s", bodyText(rec))
	}
}

// STT is never part of the turns: the arbiter does not manage it, and entering for it is a no-op that neither waits
// nor stops anything - even while a large engine is in use.
// Mutation (d): residency.go newResidency call in service.go, add d.STTSup to the engine list -> entering for STT while
// the fast voice is in use blocks (and a studio-voice start stops STT) -> RED.
func TestSmallMemoryNeverEvictsSTT(t *testing.T) {
	d := smallMemDaemon(t, 16)
	if d.mem.managed(d.STTSup) {
		t.Fatal("STT is managed by the residency: dictation and meeting recordings would be evicted")
	}
	if _, err := d.STTSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	sttPid := d.STTSup.Status().PID
	leave, err := d.mem.enter(context.Background(), d.Sup, 0) // the fast voice is "in use"
	if err != nil {
		t.Fatal(err)
	}
	defer leave()
	done := make(chan error, 1)
	go func() {
		l, err := d.mem.enter(context.Background(), d.STTSup, time.Second)
		if err == nil {
			l()
		}
		done <- err
	}()
	if err := within(t, "STT entering during a large engine's turn", 3*time.Second, done); err != nil {
		t.Fatal(err)
	}
	if err := voxSpeakBounded(d); err == nil {
		t.Fatal("setup: the studio voice should be waiting for the fast voice's turn")
	}
	if st := d.STTSup.Status(); st.PID != sttPid || !alive(sttPid) {
		t.Fatalf("STT was stopped: pid %d (was %d)", st.PID, sttPid)
	}
}

func voxSpeakBounded(d *Daemon) error {
	old := engineTurnBudget
	engineTurnBudget = 200 * time.Millisecond
	defer func() { engineTurnBudget = old }()
	return voxSpeak(context.Background(), d)
}

// A busy answer must not leave the arbiter claimed: after a request gave up, the next one still gets its turn.
func TestSmallMemoryGivingUpReleasesTheTurn(t *testing.T) {
	d := smallMemDaemon(t, 16)
	leave, err := d.mem.enter(context.Background(), d.Sup, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := voxSpeakBounded(d); err == nil {
		t.Fatal("the studio voice got a turn while the fast voice held it")
	}
	leave()
	if err := voxSpeak(context.Background(), d); err != nil {
		t.Fatalf("studio voice after the fast voice left: %v", err)
	}
	if n := d.usesInFlight(); n != 0 {
		t.Fatalf("%d uses still counted after every request ended", n)
	}
}

// A failed stop of the other engine (it is busy beyond the wait) refuses the start: the new engine must not load next
// to a resident one.
// Mutation: residency.go take, replace `r.settled = true` branch so a failed evictOthers still settles -> the studio
// voice starts beside the fast voice -> RED.
func TestSmallMemoryRefusesToStartWhenTheOtherEngineCannotStop(t *testing.T) {
	d := smallMemDaemon(t, 16)
	if err := fastSpeak(t, d); err != nil {
		t.Fatal(err)
	}
	g := d.Sup.Acquire() // a request the arbiter does not know of keeps the fast voice busy
	defer g.Release()
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	err := voxSpeak(ctx, d)
	if err == nil {
		t.Fatal("the studio voice started beside a resident fast voice")
	}
	if d.VoxSup.State() != engine.StateStopped {
		t.Fatalf("studio voice state = %s, want stopped", d.VoxSup.State())
	}
	if n := d.usesInFlight(); n != 0 {
		t.Fatalf("a failed claim left %d uses counted", n)
	}
}
