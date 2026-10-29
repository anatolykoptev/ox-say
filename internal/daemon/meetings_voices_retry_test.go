package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/meeting"
)

// unavailableMeeting makes a finished meeting whose far side kept one label because diarization was unavailable for
// reason, with both channels on disk, and returns its id.
func unavailableMeeting(t *testing.T, d *Daemon, mux http.Handler, reason string) string {
	t.Helper()
	rec := call(t, mux, "POST", "/v1/meetings", `{"title":"Plan","labels":{"me":"Anatoly","them":"Other"}}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create = %d %s", rec.Code, rec.Body)
	}
	var created createMeetingResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	writeTone(t, filepath.Join(created.Dir, meeting.MePCM), 30)
	writeTone(t, filepath.Join(created.Dir, meeting.ThemPCM), 30)
	if _, err := d.Meet.Store.Update(created.ID, func(m *meeting.Manifest) {
		m.Status = meeting.StatusDone
		m.Warnings = []string{meeting.WarnDiarUnavailable}
		m.DiarReason = reason
	}); err != nil {
		t.Fatal(err)
	}
	return created.ID
}

// readiness stands in for diarReady: "" is ready, anything else is the reason it is not.
type readiness struct{ reason atomic.Value }

func (r *readiness) set(s string) { r.reason.Store(s) }
func (r *readiness) get() string  { return r.reason.Load().(string) }

// voicesFixture is a meeting daemon whose diarizer is a fake that counts its calls and breaks (so a run that reached
// it is visible in the manifest), and whose readiness the test sets.
func voicesFixture(t *testing.T) (*Daemon, *http.ServeMux, *readiness, *atomic.Int32) {
	t.Helper()
	d, mux := meetingFixture(t, nil)
	ready := &readiness{}
	ready.set("")
	var calls atomic.Int32
	d.Meet.DiarizeReady = ready.get
	d.Meet.Diarize = func(context.Context, string) ([]byte, error) {
		calls.Add(1)
		return nil, errors.New("fake ox-diar broke")
	}
	return d, mux, ready, &calls
}

func meetingManifest(t *testing.T, d *Daemon, id string) meeting.Manifest {
	t.Helper()
	m, err := d.Meet.Store.Load(id)
	if err != nil {
		t.Fatal(err)
	}
	return *m
}

// A meeting recorded while the voice engine or its models were missing gets its voices once diarization is ready:
// the retry is accepted and a voices job runs (the fake diarizer is called).
// Mutation: internal/meeting/runner.go RetryVoices, make the unavailable-reason branch of wantsVoicesAgain return
// false -> RED; delete the `r.Enqueue(id)` line -> RED (no job).
func TestVoicesRetryForAnUnavailableMeetingRunsOnceDiarizationIsReady(t *testing.T) {
	for _, reason := range []string{meeting.DiarModelsMissing, meeting.DiarEngineMissing, meeting.DiarOSTooOld, meeting.DiarCPUUnsupported} {
		d, mux, _, calls := voicesFixture(t)
		id := unavailableMeeting(t, d, mux, reason)
		rec := call(t, mux, "POST", "/v1/meetings/"+id+"/voices", "")
		if rec.Code != http.StatusAccepted {
			t.Fatalf("%s: POST = %d %s", reason, rec.Code, rec.Body)
		}
		if err := d.Meet.Process(context.Background(), id); err != nil {
			t.Fatal(err)
		}
		if calls.Load() != 1 {
			t.Errorf("%s: the diarizer ran %d times, want 1", reason, calls.Load())
		}
		if m := meetingManifest(t, d, id); len(m.Warnings) != 1 || m.Warnings[0] != meeting.WarnNoDiarization {
			t.Errorf("%s: after the run warnings = %v (the unavailable warning must be replaced by what the run did)", reason, m.Warnings)
		}
	}
}

// While diarization is not ready the retry is refused with the stable code and the reason the app can show, the
// meeting is left as it was and nothing runs.
// Mutation: internal/meeting/runner.go RetryVoices, delete the readiness refusal (always allow) -> RED;
// invert it (refuse when ready) -> RED in the test above.
func TestVoicesRetryIsRefusedWhileDiarizationIsNotReady(t *testing.T) {
	d, mux, ready, calls := voicesFixture(t)
	ready.set(meeting.DiarModelsMissing)
	id := unavailableMeeting(t, d, mux, meeting.DiarModelsMissing)
	rec := call(t, mux, "POST", "/v1/meetings/"+id+"/voices", "")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("POST = %d %s", rec.Code, rec.Body)
	}
	var body struct {
		Error struct{ Code, Reason, Message string }
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if body.Error.Code != "voices_not_ready" || body.Error.Reason != meeting.DiarModelsMissing || body.Error.Message == "" {
		t.Errorf("error body = %s", rec.Body)
	}
	if m := meetingManifest(t, d, id); m.Status != meeting.StatusDone || m.Warnings[0] != meeting.WarnDiarUnavailable {
		t.Errorf("a refused retry moved the meeting: %+v", m)
	}
	if d.Meet.Active() != 0 || calls.Load() != 0 {
		t.Errorf("a refused retry queued work: active %d, diarizer calls %d", d.Meet.Active(), calls.Load())
	}
}

// Reasons where trying again cannot help stay refused even when diarization is ready: ox-diar exit 4 (unreadable
// pcm), models that will not load, a recording over the cap, and a code from a newer daemon.
// Mutation: internal/meeting/diarize.go retryableUnavailable, add DiarInputUnreadable (or DiarTooLong,
// DiarModelsUnusable) to the set -> RED.
func TestVoicesRetryStaysRefusedWhereARetryCannotHelp(t *testing.T) {
	for _, reason := range []string{meeting.DiarInputUnreadable, meeting.DiarModelsUnusable, meeting.DiarTooLong, "from_the_future", ""} {
		d, mux, _, calls := voicesFixture(t)
		id := unavailableMeeting(t, d, mux, reason)
		rec := call(t, mux, "POST", "/v1/meetings/"+id+"/voices", "")
		if rec.Code != http.StatusConflict {
			t.Errorf("%q: POST = %d %s, want 409", reason, rec.Code, rec.Body)
		}
		if d.Meet.Active() != 0 || calls.Load() != 0 {
			t.Errorf("%q: a refused retry queued work", reason)
		}
	}
}

// A meeting whose audio retention has removed cannot be retried even when diarization is ready.
func TestVoicesRetryNeedsTheFarSideAudio(t *testing.T) {
	d, mux, _, _ := voicesFixture(t)
	id := unavailableMeeting(t, d, mux, meeting.DiarModelsMissing)
	dir, _ := d.Meet.Store.Dir(id)
	if err := os.Remove(filepath.Join(dir, meeting.ThemPCM)); err != nil {
		t.Fatal(err)
	}
	if rec := call(t, mux, "POST", "/v1/meetings/"+id+"/voices", ""); rec.Code != http.StatusConflict {
		t.Fatalf("POST = %d %s", rec.Code, rec.Body)
	}
	if got := servedRetryable(t, mux, id); got {
		t.Error("the served meeting offers a retry without audio")
	}
}

// #340: an external deletion of me.pcm (a crash, a failed unlink, a user) leaves them.pcm behind. The retry would be
// accepted and then bounced by the transcription's half-deleted-audio guard, so "Try Again" did nothing until the
// retention date. It is offered and accepted only when the mic file is here or the manifest records the mic as silent
// (a side that never had audio is not a loss).
// Mutation: internal/meeting/runner.go wantsVoicesAgain, `return !(transcriptReadable(dir) && channelLost(err, m,
// WarnNoMicAudio))` -> `return true` -> RED (served voices_retryable true, POST 202) in the rows with the mic file gone.
func TestVoicesRetryNeedsTheMicFileUnlessTheMicWasSilent(t *testing.T) {
	for _, tc := range []struct {
		name    string
		warns   []string
		deleted bool
		rmMe    bool
		want    bool
	}{
		{"mic file here", []string{meeting.WarnDiarUnavailable}, false, false, true},
		{"mic file gone, mic not recorded silent", []string{meeting.WarnDiarUnavailable}, false, true, false},
		{"failed kind, mic file gone", []string{meeting.WarnNoDiarization}, false, true, false},
		{"mic file gone, mic recorded silent", []string{meeting.WarnDiarUnavailable, meeting.WarnNoMicAudio}, false, true, true},
		{"mic recorded silent but audio marked deleted", []string{meeting.WarnDiarUnavailable, meeting.WarnNoMicAudio}, true, true, false},
	} {
		d, mux, _, calls := voicesFixture(t)
		id := unavailableMeeting(t, d, mux, meeting.DiarModelsMissing)
		dir, _ := d.Meet.Store.Dir(id)
		// a finished meeting has a transcript, which is what makes a missing mic file a loss
		if err := os.WriteFile(filepath.Join(dir, meeting.TranscriptJSON), []byte("[]"), 0o600); err != nil {
			t.Fatal(err)
		}
		if tc.rmMe {
			if err := os.Remove(filepath.Join(dir, meeting.MePCM)); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := d.Meet.Store.Update(id, func(m *meeting.Manifest) { m.Warnings = tc.warns; m.AudioDeleted = tc.deleted }); err != nil {
			t.Fatal(err)
		}
		if tc.warns[0] == meeting.WarnDiarUnavailable {
			if got := servedRetryable(t, mux, id); got != tc.want {
				t.Errorf("%s: voices_retryable = %v, want %v", tc.name, got, tc.want)
			}
		}
		rec := call(t, mux, "POST", "/v1/meetings/"+id+"/voices", "")
		wantCode := http.StatusConflict
		if tc.want {
			wantCode = http.StatusAccepted
		}
		if rec.Code != wantCode {
			t.Errorf("%s: POST = %d %s, want %d", tc.name, rec.Code, rec.Body, wantCode)
		}
		if !tc.want && (d.Meet.Active() != 0 || calls.Load() != 0) {
			t.Errorf("%s: a refused retry queued work", tc.name)
		}
	}
}

// servedRetryable reads voices_retryable from the JSON the daemon serves for one meeting, in the list and in the
// detail, and fails when the two disagree.
func servedRetryable(t *testing.T, mux http.Handler, id string) bool {
	t.Helper()
	var detail map[string]any
	rec := call(t, mux, "GET", "/v1/meetings/"+id, "")
	if err := json.Unmarshal(rec.Body.Bytes(), &detail); err != nil {
		t.Fatalf("detail: %v %s", err, rec.Body)
	}
	var list struct{ Meetings []map[string]any }
	rec = call(t, mux, "GET", "/v1/meetings", "")
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatalf("list: %v %s", err, rec.Body)
	}
	var inList any
	for _, m := range list.Meetings {
		if m["id"] == id {
			inList = m["voices_retryable"]
		}
	}
	inDetail := detail["voices_retryable"]
	if (inList == true) != (inDetail == true) {
		t.Fatalf("list says %v, detail says %v", inList, inDetail)
	}
	return inDetail == true
}

// The app decides whether to show "Try Again" from this field of the served JSON: true exactly when the meeting is
// unavailable for a reason a retry can fix, diarization is ready now, and the audio is here.
// Mutation (reads the served JSON): internal/daemon/meetings_http.go summarize and handleMeetingGet, hard-wire
// VoicesRetryable to false -> RED here; internal/meeting/runner.go VoicesRetryable, drop the DiarizeReady check
// -> RED (not ready, yet offered).
func TestServedMeetingSaysWhetherVoicesCanBeRetried(t *testing.T) {
	d, mux, ready, _ := voicesFixture(t)
	models := unavailableMeeting(t, d, mux, meeting.DiarModelsMissing)
	unreadable := unavailableMeeting(t, d, mux, meeting.DiarInputUnreadable)
	ready.set(meeting.DiarModelsMissing)
	if servedRetryable(t, mux, models) {
		t.Error("models_missing offered a retry while the models are still missing")
	}
	ready.set("")
	if !servedRetryable(t, mux, models) {
		t.Error("models_missing offers no retry although diarization is ready")
	}
	if servedRetryable(t, mux, unreadable) {
		t.Error("input_unreadable offers a retry: it would meet the same file")
	}
}

// servedRetryableField is servedRetryable for the failed kind: the app must tell "the daemon says no" (false) from "an
// older daemon that serves no word" (absent), so it reports whether the field is in the JSON at all, in the list and
// in the detail alike.
func servedRetryableField(t *testing.T, mux http.Handler, id string) (present, value bool) {
	t.Helper()
	var detail map[string]any
	rec := call(t, mux, "GET", "/v1/meetings/"+id, "")
	if err := json.Unmarshal(rec.Body.Bytes(), &detail); err != nil {
		t.Fatalf("detail: %v %s", err, rec.Body)
	}
	var list struct{ Meetings []map[string]any }
	rec = call(t, mux, "GET", "/v1/meetings", "")
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatalf("list: %v %s", err, rec.Body)
	}
	var inList any
	for _, m := range list.Meetings {
		if m["id"] == id {
			inList = m["voices_retryable"]
		}
	}
	inDetail, ok := detail["voices_retryable"]
	if inList != inDetail {
		t.Fatalf("list says %v, detail says %v", inList, inDetail)
	}
	return ok, inDetail == true
}

// #340 (failed kind): the app used to decide Try Again for a failed run alone, so a half-deleted failed meeting showed a
// button the POST refuses (409). The daemon now serves voices_retryable for the failed kind as well, from the same
// rule the POST uses, and serves it as an explicit false (not an omitted field) so the app can tell a "no" from an
// older daemon.
// Mutations: internal/meeting/runner.go VoicesRetryer, `if !slices.Contains(m.Warnings, WarnNoDiarization) && !unavailableFixable(&m)` -> `if !unavailableFixable(&m)`
// -> RED (failed kind served false); internal/daemon/meetings_http.go summarizer / handleMeetingGet, `voicesField(m, ...)`
// -> `&retryable` or nil for the failed kind -> RED (field absent / wrong).
func TestServedMeetingSaysWhetherAFailedRunCanBeRetried(t *testing.T) {
	d, mux, _, _ := voicesFixture(t)
	failed := unavailableMeeting(t, d, mux, meeting.DiarEngineError)
	if _, err := d.Meet.Store.Update(failed, func(m *meeting.Manifest) { m.Warnings = []string{meeting.WarnNoDiarization} }); err != nil {
		t.Fatal(err)
	}
	if present, v := servedRetryableField(t, mux, failed); !present || !v {
		t.Errorf("a failed run with both channels here: present=%v value=%v, want served true", present, v)
	}
	// the failed kind does not wait for diarization to be ready: RetryVoices only asks readiness for the unavailable kind
	// (a failed run is not a missing-model problem), so a not-ready answer must not turn the served word to false
	d2, mux2, ready2, _ := voicesFixture(t)
	failed2 := unavailableMeeting(t, d2, mux2, meeting.DiarEngineError)
	if _, err := d2.Meet.Store.Update(failed2, func(m *meeting.Manifest) { m.Warnings = []string{meeting.WarnNoDiarization} }); err != nil {
		t.Fatal(err)
	}
	ready2.set(meeting.DiarModelsMissing)
	if present, v := servedRetryableField(t, mux2, failed2); !present || !v {
		t.Errorf("a failed run while diarization is not ready: present=%v value=%v, want served true (the POST accepts it)", present, v)
	}
	if rec := call(t, mux2, "POST", "/v1/meetings/"+failed2+"/voices", ""); rec.Code != http.StatusAccepted {
		t.Errorf("setup: the POST for that failed run = %d %s, want 202", rec.Code, rec.Body)
	}

	// half deleted (mic file gone over a finished transcript): the POST bounces it, so the daemon says no, explicitly
	d3, mux3, _, _ := voicesFixture(t)
	half := unavailableMeeting(t, d3, mux3, meeting.DiarEngineError)
	dir, _ := d3.Meet.Store.Dir(half)
	if err := os.WriteFile(filepath.Join(dir, meeting.TranscriptJSON), []byte("[]"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(dir, meeting.MePCM)); err != nil {
		t.Fatal(err)
	}
	if _, err := d3.Meet.Store.Update(half, func(m *meeting.Manifest) { m.Warnings = []string{meeting.WarnNoDiarization} }); err != nil {
		t.Fatal(err)
	}
	if present, v := servedRetryableField(t, mux3, half); !present || v {
		t.Errorf("a half-deleted failed run: present=%v value=%v, want an explicit false", present, v)
	}
	if rec := call(t, mux3, "POST", "/v1/meetings/"+half+"/voices", ""); rec.Code != http.StatusConflict {
		t.Errorf("setup: the POST for the half-deleted run = %d %s, want 409", rec.Code, rec.Body)
	}

	// a meeting with no voices problem carries no word at all
	d4, mux4, _, _ := voicesFixture(t)
	clean := unavailableMeeting(t, d4, mux4, "")
	if _, err := d4.Meet.Store.Update(clean, func(m *meeting.Manifest) { m.Warnings = nil; m.DiarReason = "" }); err != nil {
		t.Fatal(err)
	}
	if present, _ := servedRetryableField(t, mux4, clean); present {
		t.Error("a meeting without a voices problem serves voices_retryable")
	}
}

// A meeting still being recorded or processed is never offered Try Again and its POST is refused the way the busy
// path refuses (409, "still being processed"), whatever its reason and however ready diarization is.
// Mutation: internal/meeting/runner.go VoicesRetryable, delete the `return false` under `default:` of the status
// switch -> RED (served voices_retryable true while queued / transcribing / ...).
func TestVoicesRetryIsNeverOfferedWhileTheMeetingIsInProgress(t *testing.T) {
	for _, st := range []meeting.Status{meeting.StatusRecording, meeting.StatusQueued, meeting.StatusTranscribing, meeting.StatusSummarizing} {
		d, mux, _, calls := voicesFixture(t)
		id := unavailableMeeting(t, d, mux, meeting.DiarModelsMissing)
		if !servedRetryable(t, mux, id) {
			t.Fatalf("setup: a done meeting must offer the retry")
		}
		if _, err := d.Meet.Store.Update(id, func(m *meeting.Manifest) { m.Status = st }); err != nil {
			t.Fatal(err)
		}
		if servedRetryable(t, mux, id) {
			t.Errorf("%s: voices_retryable is true while the meeting is in progress", st)
		}
		rec := call(t, mux, "POST", "/v1/meetings/"+id+"/voices", "")
		if rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), "still being processed") {
			t.Errorf("%s: POST = %d %s, want the busy 409", st, rec.Code, rec.Body)
		}
		if got := meetingManifest(t, d, id).Status; got != st || calls.Load() != 0 {
			t.Errorf("%s: a refused retry moved the meeting to %s or ran the diarizer", st, got)
		}
	}
}
