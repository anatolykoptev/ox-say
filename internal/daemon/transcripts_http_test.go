package daemon

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	mcpserver "github.com/anatolykoptev/go-mcpserver"
	"github.com/anatolykoptev/ox-say/internal/testutil"
	"github.com/anatolykoptev/ox-say/internal/transcripts"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const transcriptPayload = `{"engine":"parakeet","language":"en","duration_s":1.5,"elapsed_s":0.2,` +
	`"text":"zebra quartz sentinel.","segments":[{"s":0.0,"e":1.5,"text":"zebra quartz sentinel."}],` +
	`"words":[{"w":"zebra","s":0.0,"e":0.5,"p":0.99}]}`

// transcriptsRig is a daemon behind the real Guard (go-mcpserver's middleware chain), its STT faked.
type transcriptsRig struct {
	d      *Daemon
	srv    *httptest.Server
	dir    string
	tmpdir string
}

func newTranscriptsRig(t *testing.T) *transcriptsRig {
	t.Helper()
	dir := t.TempDir()
	fakeEnv(t, dir)
	tmpdir := filepath.Join(dir, "tmp")
	if err := os.MkdirAll(tmpdir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", tmpdir)
	t.Setenv("OXSAY_FAKE_STT_JSON", transcriptPayload)
	d := newTestDaemon(t, dir, nil)
	sttSetup(t, d, dir)
	return rigFor(t, d, dir, tmpdir)
}

func rigFor(t *testing.T, d *Daemon, dir, tmpdir string) *transcriptsRig {
	t.Helper()
	cfg := d.ServerConfig("test")
	h, err := mcpserver.Build(mcpserver.NewServer(&mcp.Implementation{Name: "ox-say", Version: "test"}, cfg), cfg)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return &transcriptsRig{d: d, srv: srv, dir: dir, tmpdir: tmpdir}
}

func (r *transcriptsRig) url(p string) string { return r.srv.URL + p }

func (r *transcriptsRig) tmpCount(t *testing.T) int {
	t.Helper()
	entries, err := os.ReadDir(r.tmpdir)
	if err != nil {
		t.Fatal(err)
	}
	return len(entries)
}

func (r *transcriptsRig) do(t *testing.T, method, path string) (int, http.Header, []byte) {
	t.Helper()
	req, err := http.NewRequest(method, r.url(path), nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, b
}

func (r *transcriptsRig) post(t *testing.T, fields map[string]string) (int, []byte) {
	t.Helper()
	resp := postTranscription(t, r.url("/v1/transcripts"), testutil.TinyWAV(), fields)
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

func (r *transcriptsRig) list(t *testing.T) []transcripts.Meta {
	t.Helper()
	code, _, body := r.do(t, http.MethodGet, "/v1/transcripts")
	if code != http.StatusOK {
		t.Fatalf("list status %d (%s)", code, body)
	}
	var out struct {
		Transcripts []transcripts.Meta `json:"transcripts"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatal(err)
	}
	return out.Transcripts
}

func TestTranscriptsRoundTrip(t *testing.T) {
	r := newTranscriptsRig(t)
	code, body := r.post(t, map[string]string{"title": "Тест"})
	if code != http.StatusCreated {
		t.Fatalf("POST status %d (%s)", code, body)
	}
	var m transcripts.Meta
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatal(err)
	}
	if m.Title != "Тест" || !transcripts.ValidID(m.ID) || m.Engine != "parakeet" || m.Seconds != 1.5 || m.Language != "en" {
		t.Fatalf("meta %+v", m)
	}
	if list := r.list(t); len(list) != 1 || list[0].ID != m.ID {
		t.Fatalf("list %+v, want the new id", list)
	}

	for _, c := range []struct{ format, ctype, want string }{
		{"srt", "text/plain", "-->"},
		{"vtt", "text/vtt", "WEBVTT"},
		{"text", "text/plain", "zebra quartz sentinel."},
		{"json", "application/json", `"text":"zebra quartz sentinel."`},
		{"ox_json", "application/json", `"segments"`},
		{"", "application/json", `"text"`},
	} {
		path := "/v1/transcripts/" + m.ID
		if c.format != "" {
			path += "?format=" + c.format
		}
		code, h, b := r.do(t, http.MethodGet, path)
		if code != http.StatusOK || !strings.Contains(string(b), c.want) || !strings.HasPrefix(h.Get("Content-Type"), c.ctype) {
			t.Errorf("format %q: %d %q %s", c.format, code, h.Get("Content-Type"), b)
		}
	}
	if c, _, _ := r.do(t, http.MethodGet, "/v1/transcripts/"+m.ID+"?format=bogus"); c != http.StatusBadRequest {
		t.Errorf("format=bogus: %d, want 400", c)
	}
	if c, _, _ := r.do(t, http.MethodGet, "/v1/transcripts/"+m.ID+"?format=verbose_json"); c != http.StatusBadRequest {
		t.Errorf("format=verbose_json is not offered here: %d, want 400", c)
	}
	if c, _, _ := r.do(t, http.MethodDelete, "/v1/transcripts/"+m.ID); c != http.StatusNoContent {
		t.Fatalf("DELETE: %d, want 204", c)
	}
	if c, _, _ := r.do(t, http.MethodGet, "/v1/transcripts/"+m.ID); c != http.StatusNotFound {
		t.Fatalf("GET after delete: %d, want 404", c)
	}
	if c, _, _ := r.do(t, http.MethodDelete, "/v1/transcripts/"+m.ID); c != http.StatusNotFound {
		t.Fatalf("second DELETE: %d, want 404", c)
	}
	if n := r.tmpCount(t); n != 0 {
		t.Fatalf("%d upload temp files left", n)
	}
}

// F3: a failing STT stores nothing and leaves no upload temp file.
func TestTranscriptsFailedSTTStoresNothing(t *testing.T) {
	r := newTranscriptsRig(t)
	t.Setenv("OXSAY_FAKE_STT_EXIT", "1")
	code, body := r.post(t, map[string]string{"title": "x"})
	if code != http.StatusInternalServerError {
		t.Fatalf("failed STT: status %d (%s), want 500", code, body)
	}
	if list := r.list(t); len(list) != 0 {
		t.Fatalf("a failed transcription left %+v", list)
	}
	entries, _ := os.ReadDir(filepath.Join(r.d.Cfg.Home, "transcripts"))
	if len(entries) != 0 {
		t.Fatalf("store directory holds %d entries after a failure", len(entries))
	}
	if n := r.tmpCount(t); n != 0 {
		t.Fatalf("%d upload temp files left after a failed transcription", n)
	}
}

func TestTranscriptsUploadFailuresLeaveNothing(t *testing.T) {
	r := newTranscriptsRig(t)
	r.d.Cfg.STTMaxUploadMB = 1
	big := bytes.Repeat([]byte{1}, 2<<20)
	resp := postTranscription(t, r.url("/v1/transcripts"), big, nil)
	b, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversize upload: %d (%s), want 413", resp.StatusCode, b)
	}
	if n := r.tmpCount(t); n != 0 {
		t.Fatalf("%d temp files left after an oversize upload", n)
	}
	// no file part at all
	var body bytes.Buffer
	body.WriteString("--xx\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nx\r\n--xx--\r\n")
	resp, err := http.Post(r.url("/v1/transcripts"), "multipart/form-data; boundary=xx", &body)
	if err != nil {
		t.Fatal(err)
	}
	b, _ = io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("no file: %d (%s), want 400", resp.StatusCode, b)
	}
	if list := r.list(t); len(list) != 0 || r.tmpCount(t) != 0 {
		t.Fatalf("leftovers: %+v, %d temp files", list, r.tmpCount(t))
	}
}

func TestTranscriptsRefuseABadTitleBeforeTranscribing(t *testing.T) {
	r := newTranscriptsRig(t)
	log := filepath.Join(r.dir, "stt.log")
	for name, title := range map[string]string{
		"too long": strings.Repeat("я", maxTitleChars+1),
		"bidi":     "evil‮txt",
	} {
		if code, body := r.post(t, map[string]string{"title": title}); code != http.StatusBadRequest {
			t.Errorf("%s title: %d (%s), want 400", name, code, body)
		}
	}
	if _, err := os.Stat(log); err == nil {
		t.Error("the recognizer ran for a request that was refused for its title")
	}
	// control characters are cleaned, as meeting titles are
	code, body := r.post(t, map[string]string{"title": " a\nb\t "})
	var m transcripts.Meta
	_ = json.Unmarshal(body, &m)
	if code != http.StatusCreated || m.Title != "a b" {
		t.Fatalf("clean title: %d %+v", code, m)
	}
}

// ValidID must stop traversal on every route that takes an id.
func TestTranscriptsIDsCannotEscape(t *testing.T) {
	r := newTranscriptsRig(t)
	home := r.d.Cfg.Home
	victim := filepath.Join(home, "victim")
	if err := os.MkdirAll(victim, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"..%2Fvictim", "%2e%2e%2fvictim", "..%2f..%2fvictim", "nope", "20261001-000000-zzzzzz", "20261001-000000-abcdef%2F.."} {
		for _, method := range []string{http.MethodGet, http.MethodDelete} {
			code, _, body := r.do(t, method, "/v1/transcripts/"+id)
			if code != http.StatusBadRequest && code != http.StatusNotFound {
				t.Errorf("%s %s: %d (%s), want 400 or 404", method, id, code, body)
			}
		}
	}
	// the cleaned-path form and the empty id never reach a handler that serves a document
	for _, p := range []string{"/v1/transcripts/", "/v1/transcripts/../victim", "/v1/transcripts//"} {
		for _, method := range []string{http.MethodGet, http.MethodDelete} {
			code, _, body := r.do(t, method, p)
			if code == http.StatusOK || code == http.StatusNoContent {
				t.Errorf("%s %s: %d (%s)", method, p, code, body)
			}
		}
	}
	if _, err := os.Stat(victim); err != nil {
		t.Fatalf("the sibling directory was touched: %v", err)
	}
}

// The upload route is not an interactive one: a long file must not make the voiceover producer yield as if someone
// were dictating. It still counts under busy.transcribing, so an app relaunch waits for it.
func TestTranscriptsPOSTIsNotInteractiveButIsBusy(t *testing.T) {
	r := newTranscriptsRig(t)
	t.Setenv("OXSAY_FAKE_STT_DELAY_MS", "1500")
	done := make(chan int, 1)
	go func() { c, _ := r.post(t, nil); done <- c }()
	testutil.WaitFor(t, 5*time.Second, func() bool { return r.d.transcribing.Load() > 0 }, "transcription to start")
	if n := r.d.inflight.Load(); n != 0 {
		t.Errorf("inflight = %d during a file transcription, want 0 (not an interactive route)", n)
	}
	if c := <-done; c != http.StatusCreated {
		t.Fatalf("POST status %d", c)
	}
}

// Transcripts are private text: nothing on this path may put it in the daemon log.
func TestTranscriptsTextNeverReachesTheLog(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	tmpdir := filepath.Join(dir, "tmp")
	_ = os.MkdirAll(tmpdir, 0o755)
	t.Setenv("TMPDIR", tmpdir)
	t.Setenv("OXSAY_FAKE_STT_JSON", transcriptPayload)
	var logs bytes.Buffer
	d := newTestDaemon(t, dir, nil)
	d.log = slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	sttSetup(t, d, dir)
	r := rigFor(t, d, dir, tmpdir)
	code, body := r.post(t, map[string]string{"title": "x"})
	var m transcripts.Meta
	_ = json.Unmarshal(body, &m)
	if code != http.StatusCreated {
		t.Fatalf("POST %d (%s)", code, body)
	}
	r.do(t, http.MethodGet, "/v1/transcripts/"+m.ID+"?format=srt")
	r.do(t, http.MethodGet, "/v1/transcripts")
	r.do(t, http.MethodDelete, "/v1/transcripts/"+m.ID)
	// a failing STT carries its own message through the log too
	t.Setenv("OXSAY_FAKE_STT_EXIT", "1")
	r.post(t, nil)
	if strings.Contains(logs.String(), "zebra") {
		t.Fatalf("transcript text reached the log:\n%s", logs.String())
	}
}

// blockedTranscriptsRig is a rig whose store open fails at start: the
// transcripts path is held by a file, and the returned blocked path can be
// removed to let a later request's retry succeed.
func blockedTranscriptsRig(t *testing.T) (*transcriptsRig, string) {
	t.Helper()
	dir := t.TempDir()
	fakeEnv(t, dir)
	tmpdir := filepath.Join(dir, "tmp")
	if err := os.MkdirAll(tmpdir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", tmpdir)
	t.Setenv("OXSAY_FAKE_STT_JSON", transcriptPayload)
	if err := os.MkdirAll(filepath.Join(dir, "home"), 0o700); err != nil {
		t.Fatal(err)
	}
	blocked := filepath.Join(dir, "home", "transcripts")
	if err := os.WriteFile(blocked, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	d := newTestDaemon(t, dir, nil)
	if d.Transcripts != nil {
		t.Fatal("the store opened on a path held by a file")
	}
	sttSetup(t, d, dir)
	return rigFor(t, d, dir, tmpdir), blocked
}

// A store that could not be opened must not take the daemon down: the routes say so, and no recognizer time is spent.
func TestTranscriptsUnavailableStoreAnswers503BeforeTranscribing(t *testing.T) {
	r, _ := blockedTranscriptsRig(t)
	if code, body := r.post(t, nil); code != http.StatusServiceUnavailable {
		t.Fatalf("POST without a store: %d (%s), want 503", code, body)
	}
	if _, err := os.Stat(filepath.Join(r.dir, "stt.log")); err == nil {
		t.Error("the recognizer ran with nowhere to store the result")
	}
	for _, c := range []struct{ method, path string }{
		{http.MethodGet, "/v1/transcripts"}, {http.MethodGet, "/v1/transcripts/20261001-000000-abcdef"}, {http.MethodDelete, "/v1/transcripts/20261001-000000-abcdef"},
	} {
		if code, _, _ := r.do(t, c.method, c.path); code != http.StatusServiceUnavailable {
			t.Errorf("%s %s without a store: %d, want 503", c.method, c.path, code)
		}
	}
}

// An init that failed at start is retried on the next request, not at the
// next restart: once the path frees, the store opens and the routes serve.
func TestTranscriptsStoreRetriesAfterAFailedInit(t *testing.T) {
	r, blocked := blockedTranscriptsRig(t)
	if code, _, _ := r.do(t, http.MethodGet, "/v1/transcripts"); code != http.StatusServiceUnavailable {
		t.Fatalf("list with the store path held: %d, want 503", code)
	}
	if err := os.Remove(blocked); err != nil {
		t.Fatal(err)
	}
	code, _, body := r.do(t, http.MethodGet, "/v1/transcripts")
	if code != http.StatusOK || !strings.Contains(string(body), `"transcripts"`) {
		t.Fatalf("list after the path freed: %d %s, want 200", code, body)
	}
}

// List's skip-warning must reach the daemon log: a store wired to a logger
// that drops it would leave a corrupt entry silently invisible (#415).
func TestTranscriptsListWarnsOnACorruptEntry(t *testing.T) {
	r := newTranscriptsRig(t)
	bad := filepath.Join(r.d.Cfg.Home, "transcripts", "20261001-000000-abcdef")
	if err := os.MkdirAll(bad, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bad, "meta.json"), []byte("{nope"), 0o600); err != nil {
		t.Fatal(err)
	}
	if code, _, _ := r.do(t, http.MethodGet, "/v1/transcripts"); code != http.StatusOK {
		t.Fatalf("list with a corrupt entry: %d, want 200 (the entry is skipped)", code)
	}
	if !testLogSaw(t, "skipping an unreadable entry") || !testLogSaw(t, "20261001-000000-abcdef") {
		t.Fatal("the skipped-entry warning did not reach the daemon log")
	}
}

// An entry whose ox.json is gone reads as not found — the same answer a
// Delete that raced the two reads gives — never a 500.
func TestTranscriptGetMetaWithoutDocumentAnswers404(t *testing.T) {
	r := newTranscriptsRig(t)
	bare := filepath.Join(r.d.Cfg.Home, "transcripts", "20261001-000000-abcdef")
	if err := os.MkdirAll(bare, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bare, "meta.json"),
		[]byte(`{"id":"20261001-000000-abcdef","title":"x","engine":"parakeet","created":"2026-10-01T00:00:00Z","seconds":1}`), 0o600); err != nil {
		t.Fatal(err)
	}
	code, _, _ := r.do(t, http.MethodGet, "/v1/transcripts/20261001-000000-abcdef")
	if code != http.StatusNotFound {
		t.Fatalf("meta without a document: %d, want 404", code)
	}
}

// srt and vtt render only Segments: a stored result that has text but no
// segments must not download as an empty file with a 200 (#415).
func TestTranscriptGetWithTextAndNoSegmentsAnswers422(t *testing.T) {
	r := newTranscriptsRig(t)
	m, err := r.d.Transcripts.Put(transcripts.Meta{Title: "x"},
		[]byte(`{"engine":"parakeet","duration_s":1.5,"elapsed_s":0.2,"text":"zebra quartz sentinel."}`))
	if err != nil {
		t.Fatal(err)
	}
	for _, format := range []string{"srt", "vtt"} {
		code, _, body := r.do(t, http.MethodGet, "/v1/transcripts/"+m.ID+"?format="+format)
		if code != http.StatusUnprocessableEntity {
			t.Errorf("format=%s on a segmentless result: %d (%s), want 422", format, code, body)
		}
	}
	// The formats that carry text still serve it.
	code, _, body := r.do(t, http.MethodGet, "/v1/transcripts/"+m.ID+"?format=text")
	if code != http.StatusOK || !strings.Contains(string(body), "zebra") {
		t.Fatalf("format=text on the same result: %d %s, want 200 with the text", code, body)
	}
	// A transcript of silence has nothing to render either way: an empty
	// file is the honest answer there.
	silent, err := r.d.Transcripts.Put(transcripts.Meta{Title: "s"},
		[]byte(`{"engine":"parakeet","duration_s":1.5,"elapsed_s":0.2,"text":""}`))
	if err != nil {
		t.Fatal(err)
	}
	code, _, _ = r.do(t, http.MethodGet, "/v1/transcripts/"+silent.ID+"?format=vtt")
	if code != http.StatusOK {
		t.Fatalf("format=vtt on an empty transcript: %d, want 200", code)
	}
}

func TestTranscriptsDirIsPrivateAndUnderHome(t *testing.T) {
	r := newTranscriptsRig(t)
	st, err := os.Stat(filepath.Join(r.d.Cfg.Home, "transcripts"))
	if err != nil || st.Mode().Perm() != 0o700 {
		t.Fatalf("transcripts dir: %v %v, want 0700 under OX_SAY_HOME", st, err)
	}
}

// The old route keeps its allowlist: title is read by the new route only.
func TestTranscriptionsRouteStillIgnoresTitle(t *testing.T) {
	r := newTranscriptsRig(t)
	resp := postTranscription(t, r.url("/v1/audio/transcriptions"), testutil.TinyWAV(), map[string]string{"title": strings.Repeat("я", 5000)})
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d: an unlisted field must be ignored, not validated", resp.StatusCode)
	}
	if list := r.list(t); len(list) != 0 {
		t.Fatalf("the OpenAI route stored a transcript: %+v", list)
	}
}
