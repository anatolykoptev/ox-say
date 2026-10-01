package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// sttLogLines is the fake ox-stt record log split into lines; missing file → nil.
func sttLogLines(t *testing.T, log string) []string {
	t.Helper()
	data, err := os.ReadFile(log)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(data)), "\n")
}

// linesWith returns the log lines carrying the given record prefix.
func linesWith(lines []string, prefix string) []string {
	var out []string
	for _, l := range lines {
		if strings.HasPrefix(l, prefix) {
			out = append(out, l)
		}
	}
	return out
}

// lastServeArgv parses the newest "serve\t<pid>\t<arg>…" record into argv fields.
func lastServeArgv(t *testing.T, log string) []string {
	t.Helper()
	var last []string
	for _, l := range linesWith(sttLogLines(t, log), "serve\t") {
		f := strings.Split(strings.TrimPrefix(l, "serve\t"), "\t")
		last = f[1:] // [0] is the pid
	}
	if last == nil {
		t.Fatalf("no serve line in %s", log)
	}
	return last
}

// warnLog is a slog handler recording Warn+ messages for assertions — the
// daemon's OnServerError surfaces only through its logger.
type warnLog struct {
	mu   sync.Mutex
	msgs []string
}

func (h *warnLog) Enabled(context.Context, slog.Level) bool { return true }

func (h *warnLog) Handle(_ context.Context, r slog.Record) error {
	if r.Level >= slog.LevelWarn {
		h.mu.Lock()
		h.msgs = append(h.msgs, r.Message)
		h.mu.Unlock()
	}
	return nil
}

func (h *warnLog) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h *warnLog) WithGroup(string) slog.Handler      { return h }

func (h *warnLog) saw(sub string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, m := range h.msgs {
		if strings.Contains(m, sub) {
			return true
		}
	}
	return false
}

// A parakeet transcription goes to the resident `ox-stt --serve` child: the
// fake records a "req" line carrying Content-Type audio/wav (httplib would
// 413 a form body) and the per-call CLI fake never runs.
// Mutation: make the server-branch condition in stt.Transcribe false ->
// RED (no req line, an argv line appears).
func TestTranscribeUsesServer(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	log := sttSetupServer(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	res, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src})
	if err != nil {
		t.Fatal(err)
	}
	if res.Text != "hello world." {
		t.Fatalf("text = %q", res.Text)
	}
	lines := sttLogLines(t, log)
	reqs := linesWith(lines, "req ")
	if len(reqs) != 1 || !strings.Contains(reqs[0], "audio/wav") {
		t.Fatalf("req lines = %v, want one with audio/wav", reqs)
	}
	if n := len(linesWith(lines, "argv\t")); n != 0 {
		t.Fatalf("CLI ox-stt ran %d times despite the server", n)
	}
}

// The server is CPU-only by default, so TTS readiness does not route a
// transcription back to the CLI.
// Mutation: add `&& !engineBusy(opts.EngineBusy)` to the server-branch
// condition in stt.Transcribe -> RED (the CLI fake runs).
func TestServerUsedWhileTTSReady(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	log := sttSetupServer(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	if _, err := d.Sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	// Pin the engine in Ready for the whole transcription.
	g := d.Sup.Acquire()
	defer g.Release()
	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	if d.Sup.State() != engine.StateReady {
		t.Fatalf("TTS state = %s, want ready", d.Sup.State())
	}
	lines := sttLogLines(t, log)
	if n := len(linesWith(lines, "req ")); n != 1 {
		t.Fatalf("server req lines = %d, want 1 (CLI must not run while TTS is ready)", n)
	}
	if n := len(linesWith(lines, "argv\t")); n != 0 {
		t.Fatalf("CLI ox-stt ran %d times while TTS was ready", n)
	}
}

// The resident server is spawned with -ng by default (CPU — the GPU stays
// with TTS); OX_SAY_STT_GPU=on drops the flag, opting into GPU sharing.
// Mutation: drop the `-ng` append in the Args func in newDaemon -> RED
// (the default-config serve argv loses -ng).
func TestSTTServerArgs(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	log := sttSetupServer(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")
	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	argv := lastServeArgv(t, log)
	for _, want := range []string{"--serve", "--port", "-m", "-ng"} {
		if !argvHas(argv, want) {
			t.Fatalf("default serve argv %v missing %q", argv, want)
		}
	}

	dir2 := t.TempDir()
	d2 := newTestDaemonSTT(t, dir2, nil, nil, nil)
	log2 := sttSetupServer(t, d2, dir2)
	// The Args closure reads cfg.STTGPU at spawn time, so flipping it here —
	// after setup, before the first transcription — is what the flag does.
	d2.Cfg.STTGPU = "on"
	src2 := testutil.WriteTinyWAV(t, dir2, "in.wav")
	if _, err := d2.Transcribe(context.Background(), TranscribeInput{AudioPath: src2}); err != nil {
		t.Fatal(err)
	}
	argv = lastServeArgv(t, log2)
	if argvHas(argv, "-ng") {
		t.Fatalf("OX_SAY_STT_GPU=on serve argv %v still carries -ng", argv)
	}
	for _, want := range []string{"--serve", "--port", "-m"} {
		if !argvHas(argv, want) {
			t.Fatalf("GPU=on serve argv %v missing %q", argv, want)
		}
	}
}

// A server failure is a fallback, not a user-visible error: the request is
// retried on the per-call CLI and OnServerError reports it.
// Mutation: return the server error instead of falling back to the CLI in
// stt.Transcribe -> RED (Transcribe fails).
func TestServerFailureFallsBackToCLI(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_STT_SERVE_STATUS", "500")
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	log := sttSetupServer(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	rec := &warnLog{}
	d.log = slog.New(rec)
	res, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src})
	if err != nil {
		t.Fatal(err)
	}
	if res.Text != "hello world." {
		t.Fatalf("text = %q — want the CLI fake's canned result", res.Text)
	}
	lines := sttLogLines(t, log)
	if n := len(linesWith(lines, "req ")); n != 1 {
		t.Fatalf("server req lines = %d, want 1", n)
	}
	if n := len(linesWith(lines, "argv\t")); n != 1 {
		t.Fatalf("CLI runs = %d, want 1 (fallback)", n)
	}
	if !rec.saw("stt server failed") {
		t.Fatalf("OnServerError never fired; warnings = %v", rec.msgs)
	}
}

// A cancelled request must not retry on the CLI: the server keeps decoding
// (a cancelled server decode is not killed), so the caller's ctx error is
// the whole answer.
// Mutation: fall back to the CLI on every server error in stt.Transcribe ->
// RED (an argv line appears / the error is not the ctx error).
func TestCancelledServerRequestDoesNotFallBack(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_STT_SERVE_DELAY_MS", "30000")
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	log := sttSetupServer(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	rec := &warnLog{}
	d.log = slog.New(rec)
	go func() {
		_, err := d.Transcribe(ctx, TranscribeInput{AudioPath: src})
		done <- err
	}()
	testutil.WaitFor(t, 10*time.Second, func() bool {
		return len(linesWith(sttLogLines(t, log), "req ")) == 1
	}, "server request to land")
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Transcribe err = %v, want context.Canceled", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Transcribe did not return after cancel")
	}
	// Deterministic half of "no fallback": a caller-cancelled server request
	// is not a server failure, so OnServerError must not fire. (The argv
	// check below is the other half; it races the CLI child's kill.)
	if rec.saw("stt server failed") {
		t.Fatal("OnServerError fired for a caller-cancelled request — a fallback ran")
	}
	if n := len(linesWith(sttLogLines(t, log), "argv\t")); n != 0 {
		t.Fatalf("CLI ox-stt ran %d times after cancellation", n)
	}
}

// The STT supervisor's IdleStop is wired from OX_SAY_STT_IDLE_STOP_SECS: an
// idle server stops itself.
// Mutation: omit `IdleStop: cfg.STTIdleStop` from the STT supervisor's
// config literal in newDaemon -> RED (the server never stops).
func TestSTTIdleStopWired(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir,
		func(c *config.Config) { c.STTIdleStop = 300 * time.Millisecond },
		nil,
		func(ec *engine.Config) { ec.IdleTick = 20 * time.Millisecond })
	sttSetupServer(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	testutil.WaitFor(t, 10*time.Second, func() bool {
		return d.STTSup.State() == engine.StateStopped
	}, "STT server idle stop")
}

// A server that cannot start (port taken, ox-stt without --serve, a corrupt
// model) must not make every dictation sleep out the supervisor's crash
// backoff inside EnsureReady: a request inside the cool-down window takes
// the CLI fallback at once. The fake's --serve mode exits 1 on spawn; the
// per-call CLI still works.
// Mutation: delete the Backoff() check in sttServer -> RED (the in-window
// request sleeps out the remaining backoff and spawns another serve child).
func TestSTTServerBackoffFallsBackFast(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_STT_SERVE_EXIT", "1")
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	log := sttSetupServer(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	// Drive failed start ATTEMPTS, not requests: a request inside a window
	// falls back without an attempt and does not grow the backoff, so a
	// request-counted loop stalls in the first window on a fast machine.
	// Each window is waited out so every request launches a fresh (failing)
	// start; the windows double (1 s, 2 s, 4 s …), so within a few attempts
	// one still has ≥2 s left after the request that earned it, however long
	// a request takes. The in-window request below must finish inside that
	// window, so 2 s leaves a loaded runner room (#41). Every request falls
	// back to the CLI.
	var calls int
	deadline := time.Now().Add(60 * time.Second)
	for d.STTSup.Backoff() < 2*time.Second {
		if time.Now().After(deadline) {
			t.Fatalf("no backoff window of 2 s or more after %d failed serve starts", calls)
		}
		testutil.WaitFor(t, 40*time.Second, func() bool {
			return d.STTSup.Backoff() <= 0
		}, "backoff window to lapse before the next attempt")
		res, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src})
		if err != nil {
			t.Fatal(err)
		}
		if res.Text != "hello world." {
			t.Fatalf("text = %q — want the CLI fake's canned result", res.Text)
		}
		calls++
	}
	win := d.STTSup.Backoff()
	serves := len(linesWith(sttLogLines(t, log), "serve\t"))

	// Inside the window a request must go straight to the CLI: it pays no
	// cool-down sleep and spawns no new serve child.
	calls++
	start := time.Now()
	res, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src})
	if err != nil {
		t.Fatal(err)
	}
	if res.Text != "hello world." {
		t.Fatalf("text = %q — want the CLI fake's canned result", res.Text)
	}
	if el := time.Since(start); el >= win {
		t.Fatalf("transcription during server backoff took %s — it slept out the crash backoff (window %s)", el, win)
	}
	lines := sttLogLines(t, log)
	if n := len(linesWith(lines, "serve\t")); n != serves {
		t.Fatalf("serve spawns = %d, want %d (no start attempt inside the backoff window)", n, serves)
	}
	if n := len(linesWith(lines, "argv\t")); n != calls {
		t.Fatalf("CLI runs = %d, want %d (every request fell back)", n, calls)
	}

	// Recovery is automatic: the first request past the window launches a
	// new start attempt (this one fails too and falls back again).
	testutil.WaitFor(t, 40*time.Second, func() bool {
		return d.STTSup.Backoff() <= 0
	}, "backoff window to lapse")
	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	lines = sttLogLines(t, log)
	if n := len(linesWith(lines, "serve\t")); n != serves+1 {
		t.Fatalf("serve spawns after the backoff lapsed = %d, want %d", n, serves+1)
	}
}

// The STT server's start budget is capped at 90 s, below the TTS startup
// budget (180 s — sized for first-start Metal shader compile): an honest
// `ox-stt --serve` start is ~2–3 s, and even a cold start of a NEW ox-stt
// binary spends ~47 s compiling Metal libraries despite -ng (issue #37). A
// hung STT start must not pin a transcription for the TTS budget.
// Mutation: pass cfg.StartupTimeout uncapped in the STT engine.Config ->
// RED (sttGot = 300s).
func TestSTTStartupTimeoutCap(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	var ttsGot, sttGot time.Duration
	newTestDaemonSTT(t, dir,
		func(c *config.Config) { c.StartupTimeout = 300 * time.Second },
		func(ec *engine.Config) { ttsGot = ec.StartupTimeout },
		func(ec *engine.Config) { sttGot = ec.StartupTimeout })
	if ttsGot != 300*time.Second {
		t.Fatalf("TTS StartupTimeout = %s, want the configured 300s", ttsGot)
	}
	if sttGot != 90*time.Second {
		t.Fatalf("STT StartupTimeout = %s, want the 90s cap", sttGot)
	}
	// A smaller configured budget is honoured, not raised to the cap.
	if got := sttStartupTimeout(15 * time.Second); got != 15*time.Second {
		t.Fatalf("sttStartupTimeout(15s) = %s, want 15s", got)
	}
	// An unset or invalid budget must not fall through to engine.New's
	// 180 s default. Mutation: drop the d <= 0 branch -> RED.
	for _, d := range []time.Duration{0, -time.Second} {
		if got := sttStartupTimeout(d); got != 90*time.Second {
			t.Fatalf("sttStartupTimeout(%s) = %s, want the 90s cap", d, got)
		}
	}
}

// OX_SAY_STT_SERVER=off: no supervisor, the CLI path serves requests and
// /status reports the server as off.
func TestSTTServerOff(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, func(c *config.Config) { c.STTServer = "off" }, nil, nil)
	if d.STTSup != nil {
		t.Fatal("STTSup built with OX_SAY_STT_SERVER=off")
	}
	log := sttSetup(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	if n := len(linesWith(sttLogLines(t, log), "argv\t")); n != 1 {
		t.Fatalf("CLI runs = %d, want 1", n)
	}
	srv := transcriptionServer(t, d)
	resp, err := http.Get(srv.URL + "/status")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var st map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		t.Fatal(err)
	}
	ss, ok := st["stt_server"].(map[string]any)
	if !ok || ss["state"] != "off" {
		t.Fatalf("stt_server = %v, want state off", st["stt_server"])
	}
}

// /status gains a separate stt_server object — the engine key the dictation
// app parses keeps its shape.
func TestStatusSTTServer(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	sttSetupServer(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	srv := transcriptionServer(t, d)
	resp, err := http.Get(srv.URL + "/status")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var st map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		t.Fatal(err)
	}
	ss, ok := st["stt_server"].(map[string]any)
	if !ok || ss["state"] != "ready" {
		t.Fatalf("stt_server = %v, want state ready", st["stt_server"])
	}
	eng, ok := st["engine"].(map[string]any)
	if !ok {
		t.Fatalf("engine key missing or not an object: %v", st["engine"])
	}
	for k := range eng {
		switch k {
		case "state", "pid", "base_url", "uptime_s", "last_error", "starts", "restarts":
		default:
			t.Fatalf("engine key grew an unexpected field %q", k)
		}
	}
	if _, ok := eng["state"].(string); !ok {
		t.Fatalf("engine.state = %v, want a string", eng["state"])
	}
}
