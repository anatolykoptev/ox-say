package daemon

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"time"
)

// cleanRequest is the body of POST /v1/audio/clean. wet is a pointer: absent means the default 0.85, a present 0 is
// honoured (the input comes back unchanged).
type cleanRequest struct {
	InPath    string   `json:"in_path"`
	OutPath   string   `json:"out_path"`
	Wet       *float64 `json:"wet"`
	Stereo    string   `json:"stereo"`
	Overwrite bool     `json:"overwrite"`
}

// writeCleanErr answers with the daemon's error envelope plus the stable code, and the engine's reason token when
// there is one.
func writeCleanErr(w http.ResponseWriter, e *CleanError) {
	body := map[string]any{"message": e.Msg, "type": http.StatusText(e.Status), "code": e.Code}
	if e.Reason != "" {
		body["reason"] = e.Reason
	}
	if e.Status == http.StatusServiceUnavailable {
		body["reason_code"] = e.Code
	}
	writeJSON(w, e.Status, map[string]any{"error": body})
}

// handleClean is POST /v1/audio/clean. It is not an interactiveRoutes member: the producer must not yield to it, and
// dictation never waits for it. It is behind Guard like every route (cross-site refused, JSON only, loopback Host).
func (d *Daemon) handleClean(w http.ResponseWriter, r *http.Request) {
	var req cleanRequest
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil || dec.More() {
		writeErr(w, http.StatusBadRequest, "The request is not valid: send one JSON object with in_path, out_path and optionally wet, stereo and overwrite.")
		return
	}
	var extra json.RawMessage
	if err := dec.Decode(&extra); err != io.EOF { // anything after the object, however it parses
		writeErr(w, http.StatusBadRequest, "The request is not valid: send one JSON object with in_path, out_path and optionally wet, stereo and overwrite.")
		return
	}
	// A long job: the server's 30 s read and write timeouts must not cut it.
	rc := http.NewResponseController(w)
	if err := rc.SetWriteDeadline(time.Now().Add(cleanOuterCap + cleanQuietCap + time.Minute)); err != nil {
		d.log.Warn("clean: cannot extend the write deadline", slog.Any("error", err))
	}
	res, err := d.Clean(r.Context(), CleanInput{InPath: req.InPath, OutPath: req.OutPath, Wet: req.Wet,
		Stereo: req.Stereo, Overwrite: req.Overwrite})
	if err != nil {
		var ce *CleanError
		if errors.As(err, &ce) {
			if ce.Status >= 500 {
				d.log.Warn("voice cleanup failed", slog.String("code", ce.Code), slog.String("reason", ce.Reason))
			}
			writeCleanErr(w, ce)
			return
		}
		if r.Context().Err() != nil {
			return // the client left; nothing is waiting for an answer
		}
		d.log.Warn("voice cleanup failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "Voice cleanup failed. Details are in the ox-say log.")
		return
	}
	writeJSON(w, http.StatusOK, res)
}
