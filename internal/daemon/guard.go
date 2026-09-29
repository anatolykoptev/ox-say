package daemon

import (
	"mime"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/anatolykoptev/go-mcpserver"
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
		if r.Method == http.MethodPost && !jsonBody(r.Header.Get("Content-Type")) {
			writeErr(w, http.StatusUnsupportedMediaType, "Content-Type must be application/json")
			return
		}
		protected.ServeHTTP(w, r)
	})
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
		ToolTimeouts: map[string]time.Duration{"speak": 5 * time.Minute},
		Routes:       d.Routes,
		Middleware:   []mcpserver.Middleware{Guard},
		OnShutdown:   d.Shutdown,
	}
}
