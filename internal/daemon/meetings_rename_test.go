package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/meeting"
)

// processedMeeting is a meeting taken through the real pipeline: transcript.md and notes.md exist.
func processedMeeting(t *testing.T, d *Daemon, title string) (meeting.Manifest, string) {
	t.Helper()
	m, dir, err := d.Meet.Store.Create(meeting.Manifest{Title: title, Labels: meeting.Labels{Me: "Me", Them: "Other"}}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	writeTone(t, filepath.Join(dir, meeting.MePCM), 30)
	if _, err := d.Meet.Finish(m.ID, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := d.Meet.Process(context.Background(), m.ID); err != nil {
		t.Fatal(err)
	}
	got, _ := d.Meet.Store.Load(m.ID)
	if got.Status != meeting.StatusDone {
		t.Fatalf("status %s", got.Status)
	}
	return *got, dir
}

func headingOf(t *testing.T, dir, name string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	line, _, _ := strings.Cut(string(raw), "\n")
	return line
}

func patchTitle(t *testing.T, mux http.Handler, id, body string) *httptest.ResponseRecorder {
	t.Helper()
	return call(t, mux, "PATCH", "/v1/meetings/"+id, body)
}

// PATCH {"title"} renames: the manifest, the heading of the transcript and of the notes, and every read of it.
// Mutation: internal/meeting/rename.go Rename, leave NotesMD out of headingFiles -> RED (the notes keep the old
// heading).
func TestPatchRenamesTheMeetingEverywhere(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	m, dir := processedMeeting(t, d, "Old name")
	rec := patchTitle(t, mux, m.ID, `{"title":"  Бюджет на квартал\n"}`)
	var got meeting.Manifest
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if rec.Code != http.StatusOK || got.Title != "Бюджет на квартал" || got.ID != m.ID || got.Status != meeting.StatusDone {
		t.Fatalf("patch = %d %s", rec.Code, rec.Body)
	}
	for _, name := range []string{meeting.TranscriptMD, meeting.NotesMD} {
		if h := headingOf(t, dir, name); !strings.HasPrefix(h, "# Бюджет на квартал — ") {
			t.Errorf("%s heading = %q", name, h)
		}
	}
	var detail meetingDetail
	_ = json.Unmarshal(call(t, mux, "GET", "/v1/meetings/"+m.ID+"?include=notes,transcript", "").Body.Bytes(), &detail)
	if detail.Title != "Бюджет на квартал" || !strings.HasPrefix(detail.NotesMD, "# Бюджет на квартал — ") || !strings.HasPrefix(detail.TranscriptMD, "# Бюджет на квартал — ") {
		t.Errorf("get after rename: %q / %.40q / %.40q", detail.Title, detail.NotesMD, detail.TranscriptMD)
	}
	var list struct {
		Meetings []meetingSummary `json:"meetings"`
	}
	_ = json.Unmarshal(call(t, mux, "GET", "/v1/meetings", "").Body.Bytes(), &list)
	if len(list.Meetings) != 1 || list.Meetings[0].Title != "Бюджет на квартал" {
		t.Errorf("list: %+v", list)
	}
}

// The create rules apply: the same caps, the same control-character cleaning, the same refusals and error shapes.
// Mutation: internal/daemon/meetings_http.go handleMeetingRename, skip the shared title check -> RED.
func TestPatchTitleHasTheCreateRules(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	m, _ := processedMeeting(t, d, "Keep")
	title := func() string { l, _ := d.Meet.Store.Load(m.ID); return l.Title }

	post := call(t, mux, "POST", "/v1/meetings", `{"title":"`+strings.Repeat("x", 201)+`"}`)
	patch := patchTitle(t, mux, m.ID, `{"title":"`+strings.Repeat("x", 201)+`"}`)
	if patch.Code != http.StatusBadRequest || patch.Body.String() != post.Body.String() {
		t.Errorf("too long: patch %d %s, create %d %s", patch.Code, patch.Body, post.Code, post.Body)
	}
	post = call(t, mux, "POST", "/v1/meetings", "{\"title\":\"a\u202eb\"}")
	patch = patchTitle(t, mux, m.ID, "{\"title\":\"a\u202eb\"}")
	if patch.Code != http.StatusBadRequest || patch.Body.String() != post.Body.String() {
		t.Errorf("bidi: patch %d %s, create %d %s", patch.Code, patch.Body, post.Code, post.Body)
	}
	for _, body := range []string{`{}`, `{"title":null}`, `{"title":"x","extra":1}`, `not json`, ``} {
		if rec := patchTitle(t, mux, m.ID, body); rec.Code != http.StatusBadRequest {
			t.Errorf("PATCH %q = %d, want 400", body, rec.Code)
		}
	}
	if title() != "Keep" {
		t.Fatalf("a refused rename changed the title to %q", title())
	}
	// 200 characters is the limit; control characters become spaces
	if rec := patchTitle(t, mux, m.ID, `{"title":"`+strings.Repeat("я", 200)+`"}`); rec.Code != http.StatusOK {
		t.Errorf("200 characters: %d %s", rec.Code, rec.Body)
	}
	if rec := patchTitle(t, mux, m.ID, `{"title":"Pl\u0000an\n2"}`); rec.Code != http.StatusOK || title() != "Pl an 2" {
		t.Errorf("control characters: %d, title %q", rec.Code, title())
	}
	if rec := patchTitle(t, mux, m.ID, `{"title":""}`); rec.Code != http.StatusOK || title() != "" {
		t.Errorf("empty title: %d, %q", rec.Code, title())
	}
}

// 404 for an id nobody has; 409, in plain words, while the meeting is being recorded or processed.
func TestPatchTitleUnknownAndBusyMeetings(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	if rec := patchTitle(t, mux, "20260101-000000-abcdef", `{"title":"x"}`); rec.Code != http.StatusNotFound {
		t.Errorf("unknown: %d %s", rec.Code, rec.Body)
	}
	m, _, _ := d.Meet.Store.Create(meeting.Manifest{Title: "Live"}, time.Now())
	rec := patchTitle(t, mux, m.ID, `{"title":"x"}`)
	if rec.Code != http.StatusConflict || strings.Contains(rec.Body.String(), m.ID) {
		t.Errorf("recording: %d %s", rec.Code, rec.Body)
	}
	if l, _ := d.Meet.Store.Load(m.ID); l.Title != "Live" {
		t.Errorf("title changed to %q", l.Title)
	}
}

// The app's calls pass the guard exactly as they are sent: loopback Host, JSON body, no Origin.
func TestSearchRenameAndAudioPassTheGuard(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	h := servedFor(t, d)
	m, _ := processedMeeting(t, d, "Guard")
	if rec := serve(h, appRequest("PATCH", "/v1/meetings/"+m.ID, `{"title":"Через guard"}`)); rec.Code != http.StatusOK {
		t.Errorf("PATCH = %d %s", rec.Code, rec.Body)
	}
	if rec := serve(h, appRequest("GET", "/v1/meetings/search?q=guard", "")); rec.Code != http.StatusOK {
		t.Errorf("search = %d %s", rec.Code, rec.Body)
	}
}
