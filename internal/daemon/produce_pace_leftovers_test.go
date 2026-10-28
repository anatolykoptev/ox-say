package daemon

import (
	"errors"
	"net/http"
	"path/filepath"
	"testing"
)

// stubPaceProbe stands in for the ffmpeg capability check and forgets what
// the real one proved.
func stubPaceProbe(t *testing.T, probe func() error) {
	t.Helper()
	oldProbe := paceProbe
	paceMu.Lock()
	oldProven := paceProven
	paceProven = false
	paceMu.Unlock()
	paceProbe = probe
	t.Cleanup(func() {
		paceProbe = oldProbe
		paceMu.Lock()
		paceProven = oldProven
		paceMu.Unlock()
	})
}

// #185.1: a failed probe is not remembered; a success is.
// Mutation: pace.go paceOK, remember the failure (paceProven = true always)
// -> the second call stays on the first answer -> RED.
// Mutation: paceOK, never remember (drop `paceProven = err == nil`) -> the
// probe runs three times -> RED.
func TestPaceProbeRetriesAfterAFailureAndCachesASuccess(t *testing.T) {
	calls := 0
	stubPaceProbe(t, func() error {
		calls++
		if calls == 1 {
			return errors.New("ffmpeg is missing")
		}
		return nil
	})
	if err := paceOK(); err == nil {
		t.Fatal("the first probe failed, yet paceOK passed")
	}
	if err := paceOK(); err != nil {
		t.Fatalf("ffmpeg appeared, yet the failure was remembered: %v", err)
	}
	if err := paceOK(); err != nil || calls != 2 {
		t.Fatalf("a proven success must not be probed again: err=%v calls=%d", err, calls)
	}
}

// #185.2: a neutral pace of 1.0 needs no ffmpeg, like 0.
// Mutation: produce_ops.go needPace, drop `&& *e.Pace != 1` -> 422 -> RED.
func TestNeutralPaceNeedsNoFFmpeg(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"`+paceScript+`","voice":"nar","out_path":"`+out+`"}`)
	stubPaceProbe(t, func() error { return errors.New("ffmpeg is missing") })
	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/delivery", `{"chunks":[{"n":1,"pace":1.0}]}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("pace 1.0 without ffmpeg: %d %s", rec.Code, rec.Body)
	}
	waitDoneHTTP(t, mux, id)
}

// #185 NIT: a batch that is a conflict anywhere is a conflict, not "no ffmpeg".
// Mutation: produce_ops.go deliver, call paceOK before deliveryModeGate -> 422 -> RED.
func TestConflictIsReportedBeforeMissingFFmpeg(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	id := createDone(t, mux, `{"script":"`+paceScript+`","voice":"nar","clone_mode":"ultimate","out_path":"`+out+`"}`)
	stubPaceProbe(t, func() error { return errors.New("ffmpeg is missing") })
	rec := do(mux, http.MethodPost, "/v1/produce/"+id+"/delivery", `{"chunks":[{"n":1,"style":"excited","pace":1.1}]}`)
	if rec.Code != http.StatusConflict {
		t.Fatalf("a style on an ultimate project with no ffmpeg: %d %s, want 409", rec.Code, rec.Body)
	}
}
