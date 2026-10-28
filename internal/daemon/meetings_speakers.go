package daemon

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/anatolykoptev/ox-say/internal/meeting"
)

func (d *Daemon) speakersRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/meetings/{id}/speakers", d.handleSpeakersGet)
	mux.HandleFunc("PATCH /v1/meetings/{id}/speakers", d.handleSpeakersEdit)
	mux.HandleFunc("POST /v1/meetings/{id}/voices", d.handleVoicesRetry)
}

// handleVoicesRetry tells the far side's voices apart again for a meeting where the diarizer broke: a full
// transcription (meeting.Runner.RetryVoices), so it is its own route, not part of the notes retry.
func (d *Daemon) handleVoicesRetry(w http.ResponseWriter, r *http.Request) {
	m, err := d.Meet.RetryVoices(r.PathValue("id"))
	var notReady *meeting.ErrVoicesNotReady
	if errors.As(err, &notReady) {
		// The models or engine are still missing at this moment (the app's check was stale): 503, not the 409 of "busy",
		// with a stable code and the reason so the app says so in its own words.
		d.log.Debug("voices retry refused", slog.String("reason", notReady.Reason))
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{
			"message": "Voices cannot be told apart yet: the voice engine or its models are not ready.",
			"type":    http.StatusText(http.StatusServiceUnavailable), "code": "voices_not_ready", "reason": notReady.Reason,
		}})
		return
	}
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, d.publicManifest(*m))
}

func (d *Daemon) handleSpeakersGet(w http.ResponseWriter, r *http.Request) {
	v, err := d.Meet.Speakers(r.PathValue("id"))
	if d.writeSpeakersErr(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, v)
}

// handleSpeakersEdit changes names, merges and the split in one request; the daemon writes the transcript
// again and queues the notes (meeting.Runner.EditSpeakers).
func (d *Daemon) handleSpeakersEdit(w http.ResponseWriter, r *http.Request) {
	var e meeting.Edit
	if err := decodeStrict(r, &e); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	v, err := d.Meet.EditSpeakers(r.PathValue("id"), e)
	if d.writeSpeakersErr(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, v)
}

// writeSpeakersErr answers err and reports whether there was one.
func (d *Daemon) writeSpeakersErr(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, meeting.ErrSpeakers):
		writeErr(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, meeting.ErrSpeakersBusy):
		writeErr(w, http.StatusConflict, "this meeting is still being processed; name the speakers when it is done")
	default:
		d.writeMeetingErr(w, err)
	}
	return true
}
