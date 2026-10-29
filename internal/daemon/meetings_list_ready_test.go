package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"sync/atomic"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/meeting"
)

// A meetings list asks "can this Mac run the diarizer now" once for the whole list, not once per meeting that
// qualifies (#340.4): the probe stats files and reads the models' marker.
// F4 mutation: internal/daemon/meetings_http.go handleMeetingList and meetings_mcp.go toolMeetingsList, build
// the summarizer inside the loop (`out = append(out, d.summarizer()(m))`) -> RED, 5 probes for 5 meetings.
func TestAMeetingsListAsksTheDiarizerReadinessOnce(t *testing.T) {
	d, mux, _, _ := voicesFixture(t)
	var probes atomic.Int32
	d.Meet.DiarizeReady = func() string { probes.Add(1); return "" }
	ids := make([]string, 5)
	for i := range ids {
		ids[i] = unavailableMeeting(t, d, mux, meeting.DiarModelsMissing)
	}

	probes.Store(0)
	rec := call(t, mux, "GET", "/v1/meetings", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET = %d %s", rec.Code, rec.Body)
	}
	if got := probes.Load(); got != 1 {
		t.Errorf("HTTP list: readiness probed %d times for %d meetings, want 1", got, len(ids))
	}
	if n := countRetryable(t, rec.Body.Bytes()); n != len(ids) {
		t.Errorf("HTTP list: %d meetings voices_retryable, want %d: %s", n, len(ids), rec.Body)
	}

	probes.Store(0)
	_, out, err := d.toolMeetingsList(context.Background(), nil, meetingsListIn{})
	if err != nil {
		t.Fatal(err)
	}
	if got := probes.Load(); got != 1 {
		t.Errorf("MCP list: readiness probed %d times for %d meetings, want 1", got, len(ids))
	}
	for _, m := range out.Meetings {
		if m.VoicesRetryable == nil || !*m.VoicesRetryable {
			t.Errorf("MCP list: %s is not voices_retryable", m.ID)
		}
	}

	// a list with nothing that qualifies does not probe at all
	probes.Store(0)
	d2, mux2, _, _ := voicesFixture(t)
	d2.Meet.DiarizeReady = func() string { probes.Add(1); return "" }
	_ = call(t, mux2, "GET", "/v1/meetings", "")
	if probes.Load() != 0 {
		t.Errorf("an empty list probed readiness %d times", probes.Load())
	}
}

func countRetryable(t *testing.T, body []byte) int {
	t.Helper()
	var got struct {
		Meetings []struct {
			VoicesRetryable bool `json:"voices_retryable"`
		}
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, m := range got.Meetings {
		if m.VoicesRetryable {
			n++
		}
	}
	return n
}
