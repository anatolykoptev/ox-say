package daemon

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/go-mcpserver"
	"github.com/anatolykoptev/ox-say/internal/stt"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The handler under test is the one `ox-say serve` runs: mcpserver.Build over
// d.ServerConfig, so dropping Guard from ServerConfig turns these red.
func servedHandler(t *testing.T) http.Handler {
	t.Helper()
	d := newTestDaemon(t, t.TempDir(), nil)
	cfg := d.ServerConfig("test")
	h, err := mcpserver.Build(mcpserver.NewServer(&mcp.Implementation{Name: "ox-say", Version: "test"}, cfg), cfg)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

// The transcribe tool's MCP timeout must outlast the longest legal
// transcription: the duration-scaled budget on a max-length clip on the
// slowest engine, twice (a queued call can sit behind one in-flight
// run), plus slack. A flat 2×STTTimeout would cut a >3 h whisper clip
// before its own deadline fired.
// Mutation: revert the entry to 2*d.Cfg.STTTimeout + 2*time.Minute in
// ServerConfig -> RED.
func TestTranscribeToolTimeoutScales(t *testing.T) {
	d := newTestDaemon(t, t.TempDir(), nil)
	// not the defaults, so a hardcoded entry cannot pass
	d.Cfg.STTTimeout = 30 * time.Second
	d.Cfg.STTMaxAudio = time.Hour
	got := d.ServerConfig("test").ToolTimeouts["transcribe"]
	want := 2*stt.WorstTimeout(d.Cfg.STTMaxAudio, d.Cfg.STTTimeout) + 2*time.Minute
	if got != want {
		t.Fatalf("transcribe tool timeout = %s, want %s", got, want)
	}
}

func TestGuard(t *testing.T) {
	h := servedHandler(t)
	voiceBody := `{"name":"ben","audio_path":"/tmp/x.wav"}`
	// A well-formed multipart body (fields only, no file): reaching the
	// handler answers 400 "file is required"; being stopped by the guard
	// answers 415.
	mpBody := "--xx\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nparakeet\r\n--xx--\r\n"
	mpType := "multipart/form-data; boundary=xx"

	cases := []struct {
		name, method, path, host, ctype, body string
		header                                map[string]string
		want                                  int
	}{
		// DNS rebinding: the page's own hostname resolves to 127.0.0.1
		{"rebinding GET", "GET", "/status", "attacker.example:8094", "", "", nil, http.StatusForbidden},
		{"rebinding POST", "POST", "/v1/audio/voices", "attacker.example:8094", "application/json", voiceBody, nil, http.StatusForbidden},
		// cross-site "simple" request: no preflight, text/plain body
		{"text/plain POST", "POST", "/v1/audio/voices", "127.0.0.1:8094", "text/plain", voiceBody, nil, http.StatusUnsupportedMediaType},
		// cross-site JSON POST from a browser that sends Sec-Fetch-Site / Origin
		{"cross-site POST", "POST", "/v1/audio/voices", "127.0.0.1:8094", "application/json", voiceBody,
			map[string]string{"Sec-Fetch-Site": "cross-site", "Origin": "https://evil.example"}, http.StatusForbidden},
		{"cross-origin POST without Sec-Fetch-Site", "POST", "/v1/audio/speech", "127.0.0.1:8094", "application/json", `{"input":"x"}`,
			map[string]string{"Origin": "https://evil.example"}, http.StatusForbidden},
		// multipart is OpenAI-compatible ONLY on the transcriptions route:
		// accepted there (reaches the handler → 400), refused elsewhere (415)
		{"multipart transcriptions", "POST", "/v1/audio/transcriptions", "127.0.0.1:8094", mpType, mpBody, nil, http.StatusBadRequest},
		{"multipart voices refused", "POST", "/v1/audio/voices", "127.0.0.1:8094", mpType, mpBody, nil, http.StatusUnsupportedMediaType},
		{"multipart speech refused", "POST", "/v1/audio/speech", "127.0.0.1:8094", mpType, mpBody, nil, http.StatusUnsupportedMediaType},
		{"cross-site multipart transcriptions", "POST", "/v1/audio/transcriptions", "127.0.0.1:8094", mpType, mpBody,
			map[string]string{"Sec-Fetch-Site": "cross-site"}, http.StatusForbidden},
		// what the CLI and local clients send is still served
		{"loopback GET", "GET", "/status", "127.0.0.1:8094", "", "", nil, http.StatusOK},
		{"localhost GET", "GET", "/status", "localhost:8094", "", "", nil, http.StatusOK},
		{"ipv6 loopback GET", "GET", "/status", "[::1]:8094", "", "", nil, http.StatusOK},
		{"cli POST reaches the handler", "POST", "/v1/audio/speech", "127.0.0.1:8094", "application/json", `{}`, nil, http.StatusBadRequest},
		{"json with charset reaches the handler", "POST", "/v1/audio/speech", "127.0.0.1:8094", "application/json; charset=utf-8", `{}`, nil, http.StatusBadRequest},
		{"cli DELETE reaches the handler", "DELETE", "/v1/audio/voices/nobody", "127.0.0.1:8094", "", "", nil, http.StatusNotFound},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest(c.method, c.path, strings.NewReader(c.body))
			req.Host = c.host
			if c.ctype != "" {
				req.Header.Set("Content-Type", c.ctype)
			}
			for k, v := range c.header {
				req.Header.Set(k, v)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != c.want {
				t.Fatalf("%s %s Host=%s: status %d, want %d (body %s)", c.method, c.path, c.host, rec.Code, c.want, rec.Body.String())
			}
		})
	}
}
