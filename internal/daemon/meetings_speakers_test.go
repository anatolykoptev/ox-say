package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/meeting"
)

// groupMeeting makes a finished meeting with three voices on disk and returns its id.
func groupMeeting(t *testing.T, d *Daemon, mux http.Handler, status meeting.Status) string {
	t.Helper()
	rec := call(t, mux, "POST", "/v1/meetings", `{"title":"Plan","labels":{"me":"Anatoly","them":"Other","speaker":"Speaker"}}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create = %d %s", rec.Code, rec.Body)
	}
	var created createMeetingResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	turns := []meeting.Turn{
		{Speaker: meeting.SpeakerMe, S: 0, E: 2, Text: "welcome everyone"},
		{Speaker: meeting.SpeakerThem, Voice: "them:1", S: 3, E: 6, Text: "thanks for having us"},
		{Speaker: meeting.SpeakerThem, Voice: "them:2", S: 7, E: 12, Text: "let us start with the budget"},
		{Speaker: meeting.SpeakerThem, Voice: "them:3", S: 13, E: 15, Text: "agreed"},
	}
	raw, _ := json.Marshal(turns)
	if err := os.WriteFile(filepath.Join(created.Dir, meeting.TranscriptJSON), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Meet.Store.Update(created.ID, func(m *meeting.Manifest) {
		m.Status, m.VoiceMode, m.Voices = status, meeting.VoicesAuto, 3
	}); err != nil {
		t.Fatal(err)
	}
	return created.ID
}

func TestSpeakersJourney(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	id := groupMeeting(t, d, mux, meeting.StatusDone)

	rec := call(t, mux, "GET", "/v1/meetings/"+id+"/speakers", "")
	var v meeting.SpeakersView
	_ = json.Unmarshal(rec.Body.Bytes(), &v)
	if rec.Code != http.StatusOK || v.Mode != meeting.VoicesAuto || len(v.Speakers) != 3 || v.Speakers[0].Label != "Speaker 1" {
		t.Fatalf("get = %d %s", rec.Code, rec.Body)
	}

	rec = call(t, mux, "PATCH", "/v1/meetings/"+id+"/speakers", `{"rename":{"them:2":"Olga"},"merge":{"them:3":"them:1"}}`)
	_ = json.Unmarshal(rec.Body.Bytes(), &v)
	if rec.Code != http.StatusOK || v.Speakers[1].Label != "Olga" || v.Speakers[2].MergedTo != "them:1" {
		t.Fatalf("patch = %d %s", rec.Code, rec.Body)
	}
	dir, _ := d.Meet.Store.Dir(id)
	text, _ := os.ReadFile(filepath.Join(dir, meeting.TranscriptMD))
	if !strings.Contains(string(text), "**Olga** [0:07]") || strings.Contains(string(text), "Speaker 3") {
		t.Errorf("transcript.md was not written again:\n%s", text)
	}
	if st, _ := d.Meet.Store.Load(id); st.Status != meeting.StatusSummarizing {
		t.Errorf("status = %s, want the notes queued", st.Status)
	}
}

// Mutations: meetings_speakers.go, `errors.Is(err, meeting.ErrSpeakers)` -> `false` -> the 400 cases are RED;
// `errors.Is(err, meeting.ErrSpeakersBusy)` -> `false` -> the 409 case is RED.
func TestSpeakersRefusals(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	id := groupMeeting(t, d, mux, meeting.StatusDone)
	for body, want := range map[string]int{
		`{"rename":{"them:9":"X"}}`:        http.StatusBadRequest,
		`{"merge":{"them:1":"them:1"}}`:    http.StatusBadRequest,
		`{"rename":{"them:1":"A\u202eB"}}`: http.StatusBadRequest,
		`{"nonsense":1}`:                   http.StatusBadRequest,
	} {
		if rec := call(t, mux, "PATCH", "/v1/meetings/"+id+"/speakers", body); rec.Code != want {
			t.Errorf("%s = %d %s, want %d", body, rec.Code, rec.Body, want)
		}
	}
	busy := groupMeeting(t, d, mux, meeting.StatusSummarizing)
	if rec := call(t, mux, "PATCH", "/v1/meetings/"+busy+"/speakers", `{"split":true}`); rec.Code != http.StatusConflict {
		t.Errorf("a meeting being processed = %d %s, want 409", rec.Code, rec.Body)
	}
	if rec := call(t, mux, "GET", "/v1/meetings/20260101-000000-aaaaaa/speakers", ""); rec.Code != http.StatusNotFound {
		t.Errorf("unknown id = %d, want 404", rec.Code)
	}
}

// POST /v1/meetings/{id}/voices queues a meeting whose diarizer broke and whose far-side audio is still there, and
// refuses any other with the plain 409 text.
// Mutation: internal/daemon/meetings_http.go meetingRetryRefusals, delete the `has no failed diarization to retry`
// row -> RED (the refusal is a 500).
func TestVoicesRetryRoute(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	healthy := groupMeeting(t, d, mux, meeting.StatusDone)
	if rec := call(t, mux, "POST", "/v1/meetings/"+healthy+"/voices", ""); rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), "no voice problem") {
		t.Errorf("a meeting with voices = %d %s, want 409", rec.Code, rec.Body)
	}
	broken := groupMeeting(t, d, mux, meeting.StatusDone)
	dir, _ := d.Meet.Store.Dir(broken)
	if err := os.WriteFile(filepath.Join(dir, meeting.ThemPCM), make([]byte, 64000), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Meet.Store.Update(broken, func(m *meeting.Manifest) {
		m.VoiceMode, m.Voices, m.Warnings, m.DiarReason = "", 0, []string{meeting.WarnNoDiarization}, meeting.DiarEngineError
	}); err != nil {
		t.Fatal(err)
	}
	rec := call(t, mux, "POST", "/v1/meetings/"+broken+"/voices", "")
	if rec.Code != http.StatusAccepted {
		t.Fatalf("a failed diarization = %d %s, want 202", rec.Code, rec.Body)
	}
	if got, _ := d.Meet.Store.Load(broken); got.Status != meeting.StatusQueued {
		t.Errorf("status = %s, want queued for the transcript", got.Status)
	}
	if rec := call(t, mux, "POST", "/v1/meetings/20260101-000000-aaaaaa/voices", ""); rec.Code != http.StatusNotFound {
		t.Errorf("unknown id = %d, want 404", rec.Code)
	}
}

// initMeetings hands the runner the diarizer and its availability gate. Without them every meeting keeps one
// far-side label and nothing says why: no error anywhere.
// Mutations: internal/daemon/meetings.go initMeetings, delete the `Diarize: d.diarizer,` line -> RED; delete the
// `DiarizeReady: d.diarReady,` line -> RED.
func TestInitMeetingsWiresTheDiarizer(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	if d.Meet.Diarize == nil || d.Meet.DiarizeReady == nil {
		t.Fatalf("Diarize %v, DiarizeReady %v: not wired", d.Meet.Diarize != nil, d.Meet.DiarizeReady != nil)
	}
	was, wasArch := osMajor, goArch
	t.Cleanup(func() { osMajor, goArch = was, wasArch })
	osMajor = func() (int, bool) { return 14, true }
	if got := d.Meet.DiarizeReady(); got != meeting.DiarOSTooOld {
		t.Errorf("DiarizeReady = %q, want the daemon's own gate (%q)", got, meeting.DiarOSTooOld)
	}
	cfg, pcm := stubDiar(t, `printf '{"x":1}' > "$2"`)
	d.Cfg.Home, d.Cfg.DiarBin = cfg.Home, cfg.DiarBin
	raw, err := d.Meet.Diarize(context.Background(), pcm)
	if err != nil || string(raw) != `{"x":1}` {
		t.Errorf("Diarize = %q, %v: not the daemon's runner", raw, err)
	}
}

// The voices of a meeting reach the list, the detail and meeting_get; the app and the agents read them there.
// Mutations: internal/daemon/meetings_http.go summarize, delete `Voices: m.Voices, VoiceMode: m.VoiceMode, DiarReason: m.DiarReason`
// -> RED (the list lacks them); internal/daemon/meetings_mcp.go toolMeetingGet, delete `Voices: m.Voices, VoiceMode: m.VoiceMode`
// -> RED (meeting_get lacks them).
func TestVoicesReachTheListTheDetailAndMCP(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	id := groupMeeting(t, d, mux, meeting.StatusDone)
	if _, err := d.Meet.Store.Update(id, func(m *meeting.Manifest) { m.DiarReason = meeting.DiarTooLong }); err != nil {
		t.Fatal(err)
	}
	var list struct {
		Meetings []map[string]any `json:"meetings"`
	}
	_ = json.Unmarshal(call(t, mux, "GET", "/v1/meetings", "").Body.Bytes(), &list)
	if len(list.Meetings) != 1 || list.Meetings[0]["voices"] != float64(3) || list.Meetings[0]["voice_mode"] != meeting.VoicesAuto || list.Meetings[0]["diar_reason"] != meeting.DiarTooLong {
		t.Errorf("list = %v", list.Meetings)
	}
	var detail map[string]any
	_ = json.Unmarshal(call(t, mux, "GET", "/v1/meetings/"+id, "").Body.Bytes(), &detail)
	if detail["voices"] != float64(3) || detail["voice_mode"] != meeting.VoicesAuto || detail["diar_reason"] != meeting.DiarTooLong {
		t.Errorf("detail = %v", detail)
	}
	got := callMCP(t, mcpSession(t, d), "meeting_get", map[string]any{"id": id, "part": "transcript"})
	if got["voices"] != float64(3) || got["voice_mode"] != meeting.VoicesAuto {
		t.Errorf("meeting_get = %v", got)
	}
}

// labels.speaker, the word before a far-side voice's number in the user's language, is stored by POST /v1/meetings
// and cleaned and bounded like the other labels.
// Mutation: internal/daemon/meetings_http.go handleMeetingCreate, drop `Speaker: speaker` from the Labels literal -> RED.
func TestCreateStoresTheSpeakerWord(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	rec := call(t, mux, "POST", "/v1/meetings", `{"labels":{"me":"Я","them":"Они","speaker":"Спикер"}}`)
	var created createMeetingResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	if rec.Code != http.StatusCreated || created.Labels.Speaker != "Спикер" {
		t.Fatalf("create = %d %s", rec.Code, rec.Body)
	}
	if got, _ := d.Meet.Store.Load(created.ID); got.Labels.Speaker != "Спикер" {
		t.Errorf("stored speaker word %q", got.Labels.Speaker)
	}
	long := `{"labels":{"speaker":"` + strings.Repeat("x", maxLabelChars+1) + `"}}`
	if rec := call(t, mux, "POST", "/v1/meetings", long); rec.Code != http.StatusBadRequest {
		t.Errorf("an over-long speaker word = %d, want 400", rec.Code)
	}
}
