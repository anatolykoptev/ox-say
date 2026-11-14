package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/glossary"
	"github.com/anatolykoptev/ox-say/internal/stt"
	"github.com/anatolykoptev/ox-say/internal/testutil"
	"github.com/anatolykoptev/ox-say/internal/transcripts"
)

func approvedPair(t *testing.T, d *Daemon, heard, meant string) {
	t.Helper()
	p, err := d.Glossary.Add(heard, meant, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Glossary.Approve(p.ID); err != nil {
		t.Fatal(err)
	}
}

// Mutation: glossary_http.go correctSessionBody, return body unconditionally -> RED.
func TestCorrectSessionBody(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	in := []byte(`{"done":true,"text":"открой Воксей","segments":[{"s":0,"e":1.5,"text":"открой Воксей","cut":"final"}],"ms":12}`)
	if out := d.correctSessionBody(in); !bytes.Equal(out, in) {
		t.Fatalf("no pairs: body changed to %s", out)
	}
	approvedPair(t, d, "Воксей", "OxSay")
	var got struct {
		Done     bool    `json:"done"`
		Text     string  `json:"text"`
		Ms       float64 `json:"ms"`
		Segments []struct {
			Text string `json:"text"`
			Cut  string `json:"cut"`
		} `json:"segments"`
	}
	if err := json.Unmarshal(d.correctSessionBody(in), &got); err != nil {
		t.Fatal(err)
	}
	if !got.Done || got.Text != "открой OxSay" || got.Ms != 12 || len(got.Segments) != 1 || got.Segments[0].Text != "открой OxSay" || got.Segments[0].Cut != "final" {
		t.Fatalf("got %+v", got)
	}
	if out := d.correctSessionBody([]byte(`not json`)); string(out) != "not json" {
		t.Fatalf("unparsable body changed: %s", out)
	}
	clean := []byte(`{"done":true,"text":"всё верно"}`)
	if out := d.correctSessionBody(clean); !bytes.Equal(out, clean) {
		t.Fatalf("nothing to replace: body changed to %s", out)
	}
}

// Mutation: glossary_http.go correctResult, skip ApplyResult -> RED.
func TestCorrectResult(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	approvedPair(t, d, "Воксей", "OxSay")
	res := &stt.Result{Text: "открой Воксей", Segments: []stt.Segment{{Text: "открой Воксей"}}}
	d.correctResult(res, "transcriptions")
	if res.Text != "открой OxSay" || res.Segments[0].Text != "открой OxSay" {
		t.Fatalf("res = %+v", res)
	}
	_ = glossary.FileName
}

// The finish body the client pastes carries the corrected text, same seam as
// TestSTTSessionProxyRoundTrip (the fake joins its chunks into the text).
// Mutation: sessions.go sttSessionOp, pass nil instead of d.correctSessionBody -> RED.
func TestSTTSessionFinishAppliesGlossary(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
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
	for i, size := range []int{640, 1280} {
		code, body = sessReq(t, http.MethodPost, base+"/"+id+"/audio", "application/octet-stream", bytes.Repeat([]byte{1}, size))
		if code != http.StatusOK {
			t.Fatalf("audio %d: status %d body %s", i+1, code, body)
		}
	}
	approvedPair(t, d, "chunk", "piece")

	code, body = sessReq(t, http.MethodPost, base+"/"+id+"/finish", "application/json", []byte("{}"))
	if code != http.StatusOK {
		t.Fatalf("finish: status %d body %s", code, body)
	}
	var fin struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(body, &fin); err != nil || fin.Text != "piece 1 piece 2" {
		t.Fatalf("finish text = %q (body %s), want %q", fin.Text, body, "piece 1 piece 2")
	}
}

// Same seam as TestTranscribeFormats: every response format carries the
// corrected text.
// Mutation: transcribe.go handleTranscribe, delete the d.correctResult line -> RED.
func TestTranscribeAppliesGlossary(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	sttSetup(t, d, dir)
	srv := transcriptionServer(t, d)
	url := srv.URL + "/v1/audio/transcriptions"

	payload := `{"engine":"parakeet","language":"en","duration_s":1.5,"elapsed_s":0.2,` +
		`"text":"hello world.","segments":[{"s":0.0,"e":1.5,"text":"hello world."}],` +
		`"words":[{"w":"hello","s":0.0,"e":0.9,"p":0.99},{"w":"world.","s":0.9,"e":1.5,"p":0.98}]}`
	t.Setenv("OXSAY_FAKE_STT_JSON", payload)
	approvedPair(t, d, "world", "planet")

	for _, format := range []string{"", "srt"} {
		resp := postTranscription(t, url, testutil.TinyWAV(), map[string]string{"response_format": format})
		body, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "hello planet.") {
			t.Fatalf("format %q: status %d body %q", format, resp.StatusCode, body)
		}
	}
}

// Same seam as TestTranscribeTool (its fake returns "hello world."): the tool
// output text is corrected, and so is the JSON out_path gets.
// Mutation: transcribe.go toolTranscribe, delete the d.correctResult line -> RED.
func TestTranscribeToolAppliesGlossary(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	sttSetup(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")
	approvedPair(t, d, "world", "planet")

	_, out, err := d.toolTranscribe(context.Background(), nil, transcribeToolIn{AudioPath: src})
	if err != nil {
		t.Fatal(err)
	}
	if out.Text != "hello planet." {
		t.Fatalf("tool out text = %q", out.Text)
	}
	outPath := filepath.Join(dir, "result.json")
	if _, _, err := d.toolTranscribe(context.Background(), nil, transcribeToolIn{AudioPath: src, OutPath: outPath}); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), "hello planet.") {
		t.Fatalf("out_path JSON = %s", raw)
	}
}

// The stored transcript stays raw; the pair applies at read time, so
// rejecting it restores the original words.
// Mutation: transcripts_http.go handleTranscriptGet, delete the d.correctResult line -> RED.
func TestTranscriptReadAppliesGlossary(t *testing.T) {
	r := newTranscriptsRig(t)
	code, body := r.post(t, map[string]string{"title": "Тест"})
	if code != http.StatusCreated {
		t.Fatalf("POST status %d (%s)", code, body)
	}
	var m transcripts.Meta
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatal(err)
	}
	get := func() string {
		code, _, body := r.do(t, http.MethodGet, "/v1/transcripts/"+m.ID+"?format=text")
		if code != http.StatusOK {
			t.Fatalf("GET status %d", code)
		}
		return string(body)
	}
	if got := get(); got != "zebra quartz sentinel." {
		t.Fatalf("raw text = %q", got)
	}
	p, err := r.d.Glossary.Add("sentinel", "guardian", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.d.Glossary.Approve(p.ID); err != nil {
		t.Fatal(err)
	}
	if got := get(); got != "zebra quartz guardian." {
		t.Fatalf("approved text = %q", got)
	}
	if _, err := r.d.Glossary.Reject(p.ID); err != nil {
		t.Fatal(err)
	}
	if got := get(); got != "zebra quartz sentinel." {
		t.Fatalf("rejected text = %q, want the raw word back", got)
	}
}
