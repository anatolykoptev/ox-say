package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// sttSetup points the daemon's STT config at the test binary re-exec'd as
// the fake ox-stt and creates the model files the Transcribe stat check
// needs. Returns the fake's argv/start/end record log path.
func sttSetup(t *testing.T, d *Daemon, dir string) string {
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

// S1 — device choice is driven by the TTS supervisor's live state: Ready →
// ox-stt gets -ng; back to Stopped with GPU=auto → no -ng.
// Mutation: drop the EngineBusy term (or always omit -ng) in the device
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
	// choice reads state at spawn time and must see busy.
	g := d.Sup.Acquire()
	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	g.Release()
	if args := lastArgvArgs(t, log); !argvHas(args, "-ng") {
		t.Fatalf("engine ready: argv %v missing -ng", args)
	}

	testutil.WaitFor(t, 5*time.Second, func() bool {
		return d.Sup.State() == engine.StateStopped
	}, "idle stop")
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

// S6 — response formats: verbose_json carries words with s/e/w/p exactly as
// the engine produced them; srt/vtt render segment times; unknown model is
// a 400; timestamp_granularities[] is accepted.
// Mutation: swap s and e when building subtitles (or drop words) -> RED.
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
		Text     string `json:"text"`
		Language string `json:"language"`
		Words    []struct {
			W string  `json:"w"`
			S float64 `json:"s"`
			E float64 `json:"e"`
			P float64 `json:"p"`
		} `json:"words"`
	}
	if err := json.Unmarshal(body, &vj); err != nil {
		t.Fatalf("verbose_json not JSON: %v", err)
	}
	if vj.Text != "hello world." || vj.Language != "en" {
		t.Fatalf("verbose_json = %s", body)
	}
	if len(vj.Words) != 2 || vj.Words[0].W != "hello" || vj.Words[0].S != 0.0 || vj.Words[0].E != 0.9 || vj.Words[0].P != 0.99 {
		t.Fatalf("verbose_json words not verbatim: %s", body)
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
		Text   string `json:"text"`
		Words  []struct {
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
