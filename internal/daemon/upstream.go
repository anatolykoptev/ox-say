package daemon

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
)

// The uncensored notes model lives on a host that can take it down — the
// repo can be removed or gated. While the file is not installed, its rows say
// whether upstream still has it, so "download" does not promise what the host
// no longer serves. The answer is a HEAD of the catalog's <url-base>/<file>,
// run in the background and cached: the read path never blocks on the network.
const (
	notesUpstreamAvailable = "available"
	notesUpstreamGone      = "gone"    // 404/410, or 401/403 — gated and removed read the same to us
	notesUpstreamUnknown   = "unknown" // transport errors, timeouts, 5xx, and "not probed yet"
)

// notesUpstreamTTL is how long one probe's verdict is trusted; the var form
// lets a test shorten it.
var notesUpstreamTTL = 10 * time.Minute

// upstreamHEAD is the single network call the probe makes. It is a var so no
// test ever touches the network.
var upstreamHEAD = func(ctx context.Context, url string) (int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, url, nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("User-Agent", "ox-say/"+version)
	resp, err := notesUpstreamClient.Do(req)
	if err != nil {
		return 0, err
	}
	_ = resp.Body.Close()
	return resp.StatusCode, nil
}

// notesUpstreamClient bounds the probe: five seconds all-in, at most five
// redirects. Nothing goes with the HEAD — no cookies, no body, just the plain
// ox-say User-Agent.
var notesUpstreamClient = &http.Client{
	Timeout: 5 * time.Second,
	CheckRedirect: func(_ *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("the download URL redirects without resolving")
		}
		return nil
	},
}

// notesUpstreamProbe is the cached, single-flight verdict for the one entry
// that needs it. Readers share one in-flight probe; a stale or empty cache
// kicks the next background request.
type notesUpstreamProbe struct {
	mu       sync.Mutex
	state    string // "" until the first probe lands
	probedAt time.Time
	inflight bool
	now      func() time.Time
}

// notesUpstream is the uncensored row's upstream field: "" (the field is
// omitted) once the file is installed — it does not matter whether the host
// still has it — otherwise the cached verdict, kicking a background probe
// when the cache is stale or has never run.
func (d *Daemon) notesUpstream(e *config.NotesModelEntry, installed bool) string {
	if e.Kind != config.NotesKindUncensored || installed {
		return ""
	}
	p := &d.upstream
	p.mu.Lock()
	if p.now == nil {
		p.now = time.Now
	}
	st := p.state
	if !p.inflight && p.now().Sub(p.probedAt) >= notesUpstreamTTL {
		p.inflight = true
		// The HEAD function is captured with the trigger: a goroutine uses
		// the stub its own reader saw, never a later test's var swap.
		go d.probeNotesUpstream(e.URL+"/"+e.File, upstreamHEAD)
	}
	p.mu.Unlock()
	if st == "" {
		return notesUpstreamUnknown
	}
	return st
}

// probeNotesUpstream does the HEAD and stores the verdict. It owns the
// inflight flag taken by the reader that started it.
func (d *Daemon) probeNotesUpstream(url string, head func(context.Context, string) (int, error)) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	code, err := head(ctx, url)
	cancel()
	st := notesUpstreamUnknown
	if err == nil {
		switch {
		case code == http.StatusNotFound || code == http.StatusGone ||
			code == http.StatusUnauthorized || code == http.StatusForbidden:
			st = notesUpstreamGone
		case code >= 200 && code < 300:
			st = notesUpstreamAvailable
		}
	}
	p := &d.upstream
	p.mu.Lock()
	if p.now == nil {
		p.now = time.Now
	}
	p.state = st
	p.probedAt = p.now()
	p.inflight = false
	p.mu.Unlock()
}

// probed reports whether one background probe has landed and none is in
// flight: the test seam that waits for the row's verdict to appear.
func (p *notesUpstreamProbe) probed() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return !p.probedAt.IsZero() && !p.inflight
}
