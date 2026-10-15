package daemon

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"regexp"
	"time"
)

// Streaming transcription sessions on the resident ox-stt server
// (`ox-stt --serve --vad <model>`). The daemon exposes them under
// /v1/audio/transcriptions/sessions and proxies verbatim: same method,
// same body and Content-Type, exact Content-Length (the server's own
// guard insists on it), upstream status and JSON back.
//
// Sessions live only in the running server, so only create may start it —
// the per-session routes answer 404 when it is not ready, and the client
// falls back to a one-shot /v1/audio/transcriptions upload.

const (
	// sessionMaxAudio bounds one /audio chunk: 30 s of 16 kHz f32le mono
	// PCM — the server's per-request window.
	sessionMaxAudio = 30 * 16000 * 4 // 1,920,000
	// sessionMaxJSON bounds the JSON bodies of the session routes.
	sessionMaxJSON = 4 << 10
	// sessionMaxResp caps what the proxy copies back from the server.
	sessionMaxResp = 8 << 20
)

// sessionIDRe is the session id shape the daemon accepts — the 32
// lowercase hex characters ox-stt issues. Anything else is a 404 before
// the server is contacted, so an id can never smuggle a path segment into
// the upstream URL.
var sessionIDRe = regexp.MustCompile(`^[0-9a-f]{32}$`)

// sttSessionIdle mirrors the resident server's own session reap — ox-stt
// drops a session idle past 120 s — plus margin: an entry older than it
// names a session the server no longer holds. A var so tests can lower it.
var sttSessionIdle = 125 * time.Second

// The daemon mirrors the server's session registry — sessions live inside
// the ox-stt process — so the count /status reports under
// busy.stt_sessions is built from what it proxies: a create's answer is
// noted, per-session traffic refreshes the entry, finish and delete drop
// it, and the sweep reaps anything idle past the server's own window.

// noteSTTSession marks id open — or refreshes it: traffic on the session
// proves the server still holds it.
func (d *Daemon) noteSTTSession(id string) {
	d.sessMu.Lock()
	d.sessSeen[id] = time.Now()
	d.sessMu.Unlock()
}

// dropSTTSession forgets id — the server consumed it or never held it.
func (d *Daemon) dropSTTSession(id string) {
	d.sessMu.Lock()
	delete(d.sessSeen, id)
	d.sessMu.Unlock()
}

// sttSessions counts the sessions the resident server still holds, reaping
// entries idle past the server's own window.
func (d *Daemon) sttSessions() int {
	d.sessMu.Lock()
	defer d.sessMu.Unlock()
	cut := time.Now().Add(-sttSessionIdle)
	for id, seen := range d.sessSeen {
		if seen.Before(cut) {
			delete(d.sessSeen, id)
		}
	}
	return len(d.sessSeen)
}

// sessionHTTP has no Timeout: the request context governs cancellation,
// and a finish call can legitimately wait out the server's 60 s pending
// decode budget.
var sessionHTTP = &http.Client{}

// writeSessionErr answers in the server's own error shape — {"error":"…"},
// NOT the daemon's nested writeErr — so a client sees one error format
// whether a refusal came from the proxy or the server behind it.
func writeSessionErr(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// handleSTTSessionCreate proxies POST /v1/audio/transcriptions/sessions to
// the server's POST /sessions. It is the one session route allowed to
// start the server — with the same backoff fast-fail as the transcription
// fallback, so a cooling-down server answers 503 at once.
func (d *Daemon) handleSTTSessionCreate(w http.ResponseWriter, r *http.Request) {
	if d.STTSup == nil {
		writeSessionErr(w, http.StatusServiceUnavailable, "streaming sessions need the STT server (OX_SAY_STT_SERVER=on)")
		return
	}
	if b := d.STTSup.Backoff(); b > 0 {
		writeSessionErr(w, http.StatusServiceUnavailable, fmt.Sprintf("stt server cooling down (%s)", b))
		return
	}
	g := d.STTSup.Acquire()
	defer g.Release()
	base, err := d.STTSup.EnsureReady(r.Context())
	if err != nil {
		writeSessionErr(w, http.StatusServiceUnavailable, fmt.Sprintf("stt server: %v", err))
		return
	}
	status, body := d.sttSessionProxy(w, r, base, "/sessions", sessionMaxJSON)
	if status/100 == 2 {
		var created struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(body, &created) == nil && sessionIDRe.MatchString(created.ID) {
			d.noteSTTSession(created.ID)
		}
	}
}

// handleSTTSessionAudio forwards one PCM chunk: f32le mono at 16 kHz, at
// most sessionMaxAudio bytes per call.
func (d *Daemon) handleSTTSessionAudio(w http.ResponseWriter, r *http.Request) {
	d.sttSessionOp(w, r, "audio", sessionMaxAudio)
}

func (d *Daemon) handleSTTSessionFinish(w http.ResponseWriter, r *http.Request) {
	d.sttSessionOp(w, r, "finish", sessionMaxJSON)
}

func (d *Daemon) handleSTTSessionDelete(w http.ResponseWriter, r *http.Request) {
	d.sttSessionOp(w, r, "", sessionMaxJSON)
}

// sttSessionOp is the shared body of the per-session routes: validate the
// id, take an in-flight guard, and proxy only to a server that is already
// ready — never spawning one. A restarted server lost its sessions, so
// not-ready reads as not-found and the client falls back to a one-shot
// transcription. The held guard keeps the idle accounting honest: session
// traffic counts as server activity.
func (d *Daemon) sttSessionOp(w http.ResponseWriter, r *http.Request, op string, limit int64) {
	if d.STTSup == nil {
		writeSessionErr(w, http.StatusServiceUnavailable, "streaming sessions need the STT server (OX_SAY_STT_SERVER=on)")
		return
	}
	id := r.PathValue("id")
	if !sessionIDRe.MatchString(id) {
		writeSessionErr(w, http.StatusNotFound, "session not found")
		return
	}
	g := d.STTSup.Acquire()
	defer g.Release()
	base, ok := d.STTSup.ReadyURL()
	if !ok {
		writeSessionErr(w, http.StatusNotFound, "session not found (the STT server restarted)")
		return
	}
	up := "/sessions/" + id
	if op != "" {
		up += "/" + op
	}
	status, _ := d.sttSessionProxy(w, r, base, up, limit)
	switch {
	case op == "audio" && status/100 == 2:
		d.noteSTTSession(id) // session traffic refreshes its idle clock
	case status == http.StatusNotFound || (op != "audio" && status/100 == 2):
		// The server no longer holds it: a finish consumed it, a delete
		// dropped it, or a 404 means it was already reaped upstream.
		d.dropSTTSession(id)
	}
}

// sttSessionProxy reads the request body under its cap, forwards it to the
// STT server at base+path, and copies the upstream status and JSON body
// back. The caller holds the guard; the request context carries the call.
// The status returned is what was written to the client — the upstream's
// code on a proxy-through, the proxy's own on a local refusal — and the
// body the one sent back, so the caller can keep the session registry.
func (d *Daemon) sttSessionProxy(w http.ResponseWriter, r *http.Request, base, path string, limit int64) (int, []byte) {
	body, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if err != nil {
		writeSessionErr(w, http.StatusBadRequest, fmt.Sprintf("cannot read body: %v", err))
		return http.StatusBadRequest, nil
	}
	if int64(len(body)) > limit {
		writeSessionErr(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("body exceeds %d bytes", limit))
		return http.StatusRequestEntityTooLarge, nil
	}
	req, err := http.NewRequestWithContext(r.Context(), r.Method, base+path, bytes.NewReader(body))
	if err != nil {
		writeSessionErr(w, http.StatusInternalServerError, err.Error())
		return http.StatusInternalServerError, nil
	}
	req.ContentLength = int64(len(body))
	if ct := r.Header.Get("Content-Type"); ct != "" {
		req.Header.Set("Content-Type", ct)
	}
	resp, err := sessionHTTP.Do(req)
	if err != nil {
		writeSessionErr(w, http.StatusBadGateway, fmt.Sprintf("stt server: %v", err))
		return http.StatusBadGateway, nil
	}
	out, rerr := readAllCap(resp.Body, sessionMaxResp)
	_ = resp.Body.Close()
	if rerr != nil {
		writeSessionErr(w, http.StatusBadGateway, fmt.Sprintf("stt server: %v", rerr))
		return http.StatusBadGateway, nil
	}
	d.logSegments(out, r.PathValue("id"))
	if ct := resp.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	} else {
		w.Header().Set("Content-Type", "application/json")
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(out)
	return resp.StatusCode, out
}

// sessionSegment is the slice of a session response's segment the daemon
// reports: how long it ran, why the segmenter closed it, and what the VAD
// saw while it was open. "text" is deliberately absent — the segment's
// text is the operator's dictation and must never reach the log.
type sessionSegment struct {
	S       float64 `json:"s"`
	E       float64 `json:"e"`
	Cut     string  `json:"cut"`
	MinP    float64 `json:"min_p"`
	QuietMs int64   `json:"quiet_ms"`
}

// logSegments writes one "stt segment" Info line per segment the upstream
// response carries — parsed off a copy; the body passed to the client stays
// byte-for-byte. A response without segments (create, delete, an error
// body) logs nothing. Low volume by design: one line per closed utterance.
// sessID attributes the line to its session — the first 8 id chars — so
// concurrent sessions' lines can be told apart; "" on the create route,
// whose response carries no segments.
func (d *Daemon) logSegments(body []byte, sessID string) {
	var resp struct {
		Segments []sessionSegment `json:"segments"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return
	}
	if len(sessID) > 8 {
		sessID = sessID[:8]
	}
	for _, s := range resp.Segments {
		d.log.Info("stt segment",
			slog.String("session", sessID),
			slog.Float64("dur_s", math.Round((s.E-s.S)*1000)/1000),
			slog.String("cut", s.Cut),
			slog.Float64("min_p", s.MinP),
			slog.Int64("quiet_ms", s.QuietMs))
	}
}
