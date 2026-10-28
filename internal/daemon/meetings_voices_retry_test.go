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
	// a failed run is the app's own business (DiarProblem.canRetry): the daemon does not claim it here
	d2, mux2, _, _ := voicesFixture(t)
	failed := unavailableMeeting(t, d2, mux2, meeting.DiarEngineError)
	if _, err := d2.Meet.Store.Update(failed, func(m *meeting.Manifest) { m.Warnings = []string{meeting.WarnNoDiarization} }); err != nil {
		t.Fatal(err)
	}
	if servedRetryable(t, mux2, failed) {
		t.Error("a failed (not unavailable) meeting is marked by the daemon field; that decision stays with the failed-kind rule")
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
