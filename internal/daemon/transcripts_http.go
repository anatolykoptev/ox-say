package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"path/filepath"

	"github.com/anatolykoptev/ox-say/internal/stt"
	"github.com/anatolykoptev/ox-say/internal/transcripts"
)

// transcriptFields are the multipart fields POST /v1/transcripts reads: the
// transcription route's, plus a title.
var transcriptFields = map[string]bool{"model": true, "language": true, "prompt": true, "title": true}

// transcriptFormats are the ?format= values GET /v1/transcripts/{id} serves.
var transcriptFormats = map[string]bool{"text": true, "srt": true, "vtt": true, "json": true, "ox_json": true}

const msgTranscriptsUnavailable = "transcripts are unavailable: the store could not be opened"

// initTranscripts opens $OX_SAY_HOME/transcripts. A directory that cannot be
// opened is logged and leaves d.Transcripts nil: dictation and everything else
// keep working, and the transcript routes answer 503.
func (d *Daemon) initTranscripts() {
	s, err := transcripts.New(filepath.Join(d.Cfg.Home, "transcripts"))
	if err != nil {
		d.log.Warn("transcripts: store unavailable", slog.Any("error", err))
		return
	}
	s.Log = d.log
	d.Transcripts = s
}

// transcriptRoutes registers the transcripts store. POST is deliberately not an
// interactiveRoutes member: a long file must not make the voiceover producer
// yield as if someone were dictating. It shares d.Transcribe, and so the STT
// queue, with every other transcription.
func (d *Daemon) transcriptRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/transcripts", d.handleTranscriptCreate)
	mux.HandleFunc("GET /v1/transcripts", d.handleTranscriptList)
	mux.HandleFunc("GET /v1/transcripts/{id}", d.handleTranscriptGet)
	mux.HandleFunc("DELETE /v1/transcripts/{id}", d.handleTranscriptDelete)
}

// writeTranscriptErr answers a store error in plain words: no path, no
// transcript text. The raw error goes to the log.
func (d *Daemon) writeTranscriptErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, transcripts.ErrInvalidID):
		writeErr(w, http.StatusBadRequest, "invalid transcript id")
	case errors.Is(err, transcripts.ErrNotFound):
		writeErr(w, http.StatusNotFound, "no such transcript")
	default:
		d.log.Warn("transcripts: request failed", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, publicMessage(err, d.Cfg.Home))
	}
}

func (d *Daemon) handleTranscriptCreate(w http.ResponseWriter, r *http.Request) {
	if d.Transcripts == nil {
		writeErr(w, http.StatusServiceUnavailable, msgTranscriptsUnavailable)
		return
	}
	tmp, fields, cleanup, err := d.receiveUpload(w, r, transcriptFields)
	if err != nil {
		return
	}
	defer cleanup()

	title := cleanText(fields["title"])
	if msg := checkText("title", title, maxTitleChars); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	eng, err := engineFor(fields["model"])
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	res, err := d.Transcribe(r.Context(), TranscribeInput{
		AudioPath: tmp,
		Engine:    eng,
		Language:  fields["language"],
		Prompt:    fields["prompt"],
	})
	if err != nil {
		// nothing is stored for a failed transcription
		writeErr(w, transcribeStatus(err), err.Error())
		return
	}
	ox, err := json.Marshal(res)
	if err != nil {
		d.writeTranscriptErr(w, err)
		return
	}
	m := transcripts.Meta{Title: title, Engine: res.Engine, Seconds: res.DurationS}
	if res.Language != nil {
		m.Language = *res.Language
	}
	m, err = d.Transcripts.Put(m, ox)
	if err != nil {
		d.writeTranscriptErr(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, m)
}

func (d *Daemon) handleTranscriptList(w http.ResponseWriter, _ *http.Request) {
	if d.Transcripts == nil {
		writeErr(w, http.StatusServiceUnavailable, msgTranscriptsUnavailable)
		return
	}
	list, err := d.Transcripts.List(0)
	if err != nil {
		d.writeTranscriptErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"transcripts": list})
}

func (d *Daemon) handleTranscriptGet(w http.ResponseWriter, r *http.Request) {
	if d.Transcripts == nil {
		writeErr(w, http.StatusServiceUnavailable, msgTranscriptsUnavailable)
		return
	}
	format := r.URL.Query().Get("format")
	if format == "" {
		format = "json"
	}
	if !transcriptFormats[format] {
		writeErr(w, http.StatusBadRequest, fmt.Sprintf("unsupported format %q (want text|srt|vtt|json|ox_json)", format))
		return
	}
	_, ox, err := d.Transcripts.Get(r.PathValue("id"))
	if err != nil {
		d.writeTranscriptErr(w, err)
		return
	}
	var res stt.Result
	if err := json.Unmarshal(ox, &res); err != nil {
		d.log.Warn("transcripts: stored document is unreadable", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "the stored transcript is unreadable")
		return
	}
	writeTranscription(w, &res, format)
}

func (d *Daemon) handleTranscriptDelete(w http.ResponseWriter, r *http.Request) {
	if d.Transcripts == nil {
		writeErr(w, http.StatusServiceUnavailable, msgTranscriptsUnavailable)
		return
	}
	if err := d.Transcripts.Delete(r.PathValue("id")); err != nil {
		d.writeTranscriptErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
