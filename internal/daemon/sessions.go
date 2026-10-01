package daemon

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"regexp"
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
	d.sttSessionProxy(w, r, base, "/sessions", sessionMaxJSON)
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
	d.sttSessionProxy(w, r, base, up, limit)
}

// sttSessionProxy reads the request body under its cap, forwards it to the
// STT server at base+path, and copies the upstream status and JSON body
// back. The caller holds the guard; the request context carries the call.
func (d *Daemon) sttSessionProxy(w http.ResponseWriter, r *http.Request, base, path string, limit int64) {
	body, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if err != nil {
		writeSessionErr(w, http.StatusBadRequest, fmt.Sprintf("cannot read body: %v", err))
		return
	}
	if int64(len(body)) > limit {
		writeSessionErr(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("body exceeds %d bytes", limit))
		return
	}
	req, err := http.NewRequestWithContext(r.Context(), r.Method, base+path, bytes.NewReader(body))
	if err != nil {
		writeSessionErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	req.ContentLength = int64(len(body))
	if ct := r.Header.Get("Content-Type"); ct != "" {
		req.Header.Set("Content-Type", ct)
	}
	resp, err := sessionHTTP.Do(req)
	if err != nil {
		writeSessionErr(w, http.StatusBadGateway, fmt.Sprintf("stt server: %v", err))
		return
	}
	out, rerr := readAllCap(resp.Body, sessionMaxResp)
	_ = resp.Body.Close()
	if rerr != nil {
		writeSessionErr(w, http.StatusBadGateway, fmt.Sprintf("stt server: %v", rerr))
		return
	}
	d.logSegments(out)
	if ct := resp.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	} else {
		w.Header().Set("Content-Type", "application/json")
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(out)
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
func (d *Daemon) logSegments(body []byte) {
	var resp struct {
		Segments []sessionSegment `json:"segments"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return
	}
	for _, s := range resp.Segments {
		d.log.Info("stt segment",
			slog.Float64("dur_s", s.E-s.S),
			slog.String("cut", s.Cut),
			slog.Float64("min_p", s.MinP),
			slog.Int64("quiet_ms", s.QuietMs))
	}
}
