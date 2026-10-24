package daemon

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func putRetention(t *testing.T, mux http.Handler, body string) *httptest.ResponseRecorder {
	t.Helper()
	return call(t, mux, "PUT", "/v1/meetings/settings", body)
}

func storedRetention(t *testing.T, d *Daemon) int {
	t.Helper()
	st, err := d.Meet.Store.LoadSettings()
	if err != nil {
		t.Fatal(err)
	}
	return st.RetentionDays
}

// An empty or field-less PUT must not zero the retention ("never delete").
// Mutation: internal/daemon/meetings_http.go handleMeetingSettingsSet, decode
// into meeting.Settings (value, not *int) again -> RED.
func TestSettingsPutWithoutRetentionIsRefusedAndChangesNothing(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	if rec := putRetention(t, mux, `{"retention_days":90}`); rec.Code != http.StatusOK {
		t.Fatalf("put 90 = %d", rec.Code)
	}
	for _, body := range []string{`{}`, ``, `{"retention_days":null}`} {
		if rec := putRetention(t, mux, body); rec.Code != http.StatusBadRequest {
			t.Errorf("PUT %q = %d %s, want 400", body, rec.Code, rec.Body)
		}
		if got := storedRetention(t, d); got != 90 {
			t.Fatalf("after PUT %q retention = %d, want 90 (unchanged)", body, got)
		}
	}
	// An explicit 0 is the user's "never" and still works; the answer is the stored value.
	rec := putRetention(t, mux, `{"retention_days":0}`)
	var echoed meeting.Settings
	_ = json.Unmarshal(rec.Body.Bytes(), &echoed)
	if rec.Code != http.StatusOK || echoed.RetentionDays != 0 || storedRetention(t, d) != 0 {
		t.Fatalf("explicit 0 = %d %s", rec.Code, rec.Body)
	}
}

// A recording meeting is deleted by no route either: its app is still writing.
// Mutation: internal/daemon/meetings_http.go handleMeetingDelete, drop
// meeting.StatusRecording from the refused case -> RED.
func TestMeetingDeleteRefusedWhileRecording(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	m, dir, _ := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	rec := call(t, mux, "DELETE", "/v1/meetings/"+m.ID, "")
	if rec.Code != http.StatusConflict {
		t.Fatalf("delete while recording = %d %s, want 409", rec.Code, rec.Body)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("the recording's directory is gone: %v", err)
	}
	if rec := call(t, mux, "DELETE", "/v1/meetings/nope", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("delete unknown = %d, want 404", rec.Code)
	}
}

func failedWithError(t *testing.T, d *Daemon, msg string) meeting.Manifest {
	t.Helper()
	m, _, _ := d.Meet.Store.Create(meeting.Manifest{Title: "Plan"}, time.Now())
	got, err := d.Meet.Store.Update(m.ID, func(mm *meeting.Manifest) {
		mm.Status, mm.NotesPending, mm.Error = meeting.StatusTranscribed, "failed", msg
	})
	if err != nil {
		t.Fatal(err)
	}
	return *got
}

// A stored error text can carry an absolute path (the home directory, a model
// file): every place that serves it answers it without the path.
// Mutation: internal/daemon/meetings_http.go summarize/publicManifest, return
// m.Error unchanged -> RED (list, get, MCP list and MCP get leak the path).
func TestServedMeetingErrorsCarryNoAbsolutePath(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	home := d.Cfg.Home
	m := failedWithError(t, d, "notes run: open "+home+"/models/notes.gguf: no such file; also /Users/bob/secret/dir/x.txt")
	leaks := func(where, body string) {
		t.Helper()
		for _, bad := range []string{home, "/Users/bob", "secret/dir"} {
			if strings.Contains(body, bad) {
				t.Errorf("%s leaks %q: %s", where, bad, body)
			}
		}
		if !strings.Contains(body, "no such file") {
			t.Errorf("%s lost the reason: %s", where, body)
		}
	}
	leaks("GET /v1/meetings", call(t, mux, "GET", "/v1/meetings", "").Body.String())
	leaks("GET /v1/meetings/{id}", call(t, mux, "GET", "/v1/meetings/"+m.ID, "").Body.String())

	cs := mcpSession(t, d)
	list, _ := json.Marshal(callMCP(t, cs, "meetings_list", nil))
	leaks("meetings_list", string(list))
	got, _ := json.Marshal(callMCP(t, cs, "meeting_get", map[string]any{"id": m.ID}))
	leaks("meeting_get", string(got))
}

// The finish and notes answers are manifests too.
// Mutation: internal/daemon/meetings_http.go handleMeetingFinish, answer the
// raw manifest -> RED.
func TestFinishAnswerCarriesNoAbsolutePath(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	m, _, _ := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	_, _ = d.Meet.Store.Update(m.ID, func(mm *meeting.Manifest) { mm.Error = "boom at " + d.Cfg.Home + "/x/y.pcm" })
	rec := call(t, mux, "POST", "/v1/meetings/"+m.ID+"/finish", "{}")
	if rec.Code != http.StatusAccepted || strings.Contains(rec.Body.String(), d.Cfg.Home) {
		t.Fatalf("finish = %d %s", rec.Code, rec.Body)
	}
}

// A text that exists but cannot be read is an error, not an empty note.
// Mutation: internal/daemon/meetings_http.go handleMeetingGet, `_ =` the Text
// error again -> RED (200 with no notes); likewise meetings_mcp.go toolMeetingGet.
func TestUnreadableTextIsAnErrorNotEmptyNotes(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	m, dir, _ := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	if err := os.Mkdir(filepath.Join(dir, meeting.NotesMD), 0o700); err != nil { // reading a directory fails
		t.Fatal(err)
	}
	rec := call(t, mux, "GET", "/v1/meetings/"+m.ID+"?include=notes", "")
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("get with unreadable notes = %d %s, want 500", rec.Code, rec.Body)
	}
	if strings.Contains(rec.Body.String(), dir) {
		t.Fatalf("the error names the directory: %s", rec.Body)
	}
	// A missing text is still just empty.
	m2, _, _ := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	if rec := call(t, mux, "GET", "/v1/meetings/"+m2.ID+"?include=notes,transcript", ""); rec.Code != http.StatusOK {
		t.Fatalf("get with absent texts = %d", rec.Code)
	}

	cs := mcpSession(t, d)
	res, err := cs.CallTool(t.Context(), &mcp.CallToolParams{Name: "meeting_get", Arguments: map[string]any{"id": m.ID}})
	if err != nil || !res.IsError {
		t.Fatalf("meeting_get with unreadable notes: err=%v res=%+v, want a tool error", err, res)
	}
	raw, _ := json.Marshal(res.Content)
	if strings.Contains(string(raw), dir) {
		t.Fatalf("the tool error names the directory: %s", raw)
	}
}

// Invalid paging is an error the model can read, not an empty page that looks
// like the end of the transcript; the page-size clamp is in the description.
// Mutation: internal/daemon/meetings_mcp.go page, restore
// `if offset < 0 || offset >= len(r) { return "", 0 }` -> RED.
func TestPageRefusesInvalidOffsets(t *testing.T) {
	text := strings.Repeat("ж", 25)
	for _, c := range []struct{ off, max int }{{-1, 10}, {26, 10}, {999, 10}, {0, -5}} {
		if _, _, err := page(text, c.off, c.max); err == nil {
			t.Errorf("page(offset %d, max %d) accepted", c.off, c.max)
		}
	}
	if got, next, err := page(text, 25, 10); err != nil || got != "" || next != 0 {
		t.Fatalf("offset at the end = %q %d %v, want empty page, no next", got, next, err)
	}
	if got, _, err := page("", 0, 0); err != nil || got != "" {
		t.Fatalf("empty text = %q %v", got, err)
	}
	if got, next, err := page(text, 0, 1_000_000); err != nil || len([]rune(got)) != 25 || next != 0 {
		t.Fatalf("a max above the cap = %d runes next %d %v", len([]rune(got)), next, err)
	}
}

// Mutation: internal/daemon/meetings_http.go handleMeetingCreate, delete the
// label/source length checks -> RED; delete cleanText -> the control-character
// cases RED.
func TestCreateCapsAndCleansLabelsSourceAndTitle(t *testing.T) {
	_, mux := meetingFixture(t, nil)
	long := strings.Repeat("x", 500)
	for _, body := range []string{
		`{"labels":{"me":"` + long + `"}}`,
		`{"labels":{"them":"` + long + `"}}`,
		`{"source":"` + long + `"}`,
	} {
		if rec := call(t, mux, "POST", "/v1/meetings", body); rec.Code != http.StatusBadRequest {
			t.Errorf("POST %.40s... = %d, want 400", body, rec.Code)
		}
	}
	rec := call(t, mux, "POST", "/v1/meetings", `{"title":"Pl\u0000an\n2","source":"zoom\u0007","labels":{"me":"Bob\nEve\u001b","them":"\t"}}`)
	var m createMeetingResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &m)
	if rec.Code != http.StatusCreated || m.Title != "Pl an 2" || m.Source != "zoom" || m.Labels.Me != "Bob Eve" || m.Labels.Them != defaultThemName {
		t.Fatalf("create = %d title %q source %q labels %+v", rec.Code, m.Title, m.Source, m.Labels)
	}
}

// include is a comma list: a name that merely contains "notes" selects nothing.
// Mutation: internal/daemon/meetings_http.go handleMeetingGet, back to
// strings.Contains(include, "notes") -> RED.
func TestIncludeIsACommaList(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	m, dir, _ := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	_ = os.WriteFile(filepath.Join(dir, meeting.NotesMD), []byte("N"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, meeting.TranscriptMD), []byte("T"), 0o600)
	get := func(inc string) meetingDetail {
		var out meetingDetail
		_ = json.Unmarshal(call(t, mux, "GET", "/v1/meetings/"+m.ID+"?include="+inc, "").Body.Bytes(), &out)
		return out
	}
	if g := get("notesfoo,xtranscript"); g.NotesMD != "" || g.TranscriptMD != "" {
		t.Fatalf("lookalike names selected texts: %+v", g)
	}
	if g := get("notes"); g.NotesMD != "N" || g.TranscriptMD != "" {
		t.Fatalf("include=notes = %+v", g)
	}
	if g := get("transcript,%20notes"); g.NotesMD != "N" || g.TranscriptMD != "T" {
		t.Fatalf("include=transcript, notes = %+v", g)
	}
}
