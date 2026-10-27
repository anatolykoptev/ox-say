package daemon

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/meeting"
)

const (
	maxTitleChars   = 200
	maxLabelChars   = 80
	maxSourceChars  = 40
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
	d.speakersRoutes(mux)
}

// meetingRetryRefusals are the runner's wordings for "the meeting's own state
// refuses this request". They map to 409 and are answered in the plain words
// listed here, because the raw error names the internal meeting id.
var meetingRetryRefusals = []struct{ match, text string }{
	{"cannot be retried while", "This meeting is still being processed; retry it when it is done."},
	{"no transcript and its audio is gone", "This meeting cannot be retried: there is no transcript and its audio is gone."},
	{"has no failed diarization to retry", "This meeting has no voice problem to retry, or its audio is gone."},
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
	title, source := cleanText(in.Title), cleanText(in.Source)
	me, them, speaker := cleanText(in.Labels.Me), cleanText(in.Labels.Them), cleanText(in.Labels.Speaker)
	for _, f := range []struct {
		name, text string
		max        int
	}{{"title", title, maxTitleChars}, {"source", source, maxSourceChars}, {"labels.me", me, maxLabelChars}, {"labels.them", them, maxLabelChars}, {"labels.speaker", speaker, maxLabelChars}} {
		if utf8.RuneCountInString(f.text) > f.max {
			writeErr(w, http.StatusBadRequest, f.name+" is too long")
			return
		}
		if meeting.HasBidiControl(f.text) {
			writeErr(w, http.StatusBadRequest, f.name+" holds a text-direction control character")
			return
		}
	}
	if me == "" {
		me = defaultMeLabel
	}
	if them == "" {
		them = defaultThemName
	}
	m, dir, err := d.Meet.Store.Create(meeting.Manifest{
		Title: title, Source: source, Labels: meeting.Labels{Me: me, Them: them, Speaker: speaker}, EchoRisk: in.EchoRisk,
	}, time.Now())
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, createMeetingResponse{Manifest: d.publicManifest(m), Dir: dir})
}

// cleanText is a caller-chosen name (title, label, source) with every control
// character — newline, tab, escape, NUL — turned into a space, and the ends
// trimmed. These texts end up in markdown files and in a model prompt, where
// a line break would start a new line of someone else's choosing.
func cleanText(s string) string {
	return strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, s))
}

// publicManifest is m as it is served: the stored Error is the raw text of a
// failed run and can name an absolute path (the home directory, a model
// file), so it is cleaned here, where every route and tool that serves a
// manifest passes, not where the runner stores it — meetings already on disk
// carry the raw text too, and the stored text stays whole for the log.
func (d *Daemon) publicManifest(m meeting.Manifest) meeting.Manifest {
	if m.Error != "" {
		m.Error = publicMessage(errors.New(m.Error), d.Cfg.Home)
	}
	return m
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
	Voices       int            `json:"voices,omitempty"`
	VoiceMode    string         `json:"voice_mode,omitempty"`
	DiarReason   string         `json:"diar_reason,omitempty"`
	// AudioDeleted: retention removed the recording, so a voices retry (which transcribes it again) cannot run.
	AudioDeleted bool `json:"audio_deleted,omitempty"`
}

func (d *Daemon) summarize(m meeting.Manifest) meetingSummary {
	m = d.publicManifest(m)
	return meetingSummary{
		ID: m.ID, Title: m.Title, Started: m.Started, DurationS: m.DurationS, Status: m.Status,
		Language: m.Language, HasNotes: m.Status == meeting.StatusDone, NotesPending: m.NotesPending,
		Warnings: m.Warnings, Error: m.Error, Voices: m.Voices, VoiceMode: m.VoiceMode, DiarReason: m.DiarReason, AudioDeleted: m.AudioDeleted,
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
		out = append(out, d.summarize(m))
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
	out := meetingDetail{Manifest: d.publicManifest(*m)}
	include := includeSet(r.URL.Query().Get("include"))
	if include["notes"] {
		if out.NotesMD, err = d.Meet.Store.Text(m.ID, meeting.NotesMD); err != nil {
			d.writeMeetingErr(w, err)
			return
		}
	}
	if include["transcript"] {
		if out.TranscriptMD, err = d.Meet.Store.Text(m.ID, meeting.TranscriptMD); err != nil {
			d.writeMeetingErr(w, err)
			return
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// includeSet is the names in a comma-separated ?include= value.
func includeSet(q string) map[string]bool {
	set := map[string]bool{}
	for _, name := range strings.Split(q, ",") {
		set[strings.TrimSpace(name)] = true
	}
	return set
}

func (d *Daemon) handleMeetingFinish(w http.ResponseWriter, r *http.Request) {
	m, err := d.Meet.Finish(r.PathValue("id"), time.Now())
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, d.publicManifest(*m))
}

func (d *Daemon) handleMeetingNotes(w http.ResponseWriter, r *http.Request) {
	m, err := d.Meet.Retry(r.PathValue("id"))
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, d.publicManifest(*m))
}

// errDeleteRefused is a meeting whose state forbids deleting it; the text is
// the plain-words answer.
type errDeleteRefused string

func (e errDeleteRefused) Error() string { return string(e) }

// handleMeetingDelete removes a meeting that nothing is working on. The state
// check and the removal are one step under the store lock: the runner's
// status changes take the same lock, so a meeting cannot be queued between
// the check and the removal.
func (d *Daemon) handleMeetingDelete(w http.ResponseWriter, r *http.Request) {
	err := d.Meet.Store.DeleteIf(r.PathValue("id"), func(m meeting.Manifest) error {
		switch m.Status {
		case meeting.StatusRecording:
			return errDeleteRefused("this meeting is still recording; finish it before deleting")
		case meeting.StatusQueued, meeting.StatusTranscribing, meeting.StatusSummarizing:
			return errDeleteRefused("this meeting is still being processed; delete it when it is done")
		}
		return nil
	})
	var refused errDeleteRefused
	if errors.As(err, &refused) {
		writeErr(w, http.StatusConflict, refused.Error())
		return
	}
	if err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (d *Daemon) handleMeetingSettings(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, d.Meet.Store.Settings())
}

func (d *Daemon) handleMeetingSettingsSet(w http.ResponseWriter, r *http.Request) {
	// A pointer: an absent field must not read as 0, which is "never delete".
	var in struct {
		RetentionDays *int `json:"retention_days"`
	}
	if err := decodeStrict(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if in.RetentionDays == nil {
		writeErr(w, http.StatusBadRequest, "retention_days is required")
		return
	}
	if err := d.Meet.Store.SetSettings(meeting.Settings{RetentionDays: *in.RetentionDays}); err != nil {
		if errors.Is(err, os.ErrInvalid) {
			writeErr(w, http.StatusBadRequest, "retention_days must be one of 0, 7, 30, 90")
			return
		}
		d.writeMeetingErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, d.Meet.Store.Settings())
}

func (d *Daemon) handleNotesModelInstall(w http.ResponseWriter, _ *http.Request) {
	if err := d.InstallNotesModel(); err != nil {
		d.writeMeetingErr(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, d.notesStatus())
}
