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

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// newTestDaemon builds a Daemon whose engine binary is the test binary
// re-exec'd as the fake child.
func newTestDaemon(t *testing.T, dir string, tune func(*engine.Config)) *Daemon {
	t.Helper()
	home := filepath.Join(dir, "home")
	cfg := &config.Config{
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
	d, err := newDaemon(cfg, testLogger(), func(ec *engine.Config) {
		ec.HealthPoll = 10 * time.Millisecond
		ec.KillGrace = 2 * time.Second
		if tune != nil {
			tune(ec)
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

func childVoices(t *testing.T, base string) map[string]bool {
	t.Helper()
	resp, err := http.Get(base + "/v1/audio/voices")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out struct {
		Voices []string `json:"voices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	m := map[string]bool{}
	for _, v := range out.Voices {
		m[v] = true
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

	base, err := d.Sup.EnsureReady(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	src := testutil.WriteTinyWAV(t, dir, "clip.wav")
	if _, registered, err := d.AddVoice(context.Background(), "ben", src, ""); err != nil {
		t.Fatal(err)
	} else if !registered {
		t.Fatal("voice was not registered into the running engine")
	}
	if !childVoices(t, base)["ben"] {
		t.Fatal("first child does not list ben")
	}

	// Idle loop stops the child.
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return d.Sup.State() == engine.StateStopped
	}, "idle stop")

	// Restart: the replay inside the start path must re-register ben.
	base2, err := d.Sup.EnsureReady(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !childVoices(t, base2)["ben"] {
		t.Fatal("restarted child does not list ben — voices were not replayed")
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
