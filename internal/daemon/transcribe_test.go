package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/stt"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// sttSetup points the daemon's STT config at the test binary re-exec'd as
// the fake ox-stt and creates the model files the Transcribe stat check
// needs. It turns the resident STT server OFF (STTSup was already built by
// newDaemon, so both the config flag and the field must move) — the tests
// using it assert the per-call CLI path. Returns the fake's record log path.
func sttSetup(t *testing.T, d *Daemon, dir string) string {
	t.Helper()
	return sttFake(t, d, dir, false)
}

// sttSetupServer is sttSetup with the resident STT server left enabled, so
// transcriptions route to the fake `ox-stt --serve` child.
func sttSetupServer(t *testing.T, d *Daemon, dir string) string {
	t.Helper()
	return sttFake(t, d, dir, true)
}

func sttFake(t *testing.T, d *Daemon, dir string, server bool) string {
	t.Helper()
	t.Setenv("OXSAY_FAKE_STT", "1")
	log := filepath.Join(dir, "stt.log")
	t.Setenv("OXSAY_FAKE_STT_LOG", log)
	model := filepath.Join(dir, "parakeet.bin")
	whisper := filepath.Join(dir, "whisper.bin")
	for _, m := range []string{model, whisper} {
		if err := os.WriteFile(m, []byte("fake"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	d.Cfg.STTBin = os.Args[0]
	d.Cfg.STTModel = model
	d.Cfg.STTWhisperModel = whisper
	d.Cfg.STTGPU = "auto"
	d.Cfg.STTTimeout = 30 * time.Second
	d.Cfg.STTMaxUploadMB = 10
	if !server {
		d.Cfg.STTServer = "off"
		d.STTSup = nil
	}
	return log
}

// lastArgvArgs returns the argv fields the fake ox-stt recorded for its most
// recent run.
func lastArgvArgs(t *testing.T, log string) []string {
	t.Helper()
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	var last []string
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if rest, ok := strings.CutPrefix(line, "argv\t"); ok {
			_, args, _ := strings.Cut(rest, "\t")
			last = strings.Split(args, "\t")
		}
	}
	return last
}

func argvHas(args []string, want string) bool {
	for _, a := range args {
		if a == want {
			return true
		}
	}
	return false
}

func transcriptionServer(t *testing.T, d *Daemon) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	d.Routes(mux)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

// postTranscription uploads wav bytes to the route as multipart.
func postTranscription(t *testing.T, url string, wav []byte, fields map[string]string) *http.Response {
	t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	fw, err := mw.CreateFormFile("file", "in.wav")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := fw.Write(wav); err != nil {
		t.Fatal(err)
	}
	for k, v := range fields {
		if err := mw.WriteField(k, v); err != nil {
			t.Fatal(err)
		}
	}
	if err := mw.Close(); err != nil {
		t.Fatal(err)
	}
	resp, err := http.Post(url, mw.FormDataContentType(), &body)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

// S1 — device choice is driven by the shared GPU lease the TTS engine
// holds for its child's whole lifetime: Ready → ox-stt gets -ng; once the
// stopped child's exit has freed the lease, GPU=auto → no -ng. The wait
// covers the lease, not just the state: the supervisor reports Stopped
// before the child has exited, and the lease outlives that window.
// Mutation: drop the GPULease wiring (or always omit -ng) in the device
// choice -> RED.
func TestTranscribeDeviceChoice(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, func(ec *engine.Config) {
		ec.IdleStop = 300 * time.Millisecond
		ec.IdleTick = 20 * time.Millisecond
	})
	log := sttSetup(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	if _, err := d.Sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	// Pin the engine in Ready while the transcription runs — the device
	// choice takes the lease at spawn time and must find it held.
	g := d.Sup.Acquire()
	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	g.Release()
	if args := lastArgvArgs(t, log); !argvHas(args, "-ng") {
		t.Fatalf("engine ready: argv %v missing -ng", args)
	}

	// Stopped alone is not enough: the teardown window (Stopped before the
	// child exits) still holds the lease, so wait for the release too.
	testutil.WaitFor(t, 5*time.Second, func() bool {
		return d.Sup.State() == engine.StateStopped && !d.gpu.Held()
	}, "idle stop + lease release")
	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	if args := lastArgvArgs(t, log); argvHas(args, "-ng") {
		t.Fatalf("engine stopped + GPU=auto: argv %v unexpectedly has -ng", args)
	}
}

// S4 — upload and conversion temp files are deleted when the request ends,
// on success and on an ox-stt failure.
// Mutation: drop the deferred os.Remove of the upload temp file in
// handleTranscribe -> RED (a leftover file remains).
func TestTranscribeUploadTempRemoved(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	tmpdir := filepath.Join(dir, "tmp")
	if err := os.MkdirAll(tmpdir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", tmpdir)
	t.Setenv("OXSAY_FAKE_STT_DELAY_MS", "2000")
	d := newTestDaemon(t, dir, nil)
	sttSetup(t, d, dir)
	srv := transcriptionServer(t, d)

	count := func() int {
		entries, err := os.ReadDir(tmpdir)
		if err != nil {
			t.Fatal(err)
		}
		return len(entries)
	}

	// Success path: the request holds its temp files for the fake's delay —
	// poll mid-flight so the assertion is not vacuous (a file MUST have
	// landed in TMPDIR), then expect zero left behind.
	respCh := make(chan *http.Response, 1)
	go func() {
		respCh <- postTranscription(t, srv.URL+"/v1/audio/transcriptions",
			testutil.TinyWAV(), map[string]string{"model": "parakeet"})
	}()
	testutil.WaitFor(t, 5*time.Second, func() bool { return count() > 0 },
		"upload temp file to appear")
	resp := <-respCh
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("transcription status = %d, want 200", resp.StatusCode)
	}
	if n := count(); n != 0 {
		t.Fatalf("%d temp files left after a successful transcription", n)
	}

	// Failure path: ox-stt exits 1 — the upload file must still be removed.
	t.Setenv("OXSAY_FAKE_STT_DELAY_MS", "0")
	t.Setenv("OXSAY_FAKE_STT_EXIT", "1")
	resp = postTranscription(t, srv.URL+"/v1/audio/transcriptions",
		testutil.TinyWAV(), map[string]string{"model": "parakeet"})
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("engine failure status = %d, want 500 (body %s)", resp.StatusCode, body)
	}
	if n := count(); n != 0 {
		t.Fatalf("%d temp files left after a failed transcription", n)
	}
}

// S6 — response formats: verbose_json is OpenAI's shape (duration, segments
// start/end, words word/start/end) built from the engine output; ox_json
// carries the engine's words (w/s/e/p) verbatim; srt/vtt render segment times;
// unknown model is a 400; timestamp_granularities[] is accepted.
// Mutation: swap s and e when building subtitles, or Start and End in
// toOpenAIVerbose (internal/daemon/transcribe.go) -> RED.
func TestTranscribeFormats(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	sttSetup(t, d, dir)
	srv := transcriptionServer(t, d)
	url := srv.URL + "/v1/audio/transcriptions"

	payload := `{"engine":"parakeet","language":"en","duration_s":1.5,"elapsed_s":0.2,` +
		`"text":"hello world.","segments":[{"s":0.0,"e":1.5,"text":"hello world."}],` +
		`"words":[{"w":"hello","s":0.0,"e":0.9,"p":0.99},{"w":"world.","s":0.9,"e":1.5,"p":0.98}]}`
	t.Setenv("OXSAY_FAKE_STT_JSON", payload)

	do := func(fields map[string]string) (int, []byte) {
		resp := postTranscription(t, url, testutil.TinyWAV(), fields)
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, b
	}

	code, body := do(map[string]string{"response_format": "verbose_json", "timestamp_granularities[]": "word"})
	if code != http.StatusOK {
		t.Fatalf("verbose_json status = %d (body %s)", code, body)
	}
	var vj struct {
		Task     string  `json:"task"`
		Text     string  `json:"text"`
		Language string  `json:"language"`
		Duration float64 `json:"duration"`
		Segments []struct {
			ID    int     `json:"id"`
			Start float64 `json:"start"`
			End   float64 `json:"end"`
			Text  string  `json:"text"`
		} `json:"segments"`
		Words []struct {
			Word  string  `json:"word"`
			Start float64 `json:"start"`
			End   float64 `json:"end"`
		} `json:"words"`
	}
	if err := json.Unmarshal(body, &vj); err != nil {
		t.Fatalf("verbose_json not JSON: %v", err)
	}
	if vj.Task != "transcribe" || vj.Text != "hello world." || vj.Language != "en" || vj.Duration != 1.5 {
		t.Fatalf("verbose_json = %s", body)
	}
	if len(vj.Segments) != 1 || vj.Segments[0].Start != 0.0 || vj.Segments[0].End != 1.5 {
		t.Fatalf("verbose_json segments: %s", body)
	}
	// OpenAI's segment fields exist (clients read avg_logprob, no_speech_prob)
	for _, key := range []string{`"seek":`, `"tokens":[]`, `"temperature":`, `"avg_logprob":`, `"compression_ratio":`, `"no_speech_prob":`} {
		if !strings.Contains(string(body), key) {
			t.Fatalf("verbose_json segment lacks %s: %s", key, body)
		}
	}
	if len(vj.Words) != 2 || vj.Words[1].Word != "world." || vj.Words[1].Start != 0.9 || vj.Words[1].End != 1.5 {
		t.Fatalf("verbose_json words: %s", body)
	}

	code, body = do(map[string]string{"response_format": "ox_json"})
	var oj struct {
		Words []struct {
			W string  `json:"w"`
			S float64 `json:"s"`
			E float64 `json:"e"`
			P float64 `json:"p"`
		} `json:"words"`
	}
	if code != http.StatusOK || json.Unmarshal(body, &oj) != nil ||
		len(oj.Words) != 2 || oj.Words[0].W != "hello" || oj.Words[0].E != 0.9 || oj.Words[0].P != 0.99 {
		t.Fatalf("ox_json: status %d body %s", code, body)
	}

	code, body = do(map[string]string{"response_format": "srt"})
	if code != http.StatusOK || !strings.Contains(string(body), "1\n00:00:00,000 --> 00:00:01,500\nhello world.\n") {
		t.Fatalf("srt: status %d body %q", code, body)
	}
	code, body = do(map[string]string{"response_format": "vtt"})
	if code != http.StatusOK || !strings.HasPrefix(string(body), "WEBVTT\n\n") || !strings.Contains(string(body), "00:00:00.000 --> 00:00:01.500") {
		t.Fatalf("vtt: status %d body %q", code, body)
	}
	code, body = do(map[string]string{"response_format": "text"})
	if code != http.StatusOK || string(body) != "hello world." {
		t.Fatalf("text: status %d body %q", code, body)
	}
	code, body = do(nil) // default json → {"text"}
	if code != http.StatusOK {
		t.Fatalf("json: status %d (body %s)", code, body)
	}
	var j struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(body, &j); err != nil || j.Text != "hello world." {
		t.Fatalf("json body = %s", body)
	}
	code, body = do(map[string]string{"model": "not-a-model"})
	if code != http.StatusBadRequest {
		t.Fatalf("unknown model: status %d, want 400 (body %s)", code, body)
	}
	code, body = do(map[string]string{"model": "whisper-1", "response_format": "text"})
	if code != http.StatusOK {
		t.Fatalf("whisper-1 alias: status %d (body %s)", code, body)
	}
}

// S7 — the transcribe tool refuses a relative audio_path and omits words
// unless asked; out_path gets the full result JSON under speak's rules.
// Mutation: drop the IsAbs check in stt.Transcribe -> RED.
func TestTranscribeTool(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	sttSetup(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	// A relative path that resolves: only the IsAbs check refuses it.
	t.Chdir(dir)
	if _, _, err := d.toolTranscribe(context.Background(), nil, transcribeToolIn{
		AudioPath: "in.wav",
	}); err == nil {
		t.Fatal("transcribe accepted a relative audio_path")
	}

	res, out, err := d.toolTranscribe(context.Background(), nil, transcribeToolIn{AudioPath: src})
	if err != nil {
		t.Fatal(err)
	}
	_ = res
	if out.Text != "hello world." || out.Engine != "parakeet" || out.DurationS <= 0 {
		t.Fatalf("tool out = %+v", out)
	}
	if len(out.Words) != 0 {
		t.Fatalf("words=false returned %d words", len(out.Words))
	}

	_, out, err = d.toolTranscribe(context.Background(), nil, transcribeToolIn{AudioPath: src, Words: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(out.Words) != 2 {
		t.Fatalf("words=true returned %d words", len(out.Words))
	}

	// out_path: written with the full engine JSON; an existing file refused.
	outPath := filepath.Join(dir, "result.json")
	_, out, err = d.toolTranscribe(context.Background(), nil, transcribeToolIn{AudioPath: src, OutPath: outPath})
	if err != nil {
		t.Fatal(err)
	}
	if out.Path != outPath {
		t.Fatalf("out.Path = %q", out.Path)
	}
	raw, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatal(err)
	}
	var stored struct {
		Text  string `json:"text"`
		Words []struct {
			W string `json:"w"`
		} `json:"words"`
	}
	if err := json.Unmarshal(raw, &stored); err != nil || stored.Text != "hello world." || len(stored.Words) != 2 {
		t.Fatalf("out_path JSON = %s", raw)
	}
	if _, _, err := d.toolTranscribe(context.Background(), nil, transcribeToolIn{AudioPath: src, OutPath: outPath}); err == nil {
		t.Fatal("out_path overwrote an existing file")
	}
	if _, _, err := d.toolTranscribe(context.Background(), nil, transcribeToolIn{
		AudioPath: src, OutPath: filepath.Join(dir, "result.txt"),
	}); err == nil {
		t.Fatal("out_path accepted a non-.json extension")
	}
}

// The upload cap: a file part one byte over it is a 413 and leaves no temp
// file behind.
// Mutation: drop `n > maxUp ||` from the size check in handleTranscribe
// (internal/daemon/transcribe.go) -> RED (status 200).
func TestTranscribeUploadCap(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	tmpdir := filepath.Join(dir, "tmp")
	if err := os.Mkdir(tmpdir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", tmpdir)
	d := newTestDaemon(t, dir, nil)
	sttSetup(t, d, dir)
	d.Cfg.STTMaxUploadMB = 1
	srv := transcriptionServer(t, d)

	over := append(testutil.TinyWAV(), make([]byte, 1<<20+1-len(testutil.TinyWAV()))...)
	resp := postTranscription(t, srv.URL+"/v1/audio/transcriptions", over, nil)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("1 MB + 1 byte: status %d, want 413", resp.StatusCode)
	}
	left, _ := filepath.Glob(filepath.Join(tmpdir, "ox-say-*"))
	if len(left) != 0 {
		t.Fatalf("temp files left: %v", left)
	}
}

// stt errors map to distinct statuses: a timeout is 504, a missing model 503.
// Mutation: map *stt.TimeoutError to 500 in transcribeStatus -> RED.
func TestTranscribeErrorStatuses(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	sttSetup(t, d, dir)
	srv := transcriptionServer(t, d)
	url := srv.URL + "/v1/audio/transcriptions"

	t.Setenv("OXSAY_FAKE_STT_DELAY_MS", "2000")
	d.Cfg.STTTimeout = 300 * time.Millisecond
	resp := postTranscription(t, url, testutil.TinyWAV(), nil)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusGatewayTimeout {
		t.Fatalf("timeout: status %d, want 504", resp.StatusCode)
	}

	t.Setenv("OXSAY_FAKE_STT_DELAY_MS", "0")
	d.Cfg.STTTimeout = 30 * time.Second
	d.Cfg.STTModel = filepath.Join(dir, "missing.bin")
	resp = postTranscription(t, url, testutil.TinyWAV(), nil)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("missing model: status %d, want 503", resp.StatusCode)
	}
}

// The daemon passes OX_SAY_STT_MAX_AUDIO_SECS through to stt.
// Mutation: delete `MaxAudio: d.Cfg.STTMaxAudio,` in Daemon.Transcribe
// (internal/daemon/transcribe.go) -> RED (200: the 4 h default applies).
func TestTranscribeMaxAudioWired(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	sttSetup(t, d, dir)
	d.Cfg.STTMaxAudio = time.Second
	srv := transcriptionServer(t, d)

	clip := filepath.Join(dir, "three.wav")
	if out, err := exec.Command("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
		"-i", "sine=frequency=440:duration=3", "-ar", "16000", "-ac", "1", clip).CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg: %v %s", err, out)
	}
	data, err := os.ReadFile(clip)
	if err != nil {
		t.Fatal(err)
	}
	resp := postTranscription(t, srv.URL+"/v1/audio/transcriptions", data, nil)
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest || !strings.Contains(string(body), "longer than") {
		t.Fatalf("3 s clip with a 1 s cap: status %d body %s, want 400 about the length", resp.StatusCode, body)
	}
}

// Every stt error class has its status.
// Mutation: drop `errors.Is(err, stt.ErrBusy)` from transcribeStatus -> RED.
func TestTranscribeStatusMap(t *testing.T) {
	for _, c := range []struct {
		name string
		err  error
		want int
	}{
		{"input", &stt.InputError{}, http.StatusBadRequest},
		{"timeout", &stt.TimeoutError{}, http.StatusGatewayTimeout},
		{"model", &stt.ModelError{}, http.StatusServiceUnavailable},
		{"busy", stt.ErrBusy, http.StatusServiceUnavailable},
		{"busy wrapped", fmt.Errorf("x: %w", stt.ErrBusy), http.StatusServiceUnavailable},
		{"engine", &stt.EngineError{}, http.StatusInternalServerError},
		{"other", errors.New("boom"), http.StatusInternalServerError},
	} {
		if got := transcribeStatus(c.err); got != c.want {
			t.Errorf("%s: status %d, want %d", c.name, got, c.want)
		}
	}
}
