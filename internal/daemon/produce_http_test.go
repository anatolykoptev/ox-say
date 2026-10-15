package daemon

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

func produceMux(t *testing.T, f *fakePorts) (*Daemon, *http.ServeMux) {
	t.Helper()
	d := newTestDaemon(t, t.TempDir(), nil)
	d.prod = newProducer(f)
	d.StartProducer()
	t.Cleanup(d.StopProducer)
	mux := http.NewServeMux()
	d.Routes(mux)
	return d, mux
}

func do(mux *http.ServeMux, method, path, body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	mux.ServeHTTP(rec, req)
	return rec
}

// Creation-time validation, status codes, and no internal paths in 4xx.
func TestProduceHTTPValidation(t *testing.T) {
	f := newFakePorts(t)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	_ = os.WriteFile(strings.TrimSuffix(out, ".wav")+".srt", []byte("x"), 0o644)
	cases := []struct {
		name, body string
		setup      func()
		want       int
	}{
		{"unknown field", `{"script":"Привет.","cfg_value":3}`, nil, http.StatusBadRequest},
		{"empty script", `{"script":""}`, nil, http.StatusBadRequest},
		{"unknown directive", `{"script":"Текст [music]."}`, nil, http.StatusBadRequest},
		{"too long", `{"script":"` + strings.Repeat("я", maxProduceChars+1) + `"}`, nil, http.StatusBadRequest},
		{"bad out ext", `{"script":"Привет.","out_path":"/tmp/x.mp3"}`, nil, http.StatusBadRequest},
		{"sibling exists", `{"script":"Привет.","out_path":"` + out + `"}`, nil, http.StatusBadRequest},
		{"bad preset", `{"script":"Привет.","preset":"podcast"}`, nil, http.StatusBadRequest},
		{"takes range", `{"script":"Привет.","takes":4}`, nil, http.StatusBadRequest},
		{"voice too long", `{"script":"Привет."}`, func() { f.voiceErr = &requestError{"this voice's recording is 40 seconds long"} }, http.StatusBadRequest},
		{"unavailable", `{"script":"Привет."}`, func() { f.voiceErr = nil; f.unavailable = "Apple Silicon only" }, http.StatusUnprocessableEntity},
	}
	for _, c := range cases {
		if c.setup != nil {
			c.setup()
		}
		rec := do(mux, http.MethodPost, "/v1/produce", c.body)
		if rec.Code != c.want {
			t.Errorf("%s: %d %s", c.name, rec.Code, rec.Body)
		}
		if strings.Contains(rec.Body.String(), f.home) {
			t.Errorf("%s: internal path in the body: %s", c.name, rec.Body)
		}
	}
}

// An internal error that carries an absolute path is answered in plain words
// (#154.5); the detail stays in the log.
// Mutation: produce_http.go writeProduceErr, answer err.Error() -> RED.
func TestProduceHTTPErrorsHideInternalPaths(t *testing.T) {
	f := newFakePorts(t)
	f.voiceErr = fmt.Errorf("open %s/voices/nar.wav: boom", f.home)
	_, mux := produceMux(t, f)
	rec := do(mux, http.MethodPost, "/v1/produce", `{"script":"Привет."}`)
	if rec.Code != http.StatusInternalServerError || strings.Contains(rec.Body.String(), f.home) {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
}

// Every {id} route validates the id before touching the disk.
// Mutation: drop the ValidID check in the GET handler path (producer.manifest) -> RED.
func TestProduceHTTPIDs(t *testing.T) {
	_, mux := produceMux(t, newFakePorts(t))
	for _, r := range []struct{ method, path, body string }{
		{http.MethodGet, "/v1/produce/..%2F..%2Fetc", ""},
		{http.MethodGet, "/v1/produce/20261015-120000-zzzzzz/chunks/0", ""},
		{http.MethodPost, "/v1/produce/x/resume", `{}`},
		{http.MethodPost, "/v1/produce/x/cancel", `{}`},
		{http.MethodPost, "/v1/produce/x/chunks/0", `{"action":"pick","take":"aa"}`},
		{http.MethodDelete, "/v1/produce/x", ""},
	} {
		if rec := do(mux, r.method, r.path, r.body); rec.Code != http.StatusNotFound {
			t.Errorf("%s %s: %d", r.method, r.path, rec.Code)
		}
	}
}

// Busy: 409 with the running id. DELETE keeps outputs unless asked.
func TestProduceHTTPBusyAndDelete(t *testing.T) {
	f := newFakePorts(t)
	f.block, f.started = make(chan struct{}), make(chan struct{}, 8)
	_, mux := produceMux(t, f)
	out := filepath.Join(t.TempDir(), "v.wav")
	rec := do(mux, http.MethodPost, "/v1/produce", `{"script":"Привет.","out_path":"`+out+`"}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	var s vproject.Summary
	_ = json.Unmarshal(rec.Body.Bytes(), &s)
	<-f.started
	rec = do(mux, http.MethodPost, "/v1/produce", `{"script":"Ещё."}`)
	if rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), s.ID) {
		t.Fatalf("busy: %d %s", rec.Code, rec.Body)
	}
	if rec := do(mux, http.MethodDelete, "/v1/produce/"+s.ID, ""); rec.Code != http.StatusConflict {
		t.Fatalf("delete while running: %d", rec.Code)
	}
	close(f.block)
	for i := 0; i < 500; i++ {
		if r := do(mux, http.MethodGet, "/v1/produce/"+s.ID, ""); strings.Contains(r.Body.String(), `"status":"done"`) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond) // the job releases the producer just after it saves "done"
	if rec := do(mux, http.MethodDelete, "/v1/produce/"+s.ID, ""); rec.Code != http.StatusOK {
		t.Fatalf("delete: %d %s", rec.Code, rec.Body)
	}
	if _, err := os.Stat(out); err != nil {
		t.Fatal("delete removed the published WAV without delete_outputs")
	}
	if _, err := os.Stat(filepath.Join(f.home, produceDir, s.ID)); !os.IsNotExist(err) {
		t.Fatal("project dir still there")
	}
}
