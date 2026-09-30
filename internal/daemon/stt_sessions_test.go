package daemon

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/go-mcpserver"
	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// sttVADModel points the daemon's VAD model at a file that exists, so the
// next spawned ox-stt gets --vad and the fake serves the session routes.
func sttVADModel(t *testing.T, d *Daemon, dir string) string {
	t.Helper()
	p := filepath.Join(dir, "silero.bin")
	if err := os.WriteFile(p, []byte("fake vad"), 0o644); err != nil {
		t.Fatal(err)
	}
	d.Cfg.STTVADModel = p
	return p
}

// sessReq issues one request against the test server and reads the whole
// response body.
func sessReq(t *testing.T, method, url, ctype string, body []byte) (int, []byte) {
	t.Helper()
	var rdr io.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, url, rdr)
	if err != nil {
		t.Fatal(err)
	}
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, b
}

func sessBase(srv *httptest.Server) string {
	return srv.URL + "/v1/audio/transcriptions/sessions"
}

// The four session routes proxy to the resident ox-stt server verbatim:
// create hands back its id, each audio chunk is forwarded as an
// exact-length application/octet-stream body, finish returns the joined
// transcript, delete drops the session (a later chunk then sees the
// upstream 404 pass through).
// Mutation: forward audio with Content-Type application/json -> RED (the
// fake's contract check answers 415 and the logged content type is wrong).
func TestSTTSessionProxyRoundTrip(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	log := sttSetupServer(t, d, dir)
	sttVADModel(t, d, dir)
	srv := transcriptionServer(t, d)
	base := sessBase(srv)

	code, body := sessReq(t, http.MethodPost, base, "application/json", []byte("{}"))
	if code != http.StatusOK {
		t.Fatalf("create: status %d body %s", code, body)
	}
	var created struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &created); err != nil || !sessionIDRe.MatchString(created.ID) {
		t.Fatalf("create body = %s, want {\"id\":<32 lowercase hex>}", body)
	}
	id := created.ID
	firstID := id

	chunks := [][]byte{bytes.Repeat([]byte{1}, 640), bytes.Repeat([]byte{2}, 1280)}
	for i, chunk := range chunks {
		code, body = sessReq(t, http.MethodPost, base+"/"+id+"/audio", "application/octet-stream", chunk)
		if code != http.StatusOK {
			t.Fatalf("audio %d: status %d body %s", i+1, code, body)
		}
		var dec struct {
			Segments []struct {
				Text string `json:"text"`
			} `json:"segments"`
		}
		if err := json.Unmarshal(body, &dec); err != nil || len(dec.Segments) != 1 {
			t.Fatalf("audio %d body = %s", i+1, body)
		}
		if want := fmt.Sprintf("chunk %d", i+1); dec.Segments[0].Text != want {
			t.Fatalf("audio %d segment text = %q, want %q", i+1, dec.Segments[0].Text, want)
		}
	}

	code, body = sessReq(t, http.MethodPost, base+"/"+id+"/finish", "application/json", []byte("{}"))
	if code != http.StatusOK {
		t.Fatalf("finish: status %d body %s", code, body)
	}
	var fin struct {
		Done bool   `json:"done"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(body, &fin); err != nil || !fin.Done || fin.Text != "chunk 1 chunk 2" {
		t.Fatalf("finish body = %s, want done:true with the chunks joined", body)
	}

	// A second session for the delete leg: finish has already consumed id.
	code, body = sessReq(t, http.MethodPost, base, "application/json", []byte("{}"))
	if code != http.StatusOK {
		t.Fatalf("second create: status %d body %s", code, body)
	}
	if err := json.Unmarshal(body, &created); err != nil || !sessionIDRe.MatchString(created.ID) {
		t.Fatalf("second create body = %s", body)
	}
	id = created.ID
	code, body = sessReq(t, http.MethodDelete, base+"/"+id, "", nil)
	if code != http.StatusOK {
		t.Fatalf("delete: status %d body %s", code, body)
	}
	code, _ = sessReq(t, http.MethodPost, base+"/"+id+"/audio", "application/octet-stream", chunks[0])
	if code != http.StatusNotFound {
		t.Fatalf("audio after delete: status %d, want the upstream 404", code)
	}

	want := []string{
		"sess-audio " + firstID + " 640 application/octet-stream",
		"sess-audio " + firstID + " 1280 application/octet-stream",
		"sess-audio " + id + " 640 application/octet-stream",
	}
	if got := linesWith(sttLogLines(t, log), "sess-audio "); !reflect.DeepEqual(got, want) {
		t.Fatalf("sess-audio records = %v, want %v", got, want)
	}
}

// Guard's octet-stream exemption applies ONLY to a well-formed
// session-audio path — everywhere else the POST is still a 415.
// Mutation: widen the exemption to a path prefix
// (/v1/audio/transcriptions/) -> RED (the refused cases reach the
// handlers and answer 503).
func TestGuardSTTSessions(t *testing.T) {
	h := servedHandlerSTTOff(t)
	id := strings.Repeat("a", 32)
	cases := []struct {
		name, path string
		want       int
	}{
		{"audio chunk accepted", "/v1/audio/transcriptions/sessions/" + id + "/audio", http.StatusServiceUnavailable},
		{"octet-stream on transcriptions", "/v1/audio/transcriptions", http.StatusUnsupportedMediaType},
		{"octet-stream on create", "/v1/audio/transcriptions/sessions", http.StatusUnsupportedMediaType},
		{"octet-stream on finish", "/v1/audio/transcriptions/sessions/" + id + "/finish", http.StatusUnsupportedMediaType},
		{"octet-stream with bad id", "/v1/audio/transcriptions/sessions/notanid/audio", http.StatusUnsupportedMediaType},
		{"octet-stream with encoded slash", "/v1/audio/transcriptions/sessions/" + id[:31] + "%2Ff/audio", http.StatusUnsupportedMediaType},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:8094"+c.path, bytes.NewReader([]byte{1, 2, 3, 4}))
			req.Header.Set("Content-Type", "application/octet-stream")
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != c.want {
				t.Fatalf("POST %s octet-stream: status %d, want %d (body %s)", c.path, rec.Code, c.want, rec.Body.String())
			}
		})
	}
}

// servedHandlerSTTOff is servedHandler with the resident STT server off:
// a session handler that is reached answers 503 without spawning anything,
// so the assertions cleanly separate "through the guard" (503) from
// "stopped by the guard" (415).
func servedHandlerSTTOff(t *testing.T) http.Handler {
	t.Helper()
	d := newTestDaemonSTT(t, t.TempDir(), func(c *config.Config) { c.STTServer = "off" }, nil, nil)
	cfg := d.ServerConfig("test")
	h, err := mcpserver.Build(mcpserver.NewServer(&mcp.Implementation{Name: "ox-say", Version: "test"}, cfg), cfg)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

// A session id that is not 32 lowercase hex is a 404 straight from the
// route (or from the mux, for shapes that cannot match) — the STT server
// is never contacted with it.
// Mutation: drop the sessionIDRe check in the handlers -> RED (the fake
// logs the forwarded calls).
func TestSTTSessionIDValidation(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	log := sttSetupServer(t, d, dir)
	sttVADModel(t, d, dir)
	srv := transcriptionServer(t, d)
	base := sessBase(srv)

	// Bring the server up so a forwarded call would land in its log.
	if code, body := sessReq(t, http.MethodPost, base, "application/json", []byte("{}")); code != http.StatusOK {
		t.Fatalf("create: status %d body %s", code, body)
	}

	bad := []string{
		"../x",                           // traversal shape — the mux never routes it
		strings.Repeat("A", 32),          // uppercase hex
		strings.Repeat("a", 31),          // short
		strings.Repeat("a", 33),          // long
		strings.Repeat("z", 32),          // not hex
		strings.Repeat("a", 31) + "%2Ff", // a slash smuggled inside the segment
	}
	for _, id := range bad {
		if code, _ := sessReq(t, http.MethodPost, base+"/"+id+"/audio", "application/octet-stream", []byte{0, 0, 0, 0}); code != http.StatusNotFound {
			t.Fatalf("audio with id %q: status %d, want 404", id, code)
		}
		if code, _ := sessReq(t, http.MethodPost, base+"/"+id+"/finish", "application/json", []byte("{}")); code != http.StatusNotFound {
			t.Fatalf("finish with id %q: status %d, want 404", id, code)
		}
		if code, _ := sessReq(t, http.MethodDelete, base+"/"+id, "", nil); code != http.StatusNotFound {
			t.Fatalf("delete with id %q: status %d, want 404", id, code)
		}
	}
	if got := linesWith(sttLogLines(t, log), "sess-"); len(got) != 0 {
		t.Fatalf("fake saw session traffic for malformed ids: %v", got)
	}
}

// OX_SAY_STT_SERVER=off makes every session route a 503 — there is no
// resident server to hold sessions.
// Mutation: drop the STTSup==nil check in handleSTTSessionCreate /
// sttSessionOp -> RED (nil-pointer panic, or the request reaches a
// different status).
func TestSTTSessionsServerOff(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, func(c *config.Config) { c.STTServer = "off" }, nil, nil)
	srv := transcriptionServer(t, d)
	base := sessBase(srv)
	id := strings.Repeat("a", 32)

	cases := []struct {
		method, url, ctype string
		body               []byte
	}{
		{http.MethodPost, base, "application/json", []byte("{}")},
		{http.MethodPost, base + "/" + id + "/audio", "application/octet-stream", []byte{0, 0, 0, 0}},
		{http.MethodPost, base + "/" + id + "/finish", "application/json", []byte("{}")},
		{http.MethodDelete, base + "/" + id, "", nil},
	}
	// The refusal is the server's own flat {"error":"…"} shape — the same
	// JSON a client parses for an upstream error.
	var e struct {
		Error string `json:"error"`
	}
	for _, c := range cases {
		code, body := sessReq(t, c.method, c.url, c.ctype, c.body)
		if code != http.StatusServiceUnavailable {
			t.Fatalf("%s %s: status %d, want 503 (body %s)", c.method, c.url, code, body)
		}
		e.Error = ""
		if err := json.Unmarshal(body, &e); err != nil || e.Error == "" ||
			!strings.Contains(e.Error, "STT server") {
			t.Fatalf("%s %s: body %s, want flat {\"error\":…STT server…}", c.method, c.url, body)
		}
	}
}

// With the STT server enabled but not running, the per-session routes
// answer 404 — sessions do not survive a restart, so nothing can be
// proxied and the server must not be started for them.
// Mutation: EnsureReady instead of ReadyURL in sttSessionOp -> RED (a
// serve spawn appears in the log).
func TestSTTSessionNotReady(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	log := sttSetupServer(t, d, dir)
	sttVADModel(t, d, dir)
	srv := transcriptionServer(t, d)
	base := sessBase(srv)
	id := strings.Repeat("a", 32)

	cases := []struct {
		method, url, ctype string
		body               []byte
	}{
		{http.MethodPost, base + "/" + id + "/audio", "application/octet-stream", []byte{0, 0, 0, 0}},
		{http.MethodPost, base + "/" + id + "/finish", "application/json", []byte("{}")},
		{http.MethodDelete, base + "/" + id, "", nil},
	}
	for _, c := range cases {
		code, body := sessReq(t, c.method, c.url, c.ctype, c.body)
		if code != http.StatusNotFound {
			t.Fatalf("%s %s: status %d, want 404 (body %s)", c.method, c.url, code, body)
		}
		if !strings.Contains(string(body), "session not found") {
			t.Fatalf("%s %s: body %s, want the not-found message", c.method, c.url, body)
		}
	}
	if n := len(linesWith(sttLogLines(t, log), "serve\t")); n != 0 {
		t.Fatalf("STT server spawned %d times for session sub-routes", n)
	}
	if s := d.STTSup.State(); s != engine.StateStopped {
		t.Fatalf("STT server state = %s, want stopped", s)
	}
}

// A create inside the server's crash-backoff window fails fast with 503 —
// it pays no cool-down sleep and spawns no new child, same shape as the
// transcription fallback.
// Mutation: drop the Backoff() check in handleSTTSessionCreate -> RED (the
// in-window create sleeps out the cool-down and spawns a second child).
func TestSTTSessionCreateBackoff(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_STT_SERVE_EXIT", "1")
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	log := sttSetupServer(t, d, dir)
	sttVADModel(t, d, dir)
	srv := transcriptionServer(t, d)
	base := sessBase(srv)

	code, _ := sessReq(t, http.MethodPost, base, "application/json", []byte("{}"))
	if code != http.StatusServiceUnavailable {
		t.Fatalf("first create (failed start): status %d, want 503", code)
	}
	win := d.STTSup.Backoff()
	if win <= 0 {
		t.Fatal("no backoff window after the failed serve start")
	}
	serves := len(linesWith(sttLogLines(t, log), "serve\t"))

	start := time.Now()
	code, _ = sessReq(t, http.MethodPost, base, "application/json", []byte("{}"))
	if el := time.Since(start); code != http.StatusServiceUnavailable || el >= win {
		t.Fatalf("create in backoff: status %d in %s (window %s), want a fast 503", code, el, win)
	}
	if n := len(linesWith(sttLogLines(t, log), "serve\t")); n != serves {
		t.Fatalf("serve spawns = %d, want %d — the backoff create spawned a child", n, serves)
	}
}

// --vad reaches the spawned ox-stt only when the model file exists at
// spawn time: a missing file keeps today's server working with sessions
// unavailable (create answers the upstream 501), and the fake's no-VAD
// knob passes its 501 through either way.
// Mutation: append --vad unconditionally in the STT Args func -> RED (the
// missing-model argv carries it and the create returns 200).
func TestSTTSessionVADArg(t *testing.T) {
	// Model file exists: --vad <path> in argv, sessions work.
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	log := sttSetupServer(t, d, dir)
	vad := sttVADModel(t, d, dir)
	srv := transcriptionServer(t, d)
	if code, body := sessReq(t, http.MethodPost, sessBase(srv), "application/json", []byte("{}")); code != http.StatusOK {
		t.Fatalf("create with VAD model: status %d body %s", code, body)
	}
	argv := lastServeArgv(t, log)
	found := false
	for i, a := range argv {
		if a == "--vad" {
			found = i+1 < len(argv) && argv[i+1] == vad
		}
	}
	if !found {
		t.Fatalf("serve argv %v missing --vad %s", argv, vad)
	}

	// Model file missing: no --vad, and the fake 501s the session create.
	dir2 := t.TempDir()
	d2 := newTestDaemonSTT(t, dir2, nil, nil, nil)
	log2 := sttSetupServer(t, d2, dir2)
	d2.Cfg.STTVADModel = filepath.Join(dir2, "missing-vad.bin")
	srv2 := transcriptionServer(t, d2)
	if code, body := sessReq(t, http.MethodPost, sessBase(srv2), "application/json", []byte("{}")); code != http.StatusNotImplemented {
		t.Fatalf("create without VAD model: status %d, want the upstream 501 (body %s)", code, body)
	}
	if argv := lastServeArgv(t, log2); argvHas(argv, "--vad") {
		t.Fatalf("serve argv %v carries --vad for a missing model", argv)
	}

	// The no-VAD knob forces 501 even when --vad was passed.
	dir3 := t.TempDir()
	t.Setenv("OXSAY_FAKE_STT_NO_VAD", "1")
	d3 := newTestDaemonSTT(t, dir3, nil, nil, nil)
	sttSetupServer(t, d3, dir3)
	sttVADModel(t, d3, dir3)
	srv3 := transcriptionServer(t, d3)
	if code, body := sessReq(t, http.MethodPost, sessBase(srv3), "application/json", []byte("{}")); code != http.StatusNotImplemented {
		t.Fatalf("create with OXSAY_FAKE_STT_NO_VAD=1: status %d, want 501 (body %s)", code, body)
	}
}

// Bodies past the caps are refused at the daemon: an audio chunk over
// 1,920,000 bytes (30 s of 16 kHz f32le mono) and a JSON route body over
// 4 KB both get 413 and never reach the server.
// Mutation: drop the `len(body) > limit` check in sttSessionProxy -> RED
// (the over-cap chunk reaches the fake and lands in its log).
func TestSTTSessionBodyCaps(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	log := sttSetupServer(t, d, dir)
	sttVADModel(t, d, dir)
	srv := transcriptionServer(t, d)
	base := sessBase(srv)

	code, body := sessReq(t, http.MethodPost, base, "application/json", []byte("{}"))
	if code != http.StatusOK {
		t.Fatalf("create: status %d body %s", code, body)
	}
	var created struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &created); err != nil {
		t.Fatalf("create body = %s", body)
	}
	id := created.ID

	code, _ = sessReq(t, http.MethodPost, base+"/"+id+"/audio", "application/octet-stream",
		make([]byte, 1920000+1))
	if code != http.StatusRequestEntityTooLarge {
		t.Fatalf("audio over 30 s: status %d, want 413", code)
	}
	code, _ = sessReq(t, http.MethodPost, base+"/"+id+"/finish", "application/json",
		make([]byte, 4<<10+1))
	if code != http.StatusRequestEntityTooLarge {
		t.Fatalf("finish over 4 KB: status %d, want 413", code)
	}
	if got := linesWith(sttLogLines(t, log), "sess-"); len(got) != 0 {
		t.Fatalf("over-cap bodies reached the server: %v", got)
	}
}

// A live session's traffic counts as server activity: audio chunks sent
// more often than the idle stop keep the resident server Ready well past
// it.
// Mutation: drop the Guard around the audio proxy -> RED (the server
// idle-stops mid-session and a chunk comes back 404).
func TestSTTSessionKeepsServerAlive(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir,
		func(c *config.Config) { c.STTIdleStop = time.Second },
		nil,
		func(ec *engine.Config) { ec.IdleTick = 50 * time.Millisecond })
	sttSetupServer(t, d, dir)
	sttVADModel(t, d, dir)
	srv := transcriptionServer(t, d)
	base := sessBase(srv)

	code, body := sessReq(t, http.MethodPost, base, "application/json", []byte("{}"))
	if code != http.StatusOK {
		t.Fatalf("create: status %d body %s", code, body)
	}
	var created struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &created); err != nil {
		t.Fatalf("create body = %s", body)
	}
	id := created.ID

	// 15 chunks 150 ms apart ≈ 2.25 s of traffic — over twice the 1 s idle
	// stop, while each gap leaves ~850 ms of slack before an idle tick could
	// fire on a slow machine. Any idle stop mid-session turns a chunk into a
	// 404.
	for i := 0; i < 15; i++ {
		time.Sleep(150 * time.Millisecond)
		code, body = sessReq(t, http.MethodPost, base+"/"+id+"/audio", "application/octet-stream", []byte{0, 0, 0, 0})
		if code != http.StatusOK {
			t.Fatalf("audio %d ~%d ms in: status %d body %s — the idle stop fired mid-session", i+1, 150*(i+1), code, body)
		}
	}
	if s := d.STTSup.State(); s != engine.StateReady {
		t.Fatalf("STT server state = %s after a busy session, want ready", s)
	}
}

// /status exposes the configured VAD model path under stt_vad_model.
// Mutation: drop the "stt_vad_model" key from the Status config map in
// service.go -> RED (cfg["stt_vad_model"] is nil).
func TestStatusSTTVADModel(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	sttSetupServer(t, d, dir)
	vad := sttVADModel(t, d, dir)
	srv := transcriptionServer(t, d)

	resp, err := http.Get(srv.URL + "/status")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var st map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		t.Fatal(err)
	}
	cfg, ok := st["config"].(map[string]any)
	if !ok {
		t.Fatalf("status config missing or not an object: %v", st["config"])
	}
	if cfg["stt_vad_model"] != vad {
		t.Fatalf("stt_vad_model = %v, want %s", cfg["stt_vad_model"], vad)
	}
}
