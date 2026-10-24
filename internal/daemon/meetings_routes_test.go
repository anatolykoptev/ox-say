package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/meeting"
)

func TestMeetingHTTPJourney(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	rec := call(t, mux, "POST", "/v1/meetings", `{"title":"Plan","labels":{"me":"Anatoly","them":"Other"},"echo_risk":false}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create = %d %s", rec.Code, rec.Body)
	}
	var created createMeetingResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	if created.Dir == "" || created.Status != meeting.StatusRecording {
		t.Fatalf("created = %+v", created)
	}
	writeTone(t, filepath.Join(created.Dir, meeting.MePCM), 30)
	writeTone(t, filepath.Join(created.Dir, meeting.ThemPCM), 30)

	if rec := call(t, mux, "POST", "/v1/meetings/"+created.ID+"/finish", ""); rec.Code != http.StatusAccepted {
		t.Fatalf("finish = %d %s", rec.Code, rec.Body)
	}
	if err := d.Meet.Process(context.Background(), created.ID); err != nil {
		t.Fatal(err)
	}
	rec = call(t, mux, "GET", "/v1/meetings/"+created.ID+"?include=notes,transcript", "")
	var got meetingDetail
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if got.Status != meeting.StatusDone || !strings.Contains(got.NotesMD, "- [ ] Me — send the plan — Friday") ||
		!strings.Contains(got.TranscriptMD, "**Anatoly**") {
		t.Fatalf("meeting = %+v", got)
	}
	if rec := call(t, mux, "GET", "/v1/meetings/nope", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("unknown id = %d", rec.Code)
	}
	if rec := call(t, mux, "DELETE", "/v1/meetings/"+created.ID, ""); rec.Code != http.StatusNoContent {
		t.Fatalf("delete = %d", rec.Code)
	}
}

func TestMeetingCreateDefaultsLabelsAndRejectsUnknownFields(t *testing.T) {
	_, mux := meetingFixture(t, nil)
	rec := call(t, mux, "POST", "/v1/meetings", `{}`)
	var m createMeetingResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &m)
	if rec.Code != http.StatusCreated || m.Labels.Me != "Me" || m.Labels.Them != "Other" {
		t.Fatalf("create {} = %d %+v", rec.Code, m)
	}
	if rec := call(t, mux, "POST", "/v1/meetings", `{"nonsense":1}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("unknown field = %d, want 400", rec.Code)
	}
}

// A meeting still in the queue or being worked on cannot be deleted.
// Mutation: internal/daemon/meetings_http.go handleMeetingDelete, change the
// case list to `case "x":` -> RED (a queued meeting is deleted mid-work).
func TestMeetingDeleteRefusedWhileProcessing(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	m, _, _ := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	_, _ = d.Meet.Finish(m.ID, time.Now())
	if rec := call(t, mux, "DELETE", "/v1/meetings/"+m.ID, ""); rec.Code != http.StatusConflict {
		t.Fatalf("delete while queued = %d, want 409", rec.Code)
	}
}

// The retention choices are the app's four picker values; anything else is
// refused, never rounded to the nearest choice.
// Mutation: internal/daemon/meetings_http.go handleMeetingSettingsSet, drop
// the SetSettings error mapping to 400 -> RED (a 1-day retention is stored
// and silently deletes audio a month early... or never).
func TestMeetingSettingsRoundTripAndValidation(t *testing.T) {
	_, mux := meetingFixture(t, nil)
	if rec := call(t, mux, "PUT", "/v1/meetings/settings", `{"retention_days":90}`); rec.Code != http.StatusOK {
		t.Fatalf("put = %d %s", rec.Code, rec.Body)
	}
	var got meeting.Settings
	_ = json.Unmarshal(call(t, mux, "GET", "/v1/meetings/settings", "").Body.Bytes(), &got)
	if got.RetentionDays != 90 {
		t.Fatalf("settings = %+v", got)
	}
	for _, bad := range []string{`{"retention_days":-1}`, `{"retention_days":99999}`, `{"retention_days":31}`, `{"days":1}`} {
		if rec := call(t, mux, "PUT", "/v1/meetings/settings", bad); rec.Code != http.StatusBadRequest {
			t.Errorf("PUT %s = %d, want 400", bad, rec.Code)
		}
	}
}

// A retry the runner refuses is answered in plain words — never the raw
// error, which names the internal meeting id.
// Mutation: internal/daemon/meetings_http.go meetingErrText, delete the
// refusal cases -> RED (the id leaks into the app's error text).
func TestMeetingNotesRefusalIsPlainWords(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	m, _, _ := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	if _, err := d.Meet.Store.Update(m.ID, func(mm *meeting.Manifest) {
		mm.Status, mm.AudioDeleted = meeting.StatusFailed, true
	}); err != nil {
		t.Fatal(err)
	}
	rec := call(t, mux, "POST", "/v1/meetings/"+m.ID+"/notes", "")
	if rec.Code != http.StatusConflict {
		t.Fatalf("retry without transcript or audio = %d %s, want 409", rec.Code, rec.Body)
	}
	var body struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if strings.Contains(body.Error.Message, m.ID) {
		t.Fatalf("the error names the internal id: %q", body.Error.Message)
	}
	if !strings.Contains(body.Error.Message, "transcript") || !strings.Contains(body.Error.Message, "audio") {
		t.Fatalf("the refusal is not in plain words: %q", body.Error.Message)
	}
}

// The app's MeetingClient decodes these exact field names: create answers
// id/dir/status; a list item carries status and has_notes and never the
// texts; a detail carries notes_md/transcript_md only when asked; settings
// is retention_days; an install answer is the notesStatus shape.
// Mutation: internal/daemon/meetings_http.go createMeetingResponse, rename
// the `dir` json tag -> RED (createMeeting decodes info.dir = nil).
func TestMeetingJSONMatchesTheAppContract(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	obj := func(rec *httptest.ResponseRecorder) map[string]any {
		t.Helper()
		var m map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
			t.Fatalf("not a JSON object: %v (%s)", err, rec.Body)
		}
		return m
	}

	rec := call(t, mux, "POST", "/v1/meetings", `{"title":"Plan"}`)
	created := obj(rec)
	for _, k := range []string{"id", "dir", "title", "started", "status", "labels"} {
		if _, ok := created[k]; !ok {
			t.Fatalf("create answer lacks %q: %v", k, created)
		}
	}
	id, _ := created["id"].(string)
	writeTone(t, filepath.Join(created["dir"].(string), meeting.MePCM), 30)
	if rec := call(t, mux, "POST", "/v1/meetings/"+id+"/finish", ""); rec.Code != http.StatusAccepted {
		t.Fatalf("finish = %d", rec.Code)
	}
	if err := d.Meet.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}

	list := obj(call(t, mux, "GET", "/v1/meetings", ""))
	items, _ := list["meetings"].([]any)
	if len(items) != 1 {
		t.Fatalf("meetings = %v", list)
	}
	item, _ := items[0].(map[string]any)
	for _, k := range []string{"id", "title", "started", "status", "has_notes"} {
		if _, ok := item[k]; !ok {
			t.Fatalf("list item lacks %q: %v", k, item)
		}
	}
	if item["status"] != "done" || item["has_notes"] != true {
		t.Fatalf("list item = %v", item)
	}
	for _, k := range []string{"notes_md", "transcript_md"} {
		if _, ok := item[k]; ok {
			t.Fatalf("the list carries %q — the texts belong to meeting_get only", k)
		}
	}

	bare := obj(call(t, mux, "GET", "/v1/meetings/"+id, ""))
	for _, k := range []string{"notes_md", "transcript_md"} {
		if _, ok := bare[k]; ok {
			t.Fatalf("the detail without include carries %q", k)
		}
	}
	full := obj(call(t, mux, "GET", "/v1/meetings/"+id+"?include=notes,transcript", ""))
	for _, k := range []string{"id", "status", "notes_md", "transcript_md"} {
		if _, ok := full[k]; !ok {
			t.Fatalf("the detail lacks %q: %v", k, full)
		}
	}

	st := obj(call(t, mux, "GET", "/v1/meetings/settings", ""))
	if _, ok := st["retention_days"]; !ok {
		t.Fatalf("settings = %v", st)
	}
}

func TestMeetingMCPTools(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	m, dir, _ := d.Meet.Store.Create(meeting.Manifest{Title: "Plan", Labels: meeting.Labels{Me: "A", Them: "B"}}, time.Now())
	writeTone(t, filepath.Join(dir, meeting.MePCM), 30)
	_, _ = d.Meet.Finish(m.ID, time.Now())
	if err := d.Meet.Process(context.Background(), m.ID); err != nil {
		t.Fatal(err)
	}
	cs := mcpSession(t, d)
	list := callMCP(t, cs, "meetings_list", nil)
	meetings, _ := list["meetings"].([]any)
	if len(meetings) != 1 || meetings[0].(map[string]any)["has_notes"] != true {
		t.Fatalf("meetings_list = %v", list)
	}
	got := callMCP(t, cs, "meeting_get", map[string]any{"id": m.ID, "part": "both"})
	if !strings.Contains(got["notes_md"].(string), "Ship Friday") || !strings.Contains(got["transcript_md"].(string), "**A**") {
		t.Fatalf("meeting_get = %v", got)
	}
}

func TestPagePagesByCharacters(t *testing.T) {
	text := strings.Repeat("ж", 25)
	p1, next, _ := page(text, 0, 10)
	p2, next2, _ := page(text, next, 10)
	p3, next3, _ := page(text, next2, 10)
	if len([]rune(p1)) != 10 || len([]rune(p2)) != 10 || len([]rune(p3)) != 5 || next3 != 0 || p1+p2+p3 != text {
		t.Fatalf("pages = %d %d %d next %d", len([]rune(p1)), len([]rune(p2)), len([]rune(p3)), next3)
	}
}
