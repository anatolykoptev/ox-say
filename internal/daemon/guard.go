package daemon

import (
	"mime"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/anatolykoptev/go-mcpserver"
	"github.com/anatolykoptev/ox-say/internal/stt"
)

// Guard rejects what a web page can send to a loopback daemon. A Host that is
// not a loopback address means DNS rebinding. Cross-site browser requests are
// refused by http.CrossOriginProtection (Sec-Fetch-Site, else Origin). POST
// bodies must be JSON, so a cross-origin "simple" request (text/plain, form
// data) fails even from a browser that sends neither header. go-mcpserver
// protects /mcp alone; Guard wraps every route.
func Guard(next http.Handler) http.Handler {
	protected := http.NewCrossOriginProtection().Handler(next)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !loopbackHost(r.Host) {
			writeErr(w, http.StatusForbidden, "host not allowed")
			return
		}
		if r.Method == http.MethodPost && !postBodyOK(r) {
			writeErr(w, http.StatusUnsupportedMediaType, "Content-Type must be application/json")
			return
		}
		protected.ServeHTTP(w, r)
	})
}

// postBodyOK requires JSON on every POST — except the transcriptions route,
// which is OpenAI-compatible multipart/form-data (file upload), and a
// session audio chunk, which is application/octet-stream (raw PCM). The
// exemptions name the exact method and path so no other POST opens up.
func postBodyOK(r *http.Request) bool {
	ct := r.Header.Get("Content-Type")
	if jsonBody(ct) {
		return true
	}
	if r.Method != http.MethodPost {
		return false
	}
	mt, _, err := mime.ParseMediaType(ct)
	if err != nil {
		return false
	}
	if r.URL.Path == "/v1/audio/transcriptions" {
		return mt == "multipart/form-data"
	}
	return mt == "application/octet-stream" && sttSessionAudioPath(r.URL.EscapedPath())
}

// sttSessionAudioPath reports whether the escaped request path is exactly
// /v1/audio/transcriptions/sessions/<id>/audio with a well-formed id — the
// one POST allowed to carry application/octet-stream. The id segment is
// checked unescaped, the same value the route sees in PathValue, so an
// encoded slash lands inside it (where the regexp refuses it) instead of
// changing the segment count.
func sttSessionAudioPath(escapedPath string) bool {
	seg := strings.Split(escapedPath, "/")
	if len(seg) != 7 || seg[0] != "" ||
		seg[1] != "v1" || seg[2] != "audio" || seg[3] != "transcriptions" ||
		seg[4] != "sessions" || seg[6] != "audio" {
		return false
	}
	id, err := url.PathUnescape(seg[5])
	return err == nil && sessionIDRe.MatchString(id)
}

// loopbackHost reports whether a Host header names this machine by a loopback
// literal or "localhost", with or without a port.
func loopbackHost(host string) bool {
	h := host
	if hh, _, err := net.SplitHostPort(host); err == nil {
		h = hh
	}
	h = strings.TrimSuffix(strings.TrimPrefix(h, "["), "]")
	if strings.EqualFold(h, "localhost") {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

func jsonBody(contentType string) bool {
	mt, _, err := mime.ParseMediaType(contentType)
	return err == nil && mt == "application/json"
}

// ServerConfig is the go-mcpserver configuration `ox-say serve` runs with.
func (d *Daemon) ServerConfig(version string) mcpserver.Config {
	return mcpserver.Config{
		Name:    "ox-say",
		Version: version,
		Host:    d.Cfg.Host,
		Port:    d.Cfg.Port,
		Logger:  d.log,
		// speak blocks on a cold engine start (Metal shader compile on first
		// ever run) plus synthesis — give it the startup window plus slack.
		// transcribe waits on the STT semaphore behind any in-flight run,
		// then runs its own — the worst case is the scaled budget on the
		// longest allowed clip, twice, plus slack.
		ToolTimeouts: map[string]time.Duration{
			"speak":      d.Cfg.StartupTimeout + 2*time.Minute,
			"transcribe": 2*stt.WorstTimeout(d.Cfg.STTMaxAudio, d.Cfg.STTTimeout) + 2*time.Minute,
		},
		Routes:     d.Routes,
		Middleware: []mcpserver.Middleware{Guard},
		OnShutdown: d.Shutdown,
	}
}
