package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

func TestMain(m *testing.M) {
	testutil.FakeChildMain()
	os.Exit(m.Run())
}

// testLogWriter mirrors daemon log lines into the test's own output
// (t.Output) and keeps every line for assertions via testLogSaw. A daemon
// goroutine that logs after the test's cleanups have run would panic
// inside t.Output, so the cleanup flips closed and late writes are
// dropped; mu makes the closed check and the write atomic.
type testLogWriter struct {
	out    io.Writer
	mu     sync.Mutex
	closed bool
	lines  []string
}

func (w *testLogWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return len(p), nil
	}
	w.lines = append(w.lines, string(p))
	return w.out.Write(p)
}

// testLogs maps a test to the writer behind its daemon logger, so a test
// can assert on lines the daemon produced (testLogSaw).
var testLogs sync.Map // *testing.T → *testLogWriter

// testLogger routes the daemon's logs into the test's own output instead
// of discarding them: a failing or flaky test then shows what the daemon
// did. The cleanup is registered before the daemon's Shutdown cleanup and
// so runs after it — shutdown logging still reaches the test, while a
// stray goroutine logging after the test completed is dropped.
// A test that builds several daemons (TestDaemonHomeLock) calls this once
// per daemon on the same t: repeat calls reuse the first writer — a fresh
// one would evict the earlier testLogs entry, and its earlier cleanup
// would then delete the new entry mid-test.
func testLogger(t *testing.T) *slog.Logger {
	t.Helper()
	if v, ok := testLogs.Load(t); ok {
		return slog.New(slog.NewTextHandler(v.(*testLogWriter), nil))
	}
	w := &testLogWriter{out: t.Output()}
	testLogs.Store(t, w)
	t.Cleanup(func() {
		w.mu.Lock()
		w.closed = true
		w.mu.Unlock()
		testLogs.Delete(t)
	})
	return slog.New(slog.NewTextHandler(w, nil))
}

// testLogSaw reports whether a daemon log line containing sub reached the
// test's log through testLogger.
func testLogSaw(t *testing.T, sub string) bool {
	t.Helper()
	v, ok := testLogs.Load(t)
	if !ok {
		t.Fatal("testLogSaw: this test built no daemon logger")
	}
	w := v.(*testLogWriter)
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, l := range w.lines {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

// testCfg is the shared daemon test config. The STT server is ON — mirroring
// the production default — with the test binary as the fake ox-stt; tests
// asserting the per-call CLI path switch it off in sttSetup.
func testCfg(t *testing.T, dir string) *config.Config {
	t.Helper()
	return &config.Config{
		Home:           filepath.Join(dir, "home"),
		Addr:           "127.0.0.1:0",
		EnginePort:     testutil.FreePort(t),
		EngineBin:      os.Args[0],
		Model:          "talker.gguf",
		Codec:          "codec.gguf",
		MaxBatch:       1,
		StartupTimeout: 15 * time.Second,
		EngineLogDir:   filepath.Join(dir, "logs"),
		CacheDir:       filepath.Join(dir, "cache"),
		STTServer:      "on",
		STTBin:         os.Args[0],
		STTModel:       filepath.Join(dir, "parakeet.bin"),
		STTPort:        testutil.FreePort(t),
		STTGPU:         "auto",
	}
}

// newTestDaemon builds a Daemon whose engine binary is the test binary
// re-exec'd as the fake child.
func newTestDaemon(t *testing.T, dir string, tune func(*engine.Config)) *Daemon {
	t.Helper()
	return newTestDaemonSTT(t, dir, nil, tune, nil)
}

// newTestDaemonSTT is newTestDaemon plus two seams the resident STT server
// tests need: editCfg adjusts the config before newDaemon consumes it (e.g.
// STTIdleStop), and tuneSTT tunes the STT supervisor's engine.Config.
func newTestDaemonSTT(t *testing.T, dir string, editCfg func(*config.Config), tune, tuneSTT func(*engine.Config)) *Daemon {
	t.Helper()
	cfg := testCfg(t, dir)
	if editCfg != nil {
		editCfg(cfg)
	}
	fast := func(ec *engine.Config) {
		ec.HealthPoll = 10 * time.Millisecond
		ec.KillGrace = 2 * time.Second
	}
	d, err := newDaemon(cfg, testLogger(t),
		func(ec *engine.Config) {
			fast(ec)
			if tune != nil {
				tune(ec)
			}
		},
		func(ec *engine.Config) {
			fast(ec)
			if tuneSTT != nil {
				tuneSTT(ec)
			}
		})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(d.Shutdown)
	return d
}

func fakeEnv(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("OXSAY_FAKE_CHILD", "1")
	t.Setenv("OXSAY_FAKE_DIR", dir)
}

// childVoices returns name → ref_text for every voice the child lists.
func childVoices(t *testing.T, base string) map[string]string {
	t.Helper()
	resp, err := http.Get(base + "/v1/audio/voices")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out struct {
		Voices []struct {
			Name    string `json:"name"`
			RefText string `json:"ref_text"`
		} `json:"voices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	m := map[string]string{}
	for _, v := range out.Voices {
		m[v.Name] = v.RefText
	}
	return m
}

// T5 — voices survive an engine restart: store.Add + idle stop + EnsureReady
// must replay the persisted voice into the NEW child process.
// Mutation: delete the Replay call from the start path -> RED.
func TestVoicesSurviveRestart(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, func(ec *engine.Config) {
		ec.IdleStop = time.Second
		ec.IdleTick = 20 * time.Millisecond
	})

	// Keep the first child up while the voice is added: the add guards the
	// engine across normalization itself (issue #29), but the gap between
	// EnsureReady returning and AddVoice taking that guard is unguarded —
	// on a loaded runner (-race) the 1 s idle window could lapse in between.
	first := d.Sup.Acquire()
	base, err := d.Sup.EnsureReady(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	src := testutil.WriteTinyWAV(t, dir, "clip.wav")
	if _, registered, err := d.AddVoice(context.Background(), "ben", src, "hello there clip"); err != nil {
		t.Fatal(err)
	} else if !registered {
		t.Fatal("voice was not registered into the running engine")
	}
	if rt, ok := childVoices(t, base)["ben"]; !ok || rt != "hello there clip" {
		t.Fatalf("first child lists ben with ref_text %q (present=%v), want recorded", rt, ok)
	}
	first.Release()

	// Idle loop stops the child.
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return d.Sup.State() == engine.StateStopped
	}, "idle stop")

	// Restart: the replay inside the start path must re-register ben with
	// its ref_text.
	base2, err := d.Sup.EnsureReady(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if rt, ok := childVoices(t, base2)["ben"]; !ok {
		t.Fatal("restarted child does not list ben — voices were not replayed")
	} else if rt != "hello there clip" {
		t.Fatalf("replayed ref_text = %q, want recorded", rt)
	}
	resp, err := http.Post(base2+"/v1/audio/speech", "application/json",
		strings.NewReader(`{"input":"hi","voice":"ben"}`))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("speech with replayed voice: %s: %s", resp.Status, body)
	}
}

// A slow Prepare must not let the idle stop win: AddVoice holds the engine
// guard across normalization, so the child survives while Prepare is open
// and the live registration lands. Without it the idle loop stops the
// child mid-Prepare — the API returns registered=false for a voice the
// next start's replay would register, or LiveURL hands out a child already
// marked Stopped and a spurious "registration failed" warning is logged.
// Mutation: move d.Sup.Acquire() back after Store.Prepare in AddVoice ->
// RED (the idle stop fires while Prepare is blocked; registered=false).
func TestAddVoicePrepareHoldsGuard(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	const idleStop = 200 * time.Millisecond
	d := newTestDaemon(t, dir, func(ec *engine.Config) {
		ec.IdleStop = idleStop
		ec.IdleTick = 20 * time.Millisecond
	})

	src := testutil.WriteTinyWAV(t, dir, "clip.wav")
	// Pin the engine through startup so the armed idle window begins exactly
	// when Prepare does: the setup guard is released inside slowPrepare and
	// the add's own guard must then be the thing keeping the child up.
	hold := d.Sup.Acquire()
	base, err := d.Sup.EnsureReady(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	preparing := make(chan struct{})
	finish := make(chan struct{})
	d.slowPrepare = func() {
		close(preparing)
		hold.Release()
		<-finish
	}

	var registered bool
	addDone := make(chan error, 1)
	go func() {
		var err error
		_, registered, err = d.AddVoice(context.Background(), "ben", src, "ref words")
		addDone <- err
	}()
	<-preparing

	// Prepare is open: let several idle ticks pass the deadline. The add's
	// guard must keep the child alive through all of them.
	time.Sleep(3 * idleStop)
	if st := d.Sup.State(); st != engine.StateReady {
		t.Errorf("mid-prepare engine state = %s, want ready — the idle stop fired under the guard", st)
	}
	close(finish)

	if err := <-addDone; err != nil {
		t.Fatalf("AddVoice: %v", err)
	}
	if !registered {
		t.Fatal("registered=false — the idle stop won while Prepare ran")
	}
	if rt, ok := childVoices(t, base)["ben"]; !ok || rt != "ref words" {
		t.Fatalf("child lists ben %q (present %v), want the live registration", rt, ok)
	}
	if testLogSaw(t, "registration failed") {
		t.Fatal("a 'registration failed' warning was logged for a voice that registered cleanly")
	}

	// The guard is released on Prepare's error paths too (a failing ffmpeg,
	// a ctx cancelled mid-Prepare): a failed add leaves no guard behind, so
	// the idle stop still fires afterwards.
	d.slowPrepare = nil
	if _, _, err := d.AddVoice(context.Background(), "bad", filepath.Join(dir, "missing.wav"), ""); err == nil {
		t.Fatal("add of a missing clip succeeded")
	}
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return d.Sup.State() == engine.StateStopped
	}, "idle stop after a failed AddVoice")
}

// A request Store.Prepare would refuse — bad name, relative path, missing
// clip — must fail BEFORE the engine guard is taken: Acquire/Release
// re-stamps the supervisor's lastActivity, so rejected adds inside the
// guard would keep pushing a Ready engine's idle stop back (issue #70).
// The add loop spans several idle windows; with validation up front none
// of the calls touches lastActivity and the child still stops on time.
// Mutation: move d.Sup.Acquire() back above the ValidateInput call in
// AddVoice -> RED (every rejected add re-arms the idle window and the
// engine is still Ready when the loop ends).
func TestAddVoiceRejectedKeepsIdleClock(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	const idleStop = 300 * time.Millisecond
	d := newTestDaemon(t, dir, func(ec *engine.Config) {
		ec.IdleStop = idleStop
		ec.IdleTick = 20 * time.Millisecond
	})
	if _, err := d.Sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	src := testutil.WriteTinyWAV(t, dir, "clip.wav")

	// Failing adds spanning 3x the idle deadline — no sleeps: the loop
	// condition is wall-clock, so under the mutation each Release keeps
	// the engine alive for the whole span.
	for stop := time.Now().Add(3 * idleStop); time.Now().Before(stop); {
		if _, _, err := d.AddVoice(context.Background(), "BAD NAME", src, ""); err == nil {
			t.Fatal("AddVoice with an invalid name succeeded")
		}
	}
	if st := d.Sup.State(); st != engine.StateStopped {
		t.Fatalf("state = %s after an idle-span of rejected adds, want stopped — a failed add refreshed lastActivity", st)
	}
}

// T7 — speak out_path rules: relative, missing parent, wrong extension and
// existing-without-overwrite are refused BEFORE the engine is touched.
// Mutation: skip the existing-file check in validateOutPath -> RED (the
// engine gets started and the state assertion fails).
func TestSpeakOutPathRules(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)

	existing := filepath.Join(dir, "out.wav")
	if err := os.WriteFile(existing, []byte("keepme"), 0o644); err != nil {
		t.Fatal(err)
	}
	cases := map[string]SpeakInput{
		"relative path":   {Text: "hi", Format: "wav", OutPath: "rel/out.wav"},
		"bare filename":   {Text: "hi", Format: "wav", OutPath: "out.wav"},
		"missing parent":  {Text: "hi", Format: "wav", OutPath: filepath.Join(dir, "nope", "o.wav")},
		"wrong extension": {Text: "hi", Format: "mp3", OutPath: filepath.Join(dir, "o.wav")},
		"existing file":   {Text: "hi", Format: "wav", OutPath: existing},
	}
	for name, in := range cases {
		if _, err := d.Speak(context.Background(), in); err == nil {
			t.Fatalf("%s: expected refusal, got nil error", name)
		}
		if d.Sup.State() != engine.StateStopped {
			t.Fatalf("%s: engine was started for a refused out_path (state %s)", name, d.Sup.State())
		}
	}
	if data, _ := os.ReadFile(existing); string(data) != "keepme" {
		t.Fatal("existing file was overwritten without overwrite")
	}
}

// Speak happy path: default output lands in the cache dir, an mp3 out_path
// is transcoded through ffmpeg, and overwrite requires the flag.
func TestSpeakHappyPath(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)

	res, err := d.Speak(context.Background(), SpeakInput{Text: "hello world"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Format != "wav" || res.DurationS <= 0 {
		t.Fatalf("result = %+v", res)
	}
	if filepath.Dir(res.Path) != d.Cfg.CacheDir {
		t.Fatalf("default out not in cache dir: %s", res.Path)
	}
	data, err := os.ReadFile(res.Path)
	if err != nil || string(data[:4]) != "RIFF" {
		t.Fatalf("not a wav: %v", err)
	}

	mp3 := filepath.Join(dir, "out.mp3")
	res2, err := d.Speak(context.Background(), SpeakInput{Text: "hello", Format: "mp3", OutPath: mp3})
	if err != nil {
		t.Fatal(err)
	}
	data, err = os.ReadFile(mp3)
	if err != nil || len(data) == 0 || string(data[:4]) == "RIFF" {
		t.Fatalf("mp3 not transcoded: %v", err)
	}
	if res2.Format != "mp3" {
		t.Fatalf("format = %q", res2.Format)
	}

	// Overwrite requires the flag.
	if _, err := d.Speak(context.Background(), SpeakInput{Text: "x", Format: "wav", OutPath: filepath.Join(dir, "dup.wav")}); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Speak(context.Background(), SpeakInput{Text: "x", Format: "wav", OutPath: filepath.Join(dir, "dup.wav"), Overwrite: true}); err != nil {
		t.Fatalf("overwrite=true should succeed: %v", err)
	}
}

// OX_SAY_VOICE fills the voice field when a request leaves it unset; an
// explicit name wins; "default" asks for the engine's random voice and is
// stripped before the request reaches it. Asserted on the stamp the fake
// child writes per speech request — the wire body, not the intent.
// Mutation: drop the applyVoiceDefault call in SynthesizeWAV or
// handleSpeech -> RED (the stamp shows no injected voice).
func TestSpeakVoiceDefault(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, func(c *config.Config) { c.Voice = "vtest" }, nil, nil)

	lastVoice := func() (string, bool) {
		t.Helper()
		data, err := os.ReadFile(filepath.Join(dir, "speech-last.json"))
		if err != nil {
			t.Fatal(err)
		}
		var body map[string]any
		if err := json.Unmarshal(data, &body); err != nil {
			t.Fatal(err)
		}
		v, ok := body["voice"].(string)
		return v, ok
	}

	g := d.Sup.Acquire()
	if _, err := d.Sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	src := testutil.WriteTinyWAV(t, dir, "clip.wav")
	if _, registered, err := d.AddVoice(context.Background(), "vtest", src, "ref"); err != nil || !registered {
		t.Fatalf("register vtest: registered=%v err=%v", registered, err)
	}
	g.Release()

	res, err := d.Speak(context.Background(), SpeakInput{Text: "hi"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Voice != "vtest" {
		t.Fatalf("reported voice = %q, want vtest", res.Voice)
	}
	if v, ok := lastVoice(); !ok || v != "vtest" {
		t.Fatalf("unset voice reached the engine as %q (present=%v), want vtest", v, ok)
	}

	// An explicit name wins — even one the engine does not know: the 400
	// proves "other" travelled upstream, not the configured default.
	if _, err := d.Speak(context.Background(), SpeakInput{Text: "hi explicit", Voice: "other"}); err == nil {
		t.Fatal("explicit unknown voice should surface the engine's error")
	}
	if v, _ := lastVoice(); v != "other" {
		t.Fatalf("explicit voice reached the engine as %q, want other", v)
	}

	// "default" is the engine's random voice: the field must not reach it.
	if _, err := d.Speak(context.Background(), SpeakInput{Text: "hi default", Voice: "default"}); err != nil {
		t.Fatal(err)
	}
	if v, ok := lastVoice(); ok {
		t.Fatalf(`"default" reached the engine as %q — want the field stripped`, v)
	}

	// The /v1/audio/speech route resolves voice the same way.
	mux := http.NewServeMux()
	d.Routes(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/v1/audio/speech", "application/json",
		strings.NewReader(`{"input":"hi"}`))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("route speak: %s", resp.Status)
	}
	if v, ok := lastVoice(); !ok || v != "vtest" {
		t.Fatalf("route unset voice reached the engine as %q (present=%v), want vtest", v, ok)
	}

	resp, err = http.Post(srv.URL+"/v1/audio/speech", "application/json",
		strings.NewReader(`{"input":"hi","voice":"default"}`))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf(`route "default" speak: %s`, resp.Status)
	}
	if v, ok := lastVoice(); ok {
		t.Fatalf(`route "default" reached the engine as %q — want the field stripped`, v)
	}
}

// T9 — client disconnect cancels the upstream request: the fake child blocks
// in its speech handler until the request context ends; after the client
// goes away the child must observe cancellation within 1s.
// Mutation: forward with context.Background() instead of r.Context() -> RED.
func TestSpeechClientCancelPropagates(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_SPEECH_BLOCK", "1")
	d := newTestDaemon(t, dir, nil)

	mux := http.NewServeMux()
	d.Routes(mux)
	// Deliberately not Close()d: a regression that drops request-context
	// propagation leaves the handler blocked forever and Close() would hang
	// the test instead of failing on the cancellation assertion.
	srv := httptest.NewServer(mux)

	ctx, cancel := context.WithCancel(context.Background())
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		srv.URL+"/v1/audio/speech", bytes.NewReader([]byte(`{"input":"hi"}`)))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	respCh := make(chan error, 1)
	go func() {
		resp, err := http.DefaultClient.Do(req)
		if err == nil {
			_ = resp.Body.Close()
		}
		respCh <- err
	}()

	// Wait until the child is inside its blocking handler, then drop the call.
	testutil.WaitFor(t, 10*time.Second, func() bool {
		_, err := os.Stat(filepath.Join(dir, "speech-started"))
		return err == nil
	}, "child speech handler to start")
	cancel()

	testutil.WaitFor(t, time.Second, func() bool {
		_, err := os.Stat(filepath.Join(dir, "speech-cancelled"))
		return err == nil
	}, "child to observe request cancellation")
}

// A relative audio_path must be refused: the daemon's cwd is "/" under
// launchd, so a relative path would resolve somewhere unexpected. The path
// given here exists — the refusal must come from the absolute-path rule,
// not from a missing file.
// Mutation: drop the filepath.IsAbs check in voices.Store.Add -> RED
// (ffmpeg happily normalises it and the route answers 200).
func TestAddVoiceRejectsRelativePath(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)

	src := testutil.WriteTinyWAV(t, dir, "clip.wav")
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	rel, err := filepath.Rel(wd, src)
	if err != nil || filepath.IsAbs(rel) {
		t.Fatalf("cannot form relative path to %s: %v", src, err)
	}

	mux := http.NewServeMux()
	d.Routes(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()
	body, _ := json.Marshal(map[string]any{"name": "ben", "audio_path": rel})
	resp, err := http.Post(srv.URL+"/v1/audio/voices", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		b, _ := io.ReadAll(resp.Body)
		t.Fatalf("relative audio_path: status %d, want 400 (body %s)", resp.StatusCode, b)
	}
	if _, err := d.Store.Get("ben"); err == nil {
		t.Fatal("voice was stored despite the rejected request")
	}

	// The MCP tool must refuse it too.
	if _, _, err := d.toolVoiceAdd(context.Background(), nil, voiceAddIn{
		Name: "ben", AudioPath: rel,
	}); err == nil {
		t.Fatal("voice_add accepted a relative audio_path")
	}
}

// Status codes are mapped by error TYPE: only *voices.InputError is a 400.
// A store write failure — an unwritable voices dir — is a 500, never a 400.
// Mutation: classify every AddVoice error as 400 (or by message substring)
// -> RED.
func TestAddVoiceStoreFailureIs500(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)

	if err := os.Chmod(d.Cfg.VoicesDir(), 0o555); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.Chmod(d.Cfg.VoicesDir(), 0o755) }()

	src := testutil.WriteTinyWAV(t, dir, "clip.wav")
	mux := http.NewServeMux()
	d.Routes(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()
	body, _ := json.Marshal(map[string]any{"name": "ben", "audio_path": src})
	resp, err := http.Post(srv.URL+"/v1/audio/voices", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusInternalServerError {
		b, _ := io.ReadAll(resp.Body)
		t.Fatalf("store write failure: status %d, want 500 (body %s)", resp.StatusCode, b)
	}
}

// A voice added while the engine is mid-start must still reach the live
// child: a replay whose store snapshot predates the add cannot carry it,
// so AddVoice itself must deliver it to the still-starting engine.
// Mutation: revert LiveURL to ReadyURL in AddVoice -> RED (the register is
// skipped because the engine is not Ready yet).
func TestVoiceAddDuringStartup(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	src := testutil.WriteTinyWAV(t, dir, "clip.wav")

	var d *Daemon
	addDone := make(chan error, 1)
	d = newTestDaemon(t, dir, func(ec *engine.Config) {
		ec.Replay = func(ctx context.Context, base string) error {
			// Snapshot the store exactly as a racing replay would, let the
			// concurrent add land fully, then register only the snapshot —
			// the new voice can reach the child solely via AddVoice.
			list, err := d.Store.List()
			if err != nil {
				return err
			}
			go func() {
				_, _, err := d.AddVoice(ctx, "ben", src, "ref words")
				addDone <- err
			}()
			if err := <-addDone; err != nil {
				return err
			}
			for _, v := range list {
				if err := d.ec.RegisterVoice(ctx, base, v.Name, d.Store.WAVPath(v.Name), v.RefText); err != nil {
					return err
				}
			}
			return nil
		}
	})

	base, err := d.Sup.EnsureReady(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := childVoices(t, base)["ben"]; !ok {
		t.Fatal("voice added during engine startup did not reach the child")
	}
}

// A voice removed while replay is mid-flight must not survive into the
// live child: RemoveVoice parks on voiceMu until the replay finishes, then
// deletes from the child too — no ghost voice left registered.
// Mutation: drop the voiceMu lock from RemoveVoice -> RED (the remove runs
// during the replay's hold and the stale register lands after the delete).
func TestVoiceRemoveDuringReplay(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	src := testutil.WriteTinyWAV(t, dir, "clip.wav")

	var d *Daemon
	removeDone := make(chan error, 1)
	d = newTestDaemon(t, dir, func(ec *engine.Config) {
		ec.Replay = func(ctx context.Context, base string) error {
			// Mirror production replayVoices: hold voiceMu across the whole
			// snapshot+register sequence.
			d.voiceMu.Lock()
			defer d.voiceMu.Unlock()
			list, err := d.Store.List()
			if err != nil {
				return err
			}
			// Materialize each clip into a detached path NOW — part of the
			// snapshot. Registering the store path later would just fail on
			// the deleted file instead of leaving the ghost voice this test
			// is hunting.
			type snap struct{ name, ref, wav string }
			var snaps []snap
			for _, v := range list {
				data, err := os.ReadFile(d.Store.WAVPath(v.Name))
				if err != nil {
					return err
				}
				p := filepath.Join(dir, "snap-"+v.Name+".wav")
				if err := os.WriteFile(p, data, 0o644); err != nil {
					return err
				}
				snaps = append(snaps, snap{v.Name, v.RefText, p})
			}
			go func() {
				// An independent request ctx — NOT the start-attempt ctx,
				// which run() cancels when the attempt concludes.
				removeDone <- d.RemoveVoice(context.Background(), "ben")
			}()
			// Give the remove time to reach voiceMu (and park there under
			// the lock / run through without it).
			time.Sleep(150 * time.Millisecond)
			for _, v := range snaps {
				if err := d.ec.RegisterVoice(ctx, base, v.name, v.wav, v.ref); err != nil {
					return err
				}
			}
			return nil
		}
	})

	// Persist the voice before the engine ever starts — replay will
	// snapshot it, and the concurrent remove must still win in the child.
	if _, _, err := d.AddVoice(context.Background(), "ben", src, "ref words"); err != nil {
		t.Fatal(err)
	}
	base, err := d.Sup.EnsureReady(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := <-removeDone; err != nil {
		t.Fatalf("RemoveVoice: %v", err)
	}
	if _, ok := childVoices(t, base)["ben"]; ok {
		t.Fatal("voice removed during replay is still live in the child")
	}
}

// Two daemons on one home must not coexist: the second fails fast on the
// home lock instead of reaping the first one's engine.
func TestDaemonHomeLock(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	home := filepath.Join(dir, "home")
	mkCfg := func() *config.Config {
		return &config.Config{
			Home:           home,
			Addr:           "127.0.0.1:0",
			EnginePort:     testutil.FreePort(t),
			EngineBin:      os.Args[0],
			Model:          "talker.gguf",
			Codec:          "codec.gguf",
			MaxBatch:       1,
			StartupTimeout: 15 * time.Second,
			EngineLogDir:   filepath.Join(dir, "logs"),
			CacheDir:       filepath.Join(dir, "cache"),
		}
	}

	d1, err := newDaemon(mkCfg(), testLogger(t), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if d2, err := newDaemon(mkCfg(), testLogger(t), nil, nil); err == nil {
		d2.Shutdown()
		t.Fatal("second daemon on the same home started successfully")
	} else if !strings.Contains(err.Error(), "another daemon") {
		t.Fatalf("second daemon error = %v, want a held-lock message", err)
	}
	d1.Shutdown()
	// The lock is released on shutdown — a later daemon can take it.
	d3, err := newDaemon(mkCfg(), testLogger(t), nil, nil)
	if err != nil {
		t.Fatalf("daemon after lock release: %v", err)
	}
	d3.Shutdown()
}

// Speak counts CHARACTERS, not bytes: 3000 Russian (multi-byte) chars must
// be accepted while 5001 chars are refused before the engine is touched —
// same cap at the HTTP route.
func TestSpeakInputCaps(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)

	if _, err := d.Speak(context.Background(), SpeakInput{Text: strings.Repeat("ж", 3000)}); err != nil {
		t.Fatalf("3000 Russian chars rejected: %v", err)
	}
	if _, err := d.Speak(context.Background(), SpeakInput{Text: strings.Repeat("a", 5001)}); err == nil {
		t.Fatal("5001 chars accepted")
	}

	mux := http.NewServeMux()
	d.Routes(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()
	body, _ := json.Marshal(map[string]any{"input": strings.Repeat("a", 5001)})
	resp, err := http.Post(srv.URL+"/v1/audio/speech", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("oversized input: status %d, want 400", resp.StatusCode)
	}
}

// readAllCap must fail rather than silently truncate an over-limit body.
func TestReadAllCap(t *testing.T) {
	b, err := readAllCap(strings.NewReader("0123456789abcdef"), 16)
	if err != nil || string(b) != "0123456789abcdef" {
		t.Fatalf("at-limit read: b=%q err=%v", b, err)
	}
	if _, err := readAllCap(strings.NewReader("0123456789abcdefg"), 16); err == nil {
		t.Fatal("over-limit read silently truncated")
	}
}

// overwrite=true must never follow a symlink at out_path.
// Mutation: drop the Lstat check in writeFile -> RED (the link target is
// clobbered).
func TestSpeakOverwriteRefusesSymlink(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)

	target := filepath.Join(dir, "target.wav")
	if err := os.WriteFile(target, []byte("keepme"), 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link.wav")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Speak(context.Background(), SpeakInput{
		Text: "hi", Format: "wav", OutPath: link, Overwrite: true,
	}); err == nil {
		t.Fatal("speak overwrote a symlink at out_path")
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "keepme" {
		t.Fatalf("symlink target clobbered: %v", err)
	}
}

// Engine-start replay holds voiceMu from its store snapshot to its last
// registration, so a concurrent add or remove waits for it instead of racing
// it (a remove interleaved there can leave a ghost voice in the child). This
// drives the real replayVoices through its test seam.
// Mutation: drop d.voiceMu.Lock()/defer d.voiceMu.Unlock() from replayVoices
// (internal/daemon/service.go) -> RED ("remove finished while replay held the
// voice lock").
func TestReplayHoldsVoiceLock(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	src := testutil.WriteTinyWAV(t, dir, "clip.wav")
	d := newTestDaemon(t, dir, nil)
	if _, _, err := d.AddVoice(context.Background(), "old", src, ""); err != nil {
		t.Fatal(err)
	}

	addDone, rmDone := make(chan error, 1), make(chan error, 1)
	var addEarly, rmEarly atomic.Bool
	d.replayAfterSnapshot = func() {
		go func() {
			_, _, err := d.AddVoice(context.Background(), "new", src, "")
			addDone <- err
		}()
		go func() { rmDone <- d.RemoveVoice(context.Background(), "old") }()
		time.Sleep(200 * time.Millisecond)
		addEarly.Store(len(addDone) > 0)
		rmEarly.Store(len(rmDone) > 0)
	}

	base, err := d.Sup.EnsureReady(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if rmEarly.Load() {
		t.Fatal("remove finished while replay held the voice lock")
	}
	if addEarly.Load() {
		t.Fatal("add finished while replay held the voice lock")
	}
	for _, ch := range []chan error{addDone, rmDone} {
		select {
		case err := <-ch:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("add/remove did not finish after replay released the lock")
		}
	}
	got := childVoices(t, base)
	if _, ok := got["old"]; ok {
		t.Fatal("removed voice is still live in the child")
	}
	if _, ok := got["new"]; !ok {
		t.Fatal("voice added during replay did not reach the child")
	}
}
