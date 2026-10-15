package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const testProjectID = "20261015-120000-a1b2c3"

// fakeProduce serves a project that is "running" for the first poll and
// finishes with final afterwards. It records the create body.
type fakeProduce struct {
	final    string
	polls    atomic.Int32
	created  map[string]any
	chunkReq map[string]any
	detail   atomic.Int32 // chunk-detail GETs so far
}

func (f *fakeProduce) summary(status string) string {
	return fmt.Sprintf(`{"id":%q,"status":%q,"seed":9,"progress":{"chunks_total":2,"chunks_done":%d},`+
		`"chunks":[{"index":1,"status":"review","pick":"aaaaaaaaaaaaaaaaaaaaaaaa","reasons":["2.0 s of silence inside the take"]}],`+
		`"outputs":{"wav":"/o.wav"},"notes":["numbers are not checked by the transcript gate"]}`, testProjectID, status, f.polls.Load())
}

func (f *fakeProduce) handler(w http.ResponseWriter, r *http.Request) {
	base := "/v1/produce/" + testProjectID
	switch {
	case r.Method == http.MethodPost && r.URL.Path == "/v1/produce":
		_ = json.NewDecoder(r.Body).Decode(&f.created)
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(f.summary("running")))
	case r.Method == http.MethodGet && r.URL.Path == base:
		st := "running"
		if f.polls.Add(1) > 1 {
			st = f.final
		}
		_, _ = w.Write([]byte(f.summary(st)))
	case r.Method == http.MethodGet && r.URL.Path == base+"/chunks/1":
		// Before the regenerate: one take. After: the original plus two new ones.
		takes := `{"key":"aaaaaaaaaaaaaaaaaaaaaaaa","duration_s":4.5,"wer":0.2,"passed":false}`
		files := `"aaaaaaaaaaaaaaaaaaaaaaaa":"/p/takes/aaaaaaaaaaaaaaaaaaaaaaaa.wav"`
		if f.detail.Add(1) > 1 {
			takes += `,{"key":"bbbbbbbbbbbbbbbbbbbbbbbb","duration_s":4.1,"wer":0,"passed":true},{"key":"cccccccccccccccccccccccc","duration_s":4.2,"wer":0.1,"passed":true}`
			files += `,"bbbbbbbbbbbbbbbbbbbbbbbb":"/p/takes/bbbbbbbbbbbbbbbbbbbbbbbb.wav","cccccccccccccccccccccccc":"/p/takes/cccccccccccccccccccccccc.wav"`
		}
		_, _ = fmt.Fprintf(w, `{"index":1,"pick":"aaaaaaaaaaaaaaaaaaaaaaaa","takes":[%s],"take_files":{%s}}`, takes, files)
	case r.Method == http.MethodPost && r.URL.Path == base+"/chunks/1":
		_ = json.NewDecoder(r.Body).Decode(&f.chunkReq)
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(f.summary("running")))
	default:
		http.NotFound(w, r)
	}
}

func newFakeProduce(t *testing.T, final string) *fakeProduce {
	t.Helper()
	f := &fakeProduce{final: final}
	srv := httptest.NewServer(http.HandlerFunc(f.handler))
	t.Cleanup(srv.Close)
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	return f
}

func writeScript(t *testing.T, text string) string {
	t.Helper()
	src := filepath.Join(t.TempDir(), "s.txt")
	if err := os.WriteFile(src, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	return src
}

// produce reads the file, sends typed fields, polls, prints the review
// list and exits 3 on "review".
// Mutation: internal/cli/produce.go exitCode, map review to 0 -> RED.
func TestProduceCLI(t *testing.T) {
	f := newFakeProduce(t, "review")
	dir := t.TempDir()
	src := writeScript(t, "Привет. [pause 0.5s] Пока.")
	var out, errb bytes.Buffer
	code := cmdProduce([]string{src, "-v", "nar", "-i", "calm", "--preset", "reels", "--seed", "9", "-o", filepath.Join(dir, "o.wav")}, &out, &errb, time.Millisecond)
	got := f.created
	if code != 3 || got["script"] != "Привет. [pause 0.5s] Пока." || got["seed"] != float64(9) || got["preset"] != "reels" || got["style"] != "calm" || got["voice"] != "nar" {
		t.Fatalf("exit %d body %v", code, got)
	}
	for _, want := range []string{"chunk 1", "/o.wav", "produce chunk " + testProjectID + " 1 --regen", "produce status " + testProjectID + " --chunk 1"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("stdout lacks %q:\n%s", want, out.String())
		}
	}
	// Binding amendment 3: the project seed and the project's notes print the
	// way `say` prints its seed and warning (stderr, same words).
	if !strings.Contains(errb.String(), "seed 9\n") || !strings.Contains(errb.String(), "warning: numbers are not checked") {
		t.Errorf("stderr lacks the seed line or the warning:\n%s", errb.String())
	}
}

// Exit codes: 0 done, 3 review, 1 anything else, 2 usage.
// Mutation: internal/cli/produce.go exitCode, return 0 for "failed" -> RED.
func TestProduceExitCodes(t *testing.T) {
	for final, want := range map[string]int{"done": 0, "review": 3, "failed": 1, "cancelled": 1, "interrupted": 1} {
		newFakeProduce(t, final)
		var out, errb bytes.Buffer
		if code := cmdProduce([]string{writeScript(t, "Привет.")}, &out, &errb, time.Millisecond); code != want {
			t.Errorf("%s: exit %d, want %d (stderr %s)", final, code, want, errb.String())
		}
	}
}

func TestProduceUsageErrors(t *testing.T) {
	newFakeProduce(t, "done")
	src := writeScript(t, "Привет.")
	cases := map[string][]string{
		"no args":        {},
		"bad seed":       {src, "--seed", "x"},
		"bad takes":      {src, "--takes", "1.5"},
		"status no id":   {"status"},
		"chunk no op":    {"chunk", testProjectID, "1"},
		"chunk two ops":  {"chunk", testProjectID, "1", "--regen", "2", "--pick", "k"},
		"chunk bad n":    {"chunk", testProjectID, "x", "--regen", "2"},
		"missing script": {filepath.Join(t.TempDir(), "nope.txt")},
	}
	for name, args := range cases {
		var errb bytes.Buffer
		if code := cmdProduce(args, io.Discard, &errb, time.Millisecond); code != 2 {
			t.Errorf("%s: exit %d, want 2 (%s)", name, code, errb.String())
		}
	}
	var errb bytes.Buffer
	cmdProduce([]string{src, "--seed", "x"}, io.Discard, &errb, time.Millisecond)
	if !strings.Contains(errb.String(), "ox-say: --seed x: not a number") {
		t.Errorf("seed message: %q", errb.String())
	}
}

// A busy daemon: the CLI names the running project and exits 1.
func TestProduceCLIBusy(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"error":{"message":"another voiceover is being produced (20261015-110000-ffffff): wait for it or cancel it"},"running_id":"20261015-110000-ffffff"}`))
	}))
	defer srv.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	var errb bytes.Buffer
	if code := cmdProduce([]string{writeScript(t, "Привет.")}, io.Discard, &errb, time.Millisecond); code != 1 || !strings.Contains(errb.String(), "running: 20261015-110000-ffffff") {
		t.Fatalf("exit %d: %s", code, errb.String())
	}
}

// --no-wait prints the id and the status command and does not poll.
// Mutation: internal/cli/produce.go cmdProduce, ignore noWait -> RED (polls > 0).
func TestProduceNoWait(t *testing.T) {
	f := newFakeProduce(t, "done")
	var out bytes.Buffer
	if code := cmdProduce([]string{writeScript(t, "Привет."), "--no-wait"}, &out, io.Discard, time.Millisecond); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if f.polls.Load() != 0 || !strings.Contains(out.String(), testProjectID) || !strings.Contains(out.String(), "produce status "+testProjectID) {
		t.Fatalf("polls %d, stdout:\n%s", f.polls.Load(), out.String())
	}
}

// Regenerate keeps the person's pick (F1-5), so the CLI names the NEW takes
// and the exact --pick command; the old take is not offered again.
// Mutation: internal/cli/produce.go newTakeKeys, return every key -> RED.
func TestProduceChunkRegenShowsNewTakes(t *testing.T) {
	f := newFakeProduce(t, "done")
	var out bytes.Buffer
	code := cmdProduce([]string{"chunk", testProjectID, "1", "--regen", "2"}, &out, io.Discard, time.Millisecond)
	if code != 0 || f.chunkReq["action"] != "regenerate" || f.chunkReq["takes"] != float64(2) {
		t.Fatalf("exit %d req %v", code, f.chunkReq)
	}
	s := out.String()
	for _, want := range []string{"produce chunk " + testProjectID + " 1 --pick bbbbbbbbbbbbbbbbbbbbbbbb", "produce chunk " + testProjectID + " 1 --pick cccccccccccccccccccccccc", "/p/takes/bbbbbbbbbbbbbbbbbbbbbbbb.wav"} {
		if !strings.Contains(s, want) {
			t.Errorf("stdout lacks %q:\n%s", want, s)
		}
	}
	if strings.Contains(s, "--pick aaaaaaaaaaaaaaaaaaaaaaaa") {
		t.Errorf("the old take is offered as new:\n%s", s)
	}
	if !strings.Contains(s, "pick is unchanged") {
		t.Errorf("the output must say the current pick is unchanged:\n%s", s)
	}
}

func TestProduceChunkPickAndText(t *testing.T) {
	f := newFakeProduce(t, "done")
	if code := cmdProduce([]string{"chunk", testProjectID, "1", "--pick", "bbbbbbbbbbbbbbbbbbbbbbbb"}, io.Discard, io.Discard, time.Millisecond); code != 0 ||
		f.chunkReq["action"] != "pick" || f.chunkReq["take"] != "bbbbbbbbbbbbbbbbbbbbbbbb" {
		t.Fatalf("pick: exit %d req %v", code, f.chunkReq)
	}
	if code := cmdProduce([]string{"chunk", testProjectID, "1", "--text", "Вот три приёма!"}, io.Discard, io.Discard, time.Millisecond); code != 0 ||
		f.chunkReq["action"] != "edit" || f.chunkReq["text"] != "Вот три приёма!" {
		t.Fatalf("edit: exit %d req %v", code, f.chunkReq)
	}
}

// status prints the chunk detail with take file paths.
func TestProduceStatusChunk(t *testing.T) {
	newFakeProduce(t, "done")
	var out bytes.Buffer
	if code := cmdProduce([]string{"status", testProjectID, "--chunk", "1"}, &out, io.Discard, time.Millisecond); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(out.String(), "/p/takes/aaaaaaaaaaaaaaaaaaaaaaaa.wav") {
		t.Fatalf("no take path:\n%s", out.String())
	}
}

// resume, cancel and rm hit the daemon's routes.
func TestProduceControlVerbs(t *testing.T) {
	var seen []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = append(seen, r.Method+" "+r.URL.RequestURI())
		switch {
		case strings.HasSuffix(r.URL.Path, "/resume"):
			body, _ := io.ReadAll(r.Body)
			seen = append(seen, string(body))
			w.WriteHeader(http.StatusAccepted)
			_, _ = w.Write([]byte(`{"id":"` + testProjectID + `","status":"done","progress":{},"chunks":[],"outputs":{},"notes":[]}`))
		case r.Method == http.MethodGet:
			_, _ = w.Write([]byte(`{"id":"` + testProjectID + `","status":"done","progress":{},"chunks":[],"outputs":{},"notes":[]}`))
		default:
			_, _ = w.Write([]byte(`{"status":"ok"}`))
		}
	}))
	defer srv.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	for _, args := range [][]string{
		{"resume", testProjectID, "--allow-battery"},
		{"cancel", testProjectID},
		{"rm", "--delete-outputs", testProjectID},
		{"rm", testProjectID},
	} {
		if code := cmdProduce(args, io.Discard, io.Discard, time.Millisecond); code != 0 {
			t.Fatalf("%v: exit %d", args, code)
		}
	}
	seen = dropPolls(seen)
	want := []string{
		"POST /v1/produce/" + testProjectID + "/resume", `{"allow_battery":true}`,
		"POST /v1/produce/" + testProjectID + "/cancel",
		"DELETE /v1/produce/" + testProjectID + "?delete_outputs=true",
		"DELETE /v1/produce/" + testProjectID,
	}
	if strings.Join(seen, "|") != strings.Join(want, "|") {
		t.Fatalf("requests %v, want %v", seen, want)
	}
}

func TestProduceLs(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"projects":[{"id":"` + testProjectID + `","title":"Reel","status":"review","progress":{"chunks_total":4,"chunks_done":4}}]}`))
	}))
	defer srv.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	var out bytes.Buffer
	if code := cmdProduce([]string{"ls"}, &out, io.Discard, time.Millisecond); code != 0 || !strings.Contains(out.String(), testProjectID) || !strings.Contains(out.String(), "Reel") {
		t.Fatalf("exit %d:\n%s", code, out.String())
	}
}

// The usage text lists the produce commands.
func TestUsageMentionsProduce(t *testing.T) {
	var b bytes.Buffer
	usage(&b)
	for _, want := range []string{"ox-say produce <script", "produce chunk", "produce status"} {
		if !strings.Contains(b.String(), want) {
			t.Errorf("usage lacks %q", want)
		}
	}
}

// dropPolls removes the status polls that follow a resume.
func dropPolls(in []string) []string {
	var out []string
	for _, s := range in {
		if s != "GET /v1/produce/"+testProjectID {
			out = append(out, s)
		}
	}
	return out
}
