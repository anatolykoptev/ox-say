package daemon

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/meeting"
)

func unifiedMemory(c *config.Config) { c.GPUMemory = config.GPUMemoryUnified }

func settingsOf(t *testing.T, mux http.Handler) meetingSettingsAnswer {
	t.Helper()
	var got meetingSettingsAnswer
	rec := call(t, mux, "GET", "/v1/meetings/settings", "")
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil || rec.Code != http.StatusOK {
		t.Fatalf("GET settings = %d %s", rec.Code, rec.Body)
	}
	return got
}

// The default follows the Mac: on for Apple Silicon, off for Intel (a decode there is ten times slower and is what a
// dictation could wait behind). A choice the user made wins either way, and both sides are checked.
// Mutation: internal/daemon/meetings_live.go liveDefault, `return d.Cfg.UnifiedMemory()` -> `return true` -> RED
// (an Intel Mac captions by default).
func TestLiveCaptionsDefaultFollowsTheMacAndTheChoiceWins(t *testing.T) {
	for _, tc := range []struct {
		name        string
		edit        func(*config.Config)
		wantDefault bool
	}{{"Intel (discrete memory)", nil, false}, {"Apple Silicon (unified memory)", unifiedMemory, true}} {
		t.Run(tc.name, func(t *testing.T) {
			d, mux := meetingFixture(t, tc.edit)
			if got := settingsOf(t, mux); got.LiveCaptions != tc.wantDefault || got.LiveCaptionsDefault != tc.wantDefault {
				t.Fatalf("settings = %+v, want live captions and their default both %v", got, tc.wantDefault)
			}
			if d.liveEnabled() != tc.wantDefault {
				t.Fatalf("liveEnabled = %v before any choice, want %v", d.liveEnabled(), tc.wantDefault)
			}
			for _, choice := range []bool{!tc.wantDefault, tc.wantDefault} {
				body := `{"live_captions":false}`
				if choice {
					body = `{"live_captions":true}`
				}
				if rec := call(t, mux, "PUT", "/v1/meetings/settings", body); rec.Code != http.StatusOK {
					t.Fatalf("PUT %s = %d %s", body, rec.Code, rec.Body)
				}
				if got := settingsOf(t, mux); got.LiveCaptions != choice || got.LiveCaptionsDefault != tc.wantDefault || !d.liveEnabled() == choice {
					t.Fatalf("after choosing %v: settings = %+v", choice, got)
				}
			}
		})
	}
}

// A settings file written before the option existed (no live_captions) is "never chosen", not "off".
func TestLiveCaptionsAnOldSettingsFileMeansNeverChosen(t *testing.T) {
	d, _ := meetingFixture(t, unifiedMemory)
	if err := os.MkdirAll(d.Meet.Store.Root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d.Meet.Store.Root, meeting.SettingsFile), []byte(`{"retention_days":7}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if !d.liveEnabled() {
		t.Fatal("an Apple Silicon Mac with a pre-option settings file has captions off: the missing field was read as false")
	}
}

// A PUT changes the fields it carries and keeps the rest, and refuses an empty one; a file that cannot be read is
// never overwritten by a change that does not mention retention.
// Mutation: internal/daemon/meetings_http.go handleMeetingSettingsSet, replace `cur, err := d.Meet.Store.LoadSettings()`
// with `cur, err := d.Meet.Store.Settings(), error(nil)` -> RED (the unusable file is written over with 30 days).
func TestMeetingSettingsPutMergesAndProtectsAnUnusableFile(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	put := func(body string) int { return call(t, mux, "PUT", "/v1/meetings/settings", body).Code }
	if put(`{"retention_days":90}`) != 200 || put(`{"live_captions":true}`) != 200 {
		t.Fatal("PUT failed")
	}
	if got := settingsOf(t, mux); got.RetentionDays != 90 || !got.LiveCaptions {
		t.Fatalf("after two PUTs: %+v, want retention 90 and live on", got)
	}
	if put(`{"retention_days":7}`) != 200 {
		t.Fatal("PUT retention failed")
	}
	if got := settingsOf(t, mux); got.RetentionDays != 7 || !got.LiveCaptions {
		t.Fatalf("a retention PUT changed the live choice: %+v", got)
	}
	for _, body := range []string{`{}`, ``, `{"retention_days":null}`, `{"live_captions":null}`} {
		if c := put(body); c != http.StatusBadRequest {
			t.Errorf("PUT %q = %d, want 400", body, c)
		}
	}

	path := filepath.Join(d.Meet.Store.Root, meeting.SettingsFile)
	if err := os.WriteFile(path, []byte(`{"retention_days":15}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if c := put(`{"live_captions":false}`); c == http.StatusOK {
		t.Fatalf("a live-only PUT was accepted over an unusable settings file")
	}
	if raw, _ := os.ReadFile(path); string(raw) != `{"retention_days":15}` {
		t.Fatalf("the unusable file was rewritten: %s", raw)
	}
	if c := put(`{"retention_days":30}`); c != http.StatusOK {
		t.Fatalf("an explicit retention does not repair the file: %d", c)
	}
}

// The cursor over HTTP: every poll with the returned next yields the new captions once; a bad cursor is a 400, an
// unknown meeting a 404, and an empty answer carries [] and the cursor unchanged.
func TestMeetingLiveRouteCursor(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	m, dir, err := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	type answer struct {
		ID       string                `json:"id"`
		Segments []meeting.LiveSegment `json:"segments"`
		Next     int                   `json:"next"`
		State    liveState             `json:"state"`
	}
	poll := func(after int) answer {
		t.Helper()
		rec := call(t, mux, "GET", "/v1/meetings/"+m.ID+"/live?after="+strconv.Itoa(after), "")
		if rec.Code != http.StatusOK || rec.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("GET live = %d (Cache-Control %q) %s", rec.Code, rec.Header().Get("Cache-Control"), rec.Body)
		}
		var a answer
		if err := json.Unmarshal(rec.Body.Bytes(), &a); err != nil {
			t.Fatal(err)
		}
		return a
	}
	first := poll(0)
	if len(first.Segments) != 0 || first.Next != 0 || !first.State.Recording {
		t.Fatalf("a meeting with no captions answers %+v", first)
	}
	var raw map[string]any
	_ = json.Unmarshal(call(t, mux, "GET", "/v1/meetings/"+m.ID+"/live", "").Body.Bytes(), &raw)
	if segs, ok := raw["segments"].([]any); !ok || segs == nil {
		t.Fatalf("an empty answer carries segments %#v, want []", raw["segments"])
	}
	l, _ := meeting.OpenLiveLog(dir)
	for _, txt := range []string{"one", "two", "three"} {
		_, _ = l.Append(meeting.LiveMe, 0, 1, txt)
	}
	a := poll(first.Next)
	if len(a.Segments) != 3 || a.Next != 3 || a.Segments[0].Text != "one" {
		t.Fatalf("first poll = %+v", a)
	}
	if b := poll(a.Next); len(b.Segments) != 0 || b.Next != 3 {
		t.Fatalf("a poll with nothing new = %+v", b)
	}
	_, _ = l.Append(meeting.LiveThem, 1, 2, "four")
	if c := poll(a.Next); len(c.Segments) != 1 || c.Segments[0].Seq != 4 || c.Next != 4 {
		t.Fatalf("poll after one more = %+v", c)
	}
	if rec := call(t, mux, "GET", "/v1/meetings/"+m.ID+"/live?after=-1", ""); rec.Code != http.StatusBadRequest {
		t.Errorf("after=-1 = %d, want 400", rec.Code)
	}
	if rec := call(t, mux, "GET", "/v1/meetings/"+m.ID+"/live?after=x", ""); rec.Code != http.StatusBadRequest {
		t.Errorf("after=x = %d, want 400", rec.Code)
	}
	if rec := call(t, mux, "GET", "/v1/meetings/nope/live", ""); rec.Code != http.StatusNotFound {
		t.Errorf("unknown meeting = %d, want 404", rec.Code)
	}
}

// liveQuiet makes the dictation quiet window short enough for a test to wait out.
func liveQuiet(t *testing.T) {
	t.Helper()
	old := interactiveQuiet
	interactiveQuiet = 120 * time.Millisecond
	t.Cleanup(func() { interactiveQuiet = old })
}

// Why a caption is held, and in what order. Each line of liveHold is a guard whose breakage shows nowhere but in a
// dictation that pastes late.
// Mutations (internal/daemon/meetings_live.go liveHold): delete `d.inflight.Load() > 0 ||` -> RED on "a request in
// flight"; delete `time.Since(...) < interactiveQuiet ||` -> RED on "just after one"; delete `d.sttSessions() > 0` ->
// RED on "a dictation session open"; `lvl >= livePressureHold` -> `lvl > livePressureHold` -> RED on level 2;
// delete the `d.liveLowPower()` branch -> RED on "low power".
func TestLiveHoldReasons(t *testing.T) {
	liveQuiet(t)
	d, _ := meetingFixture(t, unifiedMemory)
	old := memoryPressureLevel
	t.Cleanup(func() { memoryPressureLevel = old })
	memoryPressureLevel = func() int { return 1 }
	oldPmset := pmsetOutput
	t.Cleanup(func() { pmsetOutput = oldPmset })
	lowPower := false
	pmsetOutput = func(_ context.Context, args ...string) ([]byte, error) {
		if len(args) == 2 { // -g batt
			return []byte("Now drawing from 'Battery Power'\n"), nil
		}
		if lowPower {
			return []byte(" lowpowermode         1\n"), nil
		}
		return []byte(" lowpowermode         0\n"), nil
	}
	expect := func(what, want string) {
		t.Helper()
		if got := d.liveHold(); got != want {
			t.Fatalf("%s: hold = %q, want %q", what, got, want)
		}
	}
	time.Sleep(interactiveQuiet) // the daemon's own start counts as quiet only once the window passed
	expect("nothing going on (on battery, not low power)", "")

	end := d.beginInteractive()
	expect("a request in flight", "dictation")
	end()
	expect("just after one", "dictation")
	time.Sleep(interactiveQuiet + 30*time.Millisecond)
	expect("after the quiet window", "")

	d.noteSTTSession("0123456789abcdef0123456789abcdef")
	expect("a dictation session open", "dictation")
	d.dropSTTSession("0123456789abcdef0123456789abcdef")
	expect("the session closed", "")

	memoryPressureLevel = func() int { return 2 }
	expect("memory pressure: warning", "memory")
	memoryPressureLevel = func() int { return 4 }
	expect("memory pressure: critical", "memory")
	memoryPressureLevel = func() int { return 0 }
	expect("pressure unreadable", "")
	memoryPressureLevel = func() int { return 1 }

	lowPower = true
	d.live.powerAt = time.Time{} // the cached read is stale
	expect("low power mode", "power")
	lowPower = false
	d.live.powerAt = time.Time{}
	expect("low power mode off again", "")

	memoryPressureLevel = func() int { return 2 }
	end = d.beginInteractive()
	expect("dictation and memory together: dictation is named", "dictation")
	end()
}

// pcmFile writes a channel: quiet seconds then speech seconds then quiet seconds.
func pcmFile(t *testing.T, path string, quiet1, speech, quiet2 int) {
	t.Helper()
	var s []int16
	s = append(s, make([]int16, quiet1*meeting.SampleRate)...)
	for range speech * meeting.SampleRate {
		s = append(s, 5000)
	}
	s = append(s, make([]int16, quiet2*meeting.SampleRate)...)
	b := make([]byte, 2*len(s))
	for i, v := range s {
		binary.LittleEndian.PutUint16(b[2*i:], uint16(v))
	}
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
}

// The journey and the guard together: a meeting recording on Apple Silicon is captioned; while a dictation is in
// flight nothing is decoded, and the captions resume only after the quiet window — the real worker, the real
// liveHold and the real d.interactive wrapper of the dictation routes.
// Mutation: internal/daemon/meetings_live.go liveHold, delete `d.inflight.Load() > 0 ||` -> RED (a decode runs
// while the dictation request is open).
func TestLiveCaptionsNeverDecodeWhileADictationIsInFlight(t *testing.T) {
	liveQuiet(t)
	d, mux := meetingFixture(t, unifiedMemory)
	var mu sync.Mutex
	var decodes []time.Time
	d.live.decode = func(context.Context, []byte) (string, error) {
		mu.Lock()
		decodes = append(decodes, time.Now())
		mu.Unlock()
		return "hello from the call", nil
	}
	count := func() int { mu.Lock(); defer mu.Unlock(); return len(decodes) }

	// a dictation request held open: the daemon's own wrapper around a handler of the interactive routes
	started, release := make(chan struct{}), make(chan struct{})
	srv := httptest.NewServer(d.interactive(func(w http.ResponseWriter, _ *http.Request) {
		close(started)
		<-release
	}))
	var releaseOnce sync.Once
	closeRelease := func() { releaseOnce.Do(func() { close(release) }) }
	t.Cleanup(func() { closeRelease(); srv.Close() }) // a failed assertion must not leave the request open
	if !slices.Contains(interactiveRoutes, "POST /v1/audio/transcriptions/sessions/{id}/audio") {
		t.Fatal("the dictation session route is not wrapped by d.interactive")
	}
	reqDone := make(chan struct{})
	go func() {
		resp, err := http.Post(srv.URL, "text/plain", nil)
		if err == nil {
			_ = resp.Body.Close()
		}
		close(reqDone)
	}()
	<-started

	rec := call(t, mux, "POST", "/v1/meetings", `{"title":"Call"}`)
	var created createMeetingResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create = %d %s", rec.Code, rec.Body)
	}
	if _, ok := d.live.state(created.ID); !ok {
		t.Fatal("no live worker started for a recording on Apple Silicon")
	}
	pcmFile(t, filepath.Join(created.Dir, meeting.MePCM), 1, 2, 1)
	pcmFile(t, filepath.Join(created.Dir, meeting.ThemPCM), 1, 2, 1)

	time.Sleep(400 * time.Millisecond)
	if n := count(); n != 0 {
		t.Fatalf("%d decodes while a dictation request was in flight", n)
	}
	st := call(t, mux, "GET", "/v1/meetings/"+created.ID+"/live", "")
	if !strings.Contains(st.Body.String(), `"paused":"dictation"`) || !strings.Contains(st.Body.String(), `"lagging":true`) {
		t.Fatalf("the app is not told captions are held for the dictation: %s", st.Body)
	}

	released := time.Now()
	closeRelease()
	<-reqDone
	deadline := time.Now().Add(5 * time.Second)
	for count() < 2 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	mu.Lock()
	first := decodes[0]
	mu.Unlock()
	if count() < 2 {
		t.Fatalf("captions did not resume after the dictation: %d decodes", count())
	}
	if first.Sub(released) < interactiveQuiet-20*time.Millisecond {
		t.Fatalf("the first decode came %v after the dictation ended, inside the %v quiet window", first.Sub(released), interactiveQuiet)
	}
	a, err := d.Live(created.ID, 0, 0)
	if err != nil || len(a.Segments) != 2 || a.Segments[0].Text != "hello from the call" || !a.State.Recording || !a.State.Active {
		t.Fatalf("live = %+v (%v), want two captions on a recording meeting", a, err)
	}

	// the worker ends with the recording and the final pass is queued as always
	if rec := call(t, mux, "POST", "/v1/meetings/"+created.ID+"/finish", ""); rec.Code != http.StatusAccepted {
		t.Fatalf("finish = %d", rec.Code)
	}
	for time.Now().Before(deadline) {
		if _, ok := d.live.state(created.ID); !ok {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the live worker is still running after the meeting finished")
}

// On Intel, a recording starts no worker unless the user turned captions on; turning them off mid-call stops it.
func TestLiveWorkerStartsOnlyWhenEnabledAndStopsWhenSwitchedOff(t *testing.T) {
	d, mux := meetingFixture(t, nil) // discrete memory: off by default
	d.live.decode = func(context.Context, []byte) (string, error) { return "x", nil }
	rec := call(t, mux, "POST", "/v1/meetings", `{}`)
	var created createMeetingResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	if _, ok := d.live.state(created.ID); ok {
		t.Fatal("a worker runs on an Intel Mac that never turned captions on")
	}
	if rec := call(t, mux, "PUT", "/v1/meetings/settings", `{"live_captions":true}`); rec.Code != http.StatusOK {
		t.Fatalf("PUT = %d", rec.Code)
	}
	if _, ok := d.live.state(created.ID); !ok {
		t.Fatal("turning captions on did not start the worker of the meeting being recorded")
	}
	if rec := call(t, mux, "PUT", "/v1/meetings/settings", `{"live_captions":false}`); rec.Code != http.StatusOK {
		t.Fatalf("PUT = %d", rec.Code)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := d.live.state(created.ID); !ok {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("turning captions off did not stop the worker")
}

// Two requests that each change one field cannot overwrite one another with what they read: the retention the user
// chose decides whether audio is deleted. Many of both run at once; the retention must be the one chosen.
// Mutation: internal/meeting/retention.go UpdateSettings, delete `s.settingsMu.Lock()` -> RED (the retention
// reverts to 30 under the live toggles).
func TestConcurrentSettingsPutsDoNotLoseTheRetention(t *testing.T) {
	_, mux := meetingFixture(t, nil)
	if rec := call(t, mux, "PUT", "/v1/meetings/settings", `{"retention_days":90}`); rec.Code != http.StatusOK {
		t.Fatal(rec.Body)
	}
	var wg sync.WaitGroup
	for i := range 40 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			body := `{"live_captions":true}`
			if i%2 == 1 {
				body = `{"live_captions":false}`
			}
			if rec := call(t, mux, "PUT", "/v1/meetings/settings", body); rec.Code != http.StatusOK {
				t.Error(rec.Body)
			}
		}()
		if i == 20 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if rec := call(t, mux, "PUT", "/v1/meetings/settings", `{"retention_days":0}`); rec.Code != http.StatusOK {
					t.Error(rec.Body)
				}
			}()
		}
	}
	wg.Wait()
	if got := settingsOf(t, mux); got.RetentionDays != 0 {
		t.Fatalf("retention = %d after a concurrent change to never-delete, want 0", got.RetentionDays)
	}
}

// Two calls recording at once: their captions are decoded one at a time, so a dictation never waits behind two
// of them, and a worker that waited for the other's decode asks the hold again once it has the turn.
// Mutation: internal/daemon/meetings_live.go decoder, delete `m.decodeMu.Lock()` -> RED (two decodes in flight);
// delete the `if m.d.liveHold() != "" {` block -> RED (a decode runs on a hold that began while it waited).
func TestLiveDecodesAreOneAtATimeAcrossRecordingsAndRecheckTheHold(t *testing.T) {
	liveQuiet(t)
	d, _ := meetingFixture(t, unifiedMemory)
	var mu sync.Mutex
	inFlight, maxInFlight, calls := 0, 0, 0
	entered := make(chan struct{}, 8)
	release := make(chan struct{})
	d.live.decode = func(context.Context, []byte) (string, error) {
		mu.Lock()
		inFlight++
		calls++
		maxInFlight = max(maxInFlight, inFlight)
		mu.Unlock()
		entered <- struct{}{}
		<-release
		mu.Lock()
		inFlight--
		mu.Unlock()
		return "x", nil
	}
	decode := d.live.decoder()
	run := func() { _, _ = decode(context.Background(), nil) }
	time.Sleep(interactiveQuiet + 30*time.Millisecond)
	go run()
	<-entered
	second := make(chan struct{})
	go func() { run(); close(second) }()
	time.Sleep(100 * time.Millisecond) // the second waits for the turn
	mu.Lock()
	if maxInFlight != 1 {
		t.Fatalf("%d decodes in flight at once", maxInFlight)
	}
	mu.Unlock()
	end := d.beginInteractive() // a dictation begins while the second one waits
	close(release)
	<-second
	end()
	mu.Lock()
	defer mu.Unlock()
	if calls != 1 {
		t.Fatalf("%d decodes, want 1: the second must see the dictation that began while it waited", calls)
	}
}
