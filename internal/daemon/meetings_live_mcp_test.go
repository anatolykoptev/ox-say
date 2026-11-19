package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/anatolykoptev/ox-say/internal/meeting"
)

// recordingMeeting is a meeting in StatusRecording with an open live log, captions on (Apple Silicon default).
func recordingMeeting(t *testing.T) (*Daemon, *mcp.ClientSession, string, *meeting.LiveLog) {
	t.Helper()
	d, _ := meetingFixture(t, unifiedMemory)
	keep := liveToolPoll
	liveToolPoll = 10 * time.Millisecond
	t.Cleanup(func() { liveToolPoll = keep })
	m, dir, err := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	l, err := meeting.OpenLiveLog(dir)
	if err != nil {
		t.Fatal(err)
	}
	return d, mcpSession(t, d), m.ID, l
}

type liveResult struct {
	elapsed time.Duration
	out     map[string]any
}

// callLive runs meeting_live in the background and returns what it answered and how long it took.
func callLive(t *testing.T, cs *mcp.ClientSession, args map[string]any) <-chan liveResult {
	t.Helper()
	ch := make(chan liveResult, 1)
	go func() {
		start := time.Now()
		res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "meeting_live", Arguments: args})
		if err != nil || res.IsError {
			ch <- liveResult{out: map[string]any{"error": err, "content": res}}
			return
		}
		raw, _ := json.Marshal(res.StructuredContent)
		var out map[string]any
		_ = json.Unmarshal(raw, &out)
		ch <- liveResult{elapsed: time.Since(start), out: out}
	}()
	return ch
}

func awaitLiveResult(t *testing.T, ch <-chan liveResult, within time.Duration) liveResult {
	t.Helper()
	select {
	case r := <-ch:
		return r
	case <-time.After(within):
		t.Fatalf("meeting_live did not answer within %s", within)
		return liveResult{}
	}
}

func segTexts(out map[string]any) []string {
	var got []string
	segs, _ := out["segments"].([]any)
	for _, s := range segs {
		got = append(got, s.(map[string]any)["text"].(string))
	}
	return got
}

// The tool returns only the captions above the cursor, with the shape an agent needs, and the cursor to pass back.
// Mutation: internal/daemon/meetings_live_mcp.go awaitLive, `d.Live(id, after, liveToolLimit)` -> `d.Live(id, 0, liveToolLimit)` -> RED
// (an agent polling with after = next gets the whole call again every time).
func TestMeetingLiveToolReturnsOnlyCaptionsAfterTheCursor(t *testing.T) {
	_, cs, id, l := recordingMeeting(t)
	for i, txt := range []string{"one", "two", "three"} {
		ch := meeting.LiveMe
		if i == 1 {
			ch = meeting.LiveThem
		}
		_, _ = l.Append(ch, float64(i), float64(i)+0.5, txt)
	}
	all := callMCP(t, cs, "meeting_live", map[string]any{"wait_s": 0})
	if all["meeting_id"] != id || all["recording"] != true || all["next"] != float64(3) || strings.Join(segTexts(all), ",") != "one,two,three" {
		t.Fatalf("first poll = %v", all)
	}
	second := all["segments"].([]any)[1].(map[string]any)
	if second["seq"] != float64(2) || second["channel"] != "them" || second["start"] != float64(1) || second["end"] != 1.5 {
		t.Fatalf("segment shape = %v", second)
	}
	if st, _ := all["state"].(map[string]any); st == nil || st["enabled"] != true || st["recording"] != true {
		t.Fatalf("state = %v, want the route's state", all["state"])
	}
	rest := callMCP(t, cs, "meeting_live", map[string]any{"after": 2, "wait_s": 0})
	if got := strings.Join(segTexts(rest), ","); got != "three" || rest["next"] != float64(3) {
		t.Fatalf("after=2 = %v, want only three, next 3", rest)
	}
	none := callMCP(t, cs, "meeting_live", map[string]any{"after": 3, "wait_s": 0})
	if segs, ok := none["segments"].([]any); !ok || len(segs) != 0 || none["next"] != float64(3) || none["recording"] != true {
		t.Fatalf("nothing new = %v, want [] and the cursor unchanged", none)
	}
}

// A call waiting for speech answers the moment a caption lands, not at the end of wait_s.
func TestMeetingLiveToolLongPollReturnsEarlyOnANewSegment(t *testing.T) {
	_, cs, _, l := recordingMeeting(t)
	ch := callLive(t, cs, map[string]any{"wait_s": 30})
	time.Sleep(100 * time.Millisecond)
	_, _ = l.Append(meeting.LiveThem, 0, 1, "hello there")
	r := awaitLiveResult(t, ch, 5*time.Second)
	if got := strings.Join(segTexts(r.out), ","); got != "hello there" || r.out["next"] != float64(1) {
		t.Fatalf("answer = %v", r.out)
	}
	if r.elapsed > 5*time.Second {
		t.Fatalf("answered after %s, want soon after the caption", r.elapsed)
	}
}

// The recording stopping ends the wait: recording false and a pointer at meeting_get for the final transcript.
func TestMeetingLiveToolLongPollReturnsEarlyWhenTheRecordingStops(t *testing.T) {
	d, cs, id, _ := recordingMeeting(t)
	ch := callLive(t, cs, map[string]any{"wait_s": 30})
	time.Sleep(100 * time.Millisecond)
	if _, err := d.Meet.Store.Update(id, func(m *meeting.Manifest) { m.Status = meeting.StatusDone }); err != nil {
		t.Fatal(err)
	}
	r := awaitLiveResult(t, ch, 5*time.Second)
	note, _ := r.out["note"].(string)
	if r.out["recording"] != false || !strings.Contains(note, "meeting_get") || !strings.Contains(note, "final transcript") {
		t.Fatalf("answer after stop = %v", r.out)
	}
	if segs, ok := r.out["segments"].([]any); !ok || len(segs) != 0 {
		t.Fatalf("segments = %#v, want []", r.out["segments"])
	}
}

// With nothing new the call waits wait_s and answers empty, still recording.
func TestMeetingLiveToolAnswersEmptyWhenTheWaitRunsOut(t *testing.T) {
	_, cs, _, _ := recordingMeeting(t)
	r := awaitLiveResult(t, callLive(t, cs, map[string]any{"wait_s": 1}), 10*time.Second)
	if r.out["recording"] != true || len(segTexts(r.out)) != 0 || r.elapsed < 900*time.Millisecond {
		t.Fatalf("timed-out answer = %v after %s", r.out, r.elapsed)
	}
}

// Mutation: internal/daemon/meetings_live_mcp.go liveWait, drop `min(s, liveToolMaxWaitS)` -> RED (wait_s 1000 waits 1000 s).
func TestLiveWaitDefaultsAndCaps(t *testing.T) {
	ptr := func(n int) *int { return &n }
	for _, tc := range []struct {
		name string
		in   *int
		want time.Duration
		bad  bool
	}{
		{"omitted is the default", nil, 20 * time.Second, false},
		{"zero answers at once", ptr(0), 0, false},
		{"within the cap", ptr(5), 5 * time.Second, false},
		{"the cap itself", ptr(45), 45 * time.Second, false},
		{"above the cap is cut", ptr(1000), 45 * time.Second, false},
		{"negative is an error", ptr(-1), 0, true},
	} {
		got, err := liveWait(tc.in)
		if (err != nil) != tc.bad || got != tc.want {
			t.Errorf("%s: liveWait = %v, %v; want %v (error %v)", tc.name, got, err, tc.want, tc.bad)
		}
	}
}

// A client that goes away ends the wait: the handler's context is cancelled and nothing keeps polling.
// Mutation: internal/daemon/meetings_live_mcp.go awaitLive, delete the `case <-ctx.Done():` arm -> RED (the call
// runs on to the end of its 30 s wait).
func TestMeetingLiveToolDisconnectCancelsTheWait(t *testing.T) {
	d, _, _, _ := recordingMeeting(t)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	wait := 30
	go func() {
		_, _, err := d.toolMeetingLive(ctx, nil, meetingLiveIn{WaitS: &wait})
		done <- err
	}()
	time.Sleep(100 * time.Millisecond)
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("err = %v, want context.Canceled", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the wait went on after the client went away")
	}
}

func TestMeetingLiveToolWithNothingRecording(t *testing.T) {
	d, _ := meetingFixture(t, unifiedMemory)
	cs := mcpSession(t, d)
	empty := callMCP(t, cs, "meeting_live", map[string]any{"wait_s": 30})
	if empty["recording"] != false || empty["last_meeting_id"] != nil || !strings.Contains(empty["note"].(string), "No meeting is recording") {
		t.Fatalf("no meetings at all = %v", empty)
	}
	m, _, err := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Meet.Store.Update(m.ID, func(x *meeting.Manifest) { x.Status = meeting.StatusDone }); err != nil {
		t.Fatal(err)
	}
	r := awaitLiveResult(t, callLive(t, cs, map[string]any{"wait_s": 30}), 5*time.Second)
	if r.out["recording"] != false || r.out["last_meeting_id"] != m.ID || r.out["meeting_id"] != nil {
		t.Fatalf("only a finished meeting = %v, want recording false and last_meeting_id %s", r.out, m.ID)
	}
}

// Captions switched off: the tool says so and how to turn them on, at once, without waiting.
func TestMeetingLiveToolSaysWhenCaptionsAreOff(t *testing.T) {
	d, _ := meetingFixture(t, nil) // Intel default: off
	if _, _, err := d.Meet.Store.Create(meeting.Manifest{}, time.Now()); err != nil {
		t.Fatal(err)
	}
	r := awaitLiveResult(t, callLive(t, mcpSession(t, d), map[string]any{"wait_s": 30}), 5*time.Second)
	note, _ := r.out["note"].(string)
	st, _ := r.out["state"].(map[string]any)
	if r.out["recording"] != true || !strings.Contains(note, "Live captions are off") || !strings.Contains(note, "Live captions during a meeting") ||
		st["enabled"] != false {
		t.Fatalf("captions-off answer = %v", r.out)
	}
}

func TestMeetingLiveToolRefusesBadInput(t *testing.T) {
	_, cs, _, _ := recordingMeeting(t)
	for name, args := range map[string]map[string]any{
		"unknown meeting": {"meeting_id": "nope"},
		"negative after":  {"after": -1},
		"negative wait":   {"wait_s": -1},
	} {
		res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "meeting_live", Arguments: args})
		if err == nil && !res.IsError {
			t.Errorf("%s: accepted", name)
		}
	}
}

// A cursor above every caption of the meeting (it came from another meeting) answers at once, clamped to the last
// caption, instead of waiting out wait_s and handing the same cursor back.
// Mutation: internal/daemon/meetings_live_mcp.go awaitLive, delete the `if after > ans.highest {...}` block -> RED
// (the call waits its whole wait_s).
func TestMeetingLiveToolClampsACursorAheadOfTheMeeting(t *testing.T) {
	_, cs, _, l := recordingMeeting(t)
	_, _ = l.Append(meeting.LiveMe, 0, 1, "one")
	_, _ = l.Append(meeting.LiveThem, 1, 2, "two")
	r := awaitLiveResult(t, callLive(t, cs, map[string]any{"after": 40, "wait_s": 30}), 5*time.Second)
	note, _ := r.out["note"].(string)
	if r.out["next"] != float64(2) || len(segTexts(r.out)) != 0 || !strings.Contains(note, "ahead") || r.out["recording"] != true {
		t.Fatalf("cursor 40 over two captions = %v, want next 2 and the ahead note", r.out)
	}
	if r2 := callMCP(t, cs, "meeting_live", map[string]any{"after": 2, "wait_s": 0}); r2["note"] != nil || r2["next"] != float64(2) {
		t.Fatalf("a cursor at the last caption is not ahead: %v", r2)
	}
}
