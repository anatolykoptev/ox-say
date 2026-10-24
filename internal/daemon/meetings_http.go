package daemon

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/meeting"
)

const (
	maxTitleChars   = 200
	defaultMeLabel  = "Me"
	defaultThemName = "Other"
)

func (d *Daemon) meetingRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/meetings", d.handleMeetingCreate)
	mux.HandleFunc("GET /v1/meetings", d.handleMeetingList)
	mux.HandleFunc("GET /v1/meetings/settings", d.handleMeetingSettings)
	mux.HandleFunc("PUT /v1/meetings/settings", d.handleMeetingSettingsSet)
	mux.HandleFunc("GET /v1/meetings/{id}", d.handleMeetingGet)
	mux.HandleFunc("POST /v1/meetings/{id}/finish", d.handleMeetingFinish)
	mux.HandleFunc("POST /v1/meetings/{id}/notes", d.handleMeetingNotes)
	mux.HandleFunc("DELETE /v1/meetings/{id}", d.handleMeetingDelete)
	mux.HandleFunc("POST /v1/meetings/notes-model/install", d.handleNotesModelInstall)
}

// meetingRetryRefusals are the runner's wordings for "the meeting's own state
// refuses this request". They map to 409 and are answered in the plain words
// listed here, because the raw error names the internal meeting id.
var meetingRetryRefusals = []struct{ match, text string }{
	{"cannot be retried while", "This meeting is still being processed; retry it when it is done."},
	{"no transcript and its audio is gone", "This meeting cannot be retried: there is no transcript and its audio is gone."},
}

// meetingErrText is a meeting error in plain words: no internal meeting id
// and no absolute path — those stay in the log (see writeMeetingErr).
func (d *Daemon) meetingErrText(err error) string {
	switch {
	case errors.Is(err, meeting.ErrNotFound):
		return "no such meeting"
	case errors.Is(err, ErrNotesInstall):
		// The refusal's plain reason follows the sentinel: "notes model
		// download: <reason>".
		return strings.TrimPrefix(err.Error(), ErrNotesInstall.Error()+": ")
	}
	for _, r := range meetingRetryRefusals {
		if strings.Contains(err.Error(), r.match) {
			return r.text
		}
	}
	return publicMessage(err, d.Cfg.Home)
}

// writeMeetingErr answers a meeting error: 404 when the id is unknown, 409
// when the meeting's state refuses the request or the install cannot start,
// else 500. The text never carries a transcript, an internal id or an
// absolute path.
func (d *Daemon) writeMeetingErr(w http.ResponseWriter, err error) {
	code := http.StatusInternalServerError
	switch {
	case errors.Is(err, meeting.ErrNotFound):
		code = http.StatusNotFound
	case errors.Is(err, ErrNotesInstall):
		code = http.StatusConflict
	default:
		for _, r := range meetingRetryRefusals {
			if strings.Contains(err.Error(), r.match) {
				code = http.StatusConflict
				break
			}
		}
	}
	level := slog.LevelDebug
	if code >= http.StatusInternalServerError {
		level = slog.LevelWarn
	}
	d.log.Log(context.Background(), level, "meeting request failed", slog.Int("status", code), slog.Any("error", err))
	writeErr(w, code, d.meetingErrText(err))
}

type createMeetingRequest struct {
	Title    string         `json:"title"`
	Source   string         `json:"source"`
	Labels   meeting.Labels `json:"labels"`
	EchoRisk bool           `json:"echo_risk"`
}

// createMeetingResponse is the manifest plus the directory the app writes
// me.pcm and them.pcm into.
type createMeetingResponse struct {
	meeting.Manifest
	Dir string `json:"dir"`
}

func (d *Daemon) handleMeetingCreate(w http.ResponseWriter, r *http.Request) {
	var in createMeetingRequest
	if err := decodeStrict(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if utf8.RuneCountInString(in.Title) > maxTitleChars {
		writeErr(w, http.StatusBadRequest, "title is too long")
		return
	}
	if strings.TrimSpace(in.Labels.Me) == "" {
		in.Labels.Me = defaultMeLabel
	}
	if strings.TrimSpace(in.Labels.Them) == "" {
		in.Labels.Them = defaultThemName
	}
	m, dir, err := d.Meet.Store.Create(meeting.Manifest{
		Title: strings.TrimSpace(in.Title), Source: in.Source, Labels: in.Labels, EchoRisk: in.EchoRisk,
	}, time.Now())
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, createMeetingResponse{Manifest: m, Dir: dir})
}

// meetingSummary is a meeting in a list: everything the app shows at a
// glance, and none of the texts (they belong to meeting_get and the detail).
type meetingSummary struct {
	ID           string         `json:"id"`
	Title        string         `json:"title,omitempty"`
	Started      time.Time      `json:"started"`
	DurationS    float64        `json:"duration_s,omitempty"`
	Status       meeting.Status `json:"status"`
	Language     string         `json:"language,omitempty"`
	HasNotes     bool           `json:"has_notes"`
	NotesPending string         `json:"notes_pending,omitempty"`
	Warnings     []string       `json:"warnings,omitempty"`
	Error        string         `json:"error,omitempty"`
}

func summarize(m meeting.Manifest) meetingSummary {
	return meetingSummary{
		ID: m.ID, Title: m.Title, Started: m.Started, DurationS: m.DurationS, Status: m.Status,
		Language: m.Language, HasNotes: m.Status == meeting.StatusDone, NotesPending: m.NotesPending,
		Warnings: m.Warnings, Error: m.Error,
	}
}

func (d *Daemon) handleMeetingList(w http.ResponseWriter, _ *http.Request) {
	list, err := d.Meet.Store.List()
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	out := make([]meetingSummary, 0, len(list))
	for _, m := range list {
		out = append(out, summarize(m))
	}
	writeJSON(w, http.StatusOK, map[string]any{"meetings": out})
}

// meetingDetail is one meeting with the texts the caller asked for.
type meetingDetail struct {
	meeting.Manifest
	NotesMD      string `json:"notes_md,omitempty"`
	TranscriptMD string `json:"transcript_md,omitempty"`
}

func (d *Daemon) handleMeetingGet(w http.ResponseWriter, r *http.Request) {
	m, err := d.Meet.Store.Load(r.PathValue("id"))
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	out := meetingDetail{Manifest: *m}
	include := r.URL.Query().Get("include")
	if strings.Contains(include, "notes") {
		out.NotesMD, _ = d.Meet.Store.Text(m.ID, meeting.NotesMD)
	}
	if strings.Contains(include, "transcript") {
		out.TranscriptMD, _ = d.Meet.Store.Text(m.ID, meeting.TranscriptMD)
	}
	writeJSON(w, http.StatusOK, out)
}

func (d *Daemon) handleMeetingFinish(w http.ResponseWriter, r *http.Request) {
	m, err := d.Meet.Finish(r.PathValue("id"), time.Now())
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, m)
}

func (d *Daemon) handleMeetingNotes(w http.ResponseWriter, r *http.Request) {
	m, err := d.Meet.Retry(r.PathValue("id"))
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, m)
}

func (d *Daemon) handleMeetingDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	m, err := d.Meet.Store.Load(id)
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	switch m.Status {
	case meeting.StatusQueued, meeting.StatusTranscribing, meeting.StatusSummarizing:
		writeErr(w, http.StatusConflict, "this meeting is still being processed; delete it when it is done")
		return
	}
	if err := d.Meet.Store.Delete(id); err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (d *Daemon) handleMeetingSettings(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, d.Meet.Store.Settings())
}

func (d *Daemon) handleMeetingSettingsSet(w http.ResponseWriter, r *http.Request) {
	var in meeting.Settings
	if err := decodeStrict(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := d.Meet.Store.SetSettings(in); err != nil {
		if errors.Is(err, os.ErrInvalid) {
			writeErr(w, http.StatusBadRequest, "retention_days must be one of 0, 7, 30, 90")
			return
		}
		d.writeMeetingErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, in)
}

func (d *Daemon) handleNotesModelInstall(w http.ResponseWriter, _ *http.Request) {
	if err := d.InstallNotesModel(); err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, d.notesStatus())
}
