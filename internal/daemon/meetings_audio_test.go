package daemon

import (
	"bytes"
	"encoding/binary"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/meeting"
)

func pcmBytes(s []int16) []byte {
	var b bytes.Buffer
	_ = binary.Write(&b, binary.LittleEndian, s)
	return b.Bytes()
}

// audioMeeting is a finished meeting with synthetic channel files (nil means no file).
func audioMeeting(t *testing.T, d *Daemon, me, them []int16) (meeting.Manifest, string) {
	t.Helper()
	m, dir, err := d.Meet.Store.Create(meeting.Manifest{Title: "Audio"}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if me != nil {
		_ = os.WriteFile(filepath.Join(dir, meeting.MePCM), pcmBytes(me), 0o600)
	}
	if them != nil {
		_ = os.WriteFile(filepath.Join(dir, meeting.ThemPCM), pcmBytes(them), 0o600)
	}
	got, err := d.Meet.Store.Update(m.ID, func(mm *meeting.Manifest) { mm.Status = meeting.StatusDone })
	if err != nil {
		t.Fatal(err)
	}
	return *got, dir
}

func audioGet(h http.Handler, id, rng string) *httptest.ResponseRecorder {
	// What AVPlayer sends: a plain GET to the loopback address, no JSON, no custom header; a Range when it seeks.
	req := httptest.NewRequest("GET", "http://127.0.0.1:8094/v1/meetings/"+id+"/audio", nil)
	if rng != "" {
		req.Header.Set("Range", rng)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// The whole mix: a 44-byte header, then clamp(me + them) per sample, the shorter channel padded; served as audio/wav
// with a length and range support, through the guard, with the request AVPlayer makes.
// Mutation: internal/meeting/mixwav.go mixSample, drop the clamp -> RED (wrapped samples).
func TestAudioServesTheSaturatedMixAsWAV(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	h := servedFor(t, d)
	m, _ := audioMeeting(t, d, []int16{30000, -30000, 100}, []int16{30000, -30000, -250, 7})
	rec := audioGet(h, m.ID, "")
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "audio/wav" {
		t.Fatalf("%d %q %s", rec.Code, rec.Header().Get("Content-Type"), rec.Body.String()[:min(80, rec.Body.Len())])
	}
	body := rec.Body.Bytes()
	if len(body) != 44+4*2 || rec.Header().Get("Content-Length") != strconv.Itoa(len(body)) || rec.Header().Get("Accept-Ranges") != "bytes" {
		t.Fatalf("len %d, headers %v", len(body), rec.Header())
	}
	var got [4]int16
	for i := range got {
		got[i] = int16(binary.LittleEndian.Uint16(body[44+2*i:]))
	}
	if got != [4]int16{32767, -32768, -150, 7} {
		t.Errorf("samples = %v", got)
	}
}

// A player seeks with Range: 206, the bytes asked for, and Content-Range of the whole file.
// Mutation: internal/daemon/meetings_audio.go handleMeetingAudio, io.Copy the reader instead of
// http.ServeContent -> RED (200 and the whole body).
func TestAudioSupportsRangeRequests(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	h := servedFor(t, d)
	n := 5000
	me, them := make([]int16, n), make([]int16, n)
	for i := range me {
		me[i], them[i] = int16(i), int16(2*i)
	}
	m, _ := audioMeeting(t, d, me, them)
	whole := audioGet(h, m.ID, "").Body.Bytes()
	for _, c := range []struct {
		hdr       string
		from, end int
	}{{"bytes=44-47", 44, 48}, {"bytes=1001-1500", 1001, 1501}, {"bytes=9000-", 9000, len(whole)}, {"bytes=-10", len(whole) - 10, len(whole)}} {
		rec := audioGet(h, m.ID, c.hdr)
		if rec.Code != http.StatusPartialContent {
			t.Errorf("%s: %d", c.hdr, rec.Code)
			continue
		}
		if !bytes.Equal(rec.Body.Bytes(), whole[c.from:c.end]) {
			t.Errorf("%s: wrong bytes", c.hdr)
		}
		if want := "bytes " + strconv.Itoa(c.from) + "-" + strconv.Itoa(c.end-1) + "/" + strconv.Itoa(len(whole)); rec.Header().Get("Content-Range") != want {
			t.Errorf("%s: Content-Range %q, want %q", c.hdr, rec.Header().Get("Content-Range"), want)
		}
	}
	if rec := audioGet(h, m.ID, "bytes=99999999-"); rec.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Errorf("past the end: %d", rec.Code)
	}
}

// A channel that was never written is silence; a file with a stray byte loses only that byte.
func TestAudioWithAMissingChannelAndOddBytes(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	m, dir := audioMeeting(t, d, nil, []int16{9, 8, 7})
	rec := call(t, mux, "GET", "/v1/meetings/"+m.ID+"/audio", "")
	if rec.Code != http.StatusOK || rec.Body.Len() != 44+6 {
		t.Fatalf("one channel: %d, %d bytes", rec.Code, rec.Body.Len())
	}
	f, _ := os.OpenFile(filepath.Join(dir, meeting.ThemPCM), os.O_APPEND|os.O_WRONLY, 0)
	_, _ = f.Write([]byte{0x55})
	_ = f.Close()
	rec = call(t, mux, "GET", "/v1/meetings/"+m.ID+"/audio", "")
	if rec.Code != http.StatusOK || rec.Body.Len() != 44+6 {
		t.Fatalf("odd file: %d, %d bytes", rec.Code, rec.Body.Len())
	}
}

// 404 for an id nobody has, 409 while the app is still writing, 410 once retention has taken the audio (the flag is
// the notion the app already uses) and when the files are simply not there.
// Mutation: internal/daemon/meetings_audio.go handleMeetingAudio, delete the `m.AudioDeleted` check -> RED (the
// files are still on disk in the flagged case, so it would be served).
func TestAudioRefusals(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	get := func(id string) *httptest.ResponseRecorder {
		return call(t, mux, "GET", "/v1/meetings/"+id+"/audio", "")
	}
	if rec := get("20260101-000000-abcdef"); rec.Code != http.StatusNotFound {
		t.Errorf("unknown id: %d", rec.Code)
	}
	if rec := get("nope"); rec.Code != http.StatusNotFound {
		t.Errorf("malformed id: %d", rec.Code)
	}
	rec, _ := audioMeeting(t, d, []int16{1, 2}, []int16{3, 4})
	_, _ = d.Meet.Store.Update(rec.ID, func(m *meeting.Manifest) { m.Status = meeting.StatusRecording })
	if r := get(rec.ID); r.Code != http.StatusConflict {
		t.Errorf("recording: %d %s", r.Code, r.Body)
	}
	_, _ = d.Meet.Store.Update(rec.ID, func(m *meeting.Manifest) { m.Status, m.AudioDeleted = meeting.StatusDone, true })
	if r := get(rec.ID); r.Code != http.StatusGone {
		t.Errorf("audio_deleted: %d %s", r.Code, r.Body)
	}
	gone, dir := audioMeeting(t, d, []int16{1}, []int16{2})
	_ = os.Remove(filepath.Join(dir, meeting.MePCM))
	_ = os.Remove(filepath.Join(dir, meeting.ThemPCM))
	if r := get(gone.ID); r.Code != http.StatusGone {
		t.Errorf("files gone: %d %s", r.Code, r.Body)
	}
	empty, _ := audioMeeting(t, d, []int16{}, nil)
	if r := get(empty.ID); r.Code != http.StatusGone {
		t.Errorf("empty recording: %d %s", r.Code, r.Body)
	}
}
