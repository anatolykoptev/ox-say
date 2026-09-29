package daemon

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/anatolykoptev/go-mcpserver"
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

func TestGuard(t *testing.T) {
	h := servedHandler(t)
	voiceBody := `{"name":"ben","audio_path":"/tmp/x.wav"}`

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
