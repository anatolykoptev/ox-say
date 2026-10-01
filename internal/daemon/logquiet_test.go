package daemon

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/anatolykoptev/go-mcpserver"
)

// The records come from go-mcpserver's own access-log middleware, so a rename
// of its message or attributes shows up here instead of silently disabling
// the filter.
func TestQuietSessionChunks(t *testing.T) {
	const chunk = "/v1/audio/transcriptions/sessions/0123456789abcdef0123456789abcdef/audio"
	var buf bytes.Buffer
	logger := slog.New(QuietSessionChunks(slog.NewTextHandler(&buf, nil)))
	h := mcpserver.RequestLog(logger)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Fail") != "" {
			w.WriteHeader(http.StatusNotFound)
		}
	}))

	for _, tc := range []struct {
		name, method, path string
		fail, logged       bool
	}{
		{"ok chunk", http.MethodPost, chunk, false, false},
		{"failed chunk", http.MethodPost, chunk, true, true},
		{"finish", http.MethodPost, strings.TrimSuffix(chunk, "/audio") + "/finish", false, true},
		{"one-shot upload", http.MethodPost, "/v1/audio/transcriptions", false, true},
		{"chunk path, other method", http.MethodGet, chunk, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			buf.Reset()
			req := httptest.NewRequest(tc.method, tc.path, nil)
			if tc.fail {
				req.Header.Set("X-Fail", "1")
			}
			h.ServeHTTP(httptest.NewRecorder(), req)
			got := strings.Contains(buf.String(), "msg=request")
			if got != tc.logged {
				t.Fatalf("logged = %v, want %v; log: %q", got, tc.logged, buf.String())
			}
		})
	}

	buf.Reset()
	logger.With("k", "v").Info("request", "method", http.MethodPost, "path", chunk, "status", 200)
	if buf.Len() != 0 {
		t.Fatalf("a logger derived With attrs lost the filter: %q", buf.String())
	}
}
