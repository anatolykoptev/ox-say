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
	"reflect"
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
// list and exits 3 on "review". EVERY key of the create body is asserted:
// a flag that stops being forwarded is a silent failure.
// Mutation: internal/cli/produce.go exitCode, map review to 0 -> RED; drop
// body["out_path"], body["title"] (the "t" entry), "overwrite", "allow_battery"
// or "takes" in createBody -> RED.
func TestProduceCLI(t *testing.T) {
	f := newFakeProduce(t, "review")
	dir := t.TempDir()
	src := writeScript(t, "Привет. [pause 0.5s] Пока.")
	var out, errb bytes.Buffer
	outFile := filepath.Join(dir, "o.wav")
	code := cmdProduce([]string{src, "-v", "nar", "-i", "calm", "-t", "My Title", "--preset", "reels", "--seed", "9",
		"--takes", "2", "--overwrite", "--allow-battery", "-o", outFile}, &out, &errb, time.Millisecond)
	want := map[string]any{"script": "Привет. [pause 0.5s] Пока.", "voice": "nar", "style": "calm", "title": "My Title",
		"preset": "reels", "seed": float64(9), "takes": float64(2), "out_path": outFile, "overwrite": true, "allow_battery": true}
	if code != 3 || !reflect.DeepEqual(f.created, want) {
		t.Fatalf("exit %d body %v, want %v", code, f.created, want)
	}
	for _, w := range []string{"chunk 1", "/o.wav", "produce chunk " + testProjectID + " 1 --regen", "produce status " + testProjectID + " --chunk 1"} {
		if !strings.Contains(out.String(), w) {
			t.Errorf("stdout lacks %q:\n%s", w, out.String())
		}
	}
	// Binding amendment 3: the project seed and the project's notes print the
	// way `say` prints its seed and warning (stderr, same words).
	if !strings.Contains(errb.String(), "seed 9\n") || !strings.Contains(errb.String(), "warning: numbers are not checked") {
		t.Errorf("stderr lacks the seed line or the warning:\n%s", errb.String())
	}
}

// A relative -o is sent absolute: the daemon's working directory is not ours.
func TestProduceRelativeOutPathIsAbsolute(t *testing.T) {
	f := newFakeProduce(t, "done")
	cmdProduce([]string{writeScript(t, "Привет."), "-o", "rel/o.wav"}, io.Discard, io.Discard, time.Millisecond)
	if got, _ := f.created["out_path"].(string); !filepath.IsAbs(got) || !strings.HasSuffix(got, "rel/o.wav") {
		t.Fatalf("out_path %q", got)
	}
}

// The 1 MiB cap on the script holds for a file and for stdin.
// Mutation: internal/cli/produce.go readScriptFrom, `> maxScriptBytes` -> `> maxScriptBytes*2` -> RED.
func TestReadScriptCap(t *testing.T) {
	if _, err := readScriptFrom(strings.NewReader(strings.Repeat("a", maxScriptBytes))); err != nil {
		t.Fatalf("exactly the cap must pass: %v", err)
	}
	if _, err := readScriptFrom(strings.NewReader(strings.Repeat("a", maxScriptBytes+1))); err == nil || !strings.Contains(err.Error(), "longer than") {
		t.Fatalf("one byte over the cap must fail: %v", err)
	}
	big := writeScript(t, strings.Repeat("a", maxScriptBytes+1))
	newFakeProduce(t, "done")
	var errb bytes.Buffer
	if code := cmdProduce([]string{big}, io.Discard, &errb, time.Millisecond); code != exitUsage || !strings.Contains(errb.String(), "longer than") {
		t.Fatalf("oversize file: exit %d %s", code, errb.String())
	}
}

// "-" reads the script from stdin.
// Mutation: internal/cli/produce.go readScript, open the file "-" instead of stdin -> RED.
func TestProduceScriptFromStdin(t *testing.T) {
	f := newFakeProduce(t, "done")
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	_, _ = w.WriteString("Из стандартного ввода.")
	_ = w.Close()
	old := os.Stdin
	os.Stdin = r
	defer func() { os.Stdin = old }()
	if code := cmdProduce([]string{"-"}, io.Discard, io.Discard, time.Millisecond); code != 0 || f.created["script"] != "Из стандартного ввода." {
		t.Fatalf("exit %d body %v", code, f.created)
	}
}

// A typo or a flag of another verb is a usage error that names the token,
// never silently dropped.
// Mutation: internal/cli/produce.go checkUsage, drop the unknown-flag loop -> RED.
func TestProduceRejectsUnknownAndMisplacedFlags(t *testing.T) {
	f := newFakeProduce(t, "done")
	src := writeScript(t, "Привет.")
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"typo switch", []string{src, "--allow-batery"}, "--allow-batery"},
		{"typo switch 2", []string{src, "--overwrit"}, "--overwrit"},
		{"typo value flag", []string{src, "--tkaes", "3"}, "--tkaes"},
		{"extra positional", []string{src, "another.txt"}, "another.txt"},
		{"seed on cancel", []string{"cancel", testProjectID, "--seed", "1"}, "--seed does not apply to produce cancel"},
		{"overwrite on status", []string{"status", testProjectID, "--overwrite"}, "--overwrite does not apply to produce status"},
		{"regen on create", []string{src, "--regen", "2"}, "--regen does not apply"},
		{"pick on resume", []string{"resume", testProjectID, "--pick", "k"}, "--pick does not apply"},
		{"ls with an argument", []string{"ls", "x"}, "takes 0 argument"},
		{"rm without id", []string{"rm"}, "takes 1 argument"},
	}
	for _, c := range cases {
		var errb bytes.Buffer
		f.created = nil
		if code := cmdProduce(c.args, io.Discard, &errb, time.Millisecond); code != exitUsage || !strings.Contains(errb.String(), c.want) {
			t.Errorf("%s: exit %d, stderr %q, want %q", c.name, code, errb.String(), c.want)
		}
		if f.created != nil {
			t.Errorf("%s: a request was sent", c.name)
		}
	}
}

// --takes must be 1..3: 0 is usage, not "the preset's default".
// Mutation: internal/cli/produce.go createBody, drop the takes range check -> RED.
func TestProduceTakesZeroIsUsage(t *testing.T) {
	f := newFakeProduce(t, "done")
	for _, v := range []string{"0", "4", "-1"} {
		var errb bytes.Buffer
		if code := cmdProduce([]string{writeScript(t, "Привет."), "--takes", v}, io.Discard, &errb, time.Millisecond); code != exitUsage || !strings.Contains(errb.String(), "must be 1 to 3") {
			t.Errorf("--takes %s: exit %d %q", v, code, errb.String())
		}
	}
	if f.created != nil {
		t.Error("a request was sent")
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

// status exits like the run: 0 done (and still going), 3 review, 1 failed.
// Mutation: internal/cli/produce.go status, return exitDone always -> RED.
func TestProduceStatusExitCodes(t *testing.T) {
	for final, want := range map[string]int{"done": 0, "review": 3, "failed": 1, "cancelled": 1, "interrupted": 1, "running": 0} {
		f := newFakeProduce(t, final)
		f.polls.Store(5) // the fake answers its final status from the second poll
		if code := cmdProduce([]string{"status", testProjectID}, io.Discard, io.Discard, time.Millisecond); code != want {
			t.Errorf("status %s: exit %d, want %d", final, code, want)
		}
	}
}

// A 404 while waiting says the project was removed; a daemon that vanishes
// for fewer than pollRetries requests is waited out; for more, one message.
// Mutation: internal/cli/produce.go wait, retries := 0 (give up at the first error) -> RED.
func TestProducePollErrors(t *testing.T) {
	var calls atomic.Int32
	flaky := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost:
			w.WriteHeader(http.StatusAccepted)
			_, _ = w.Write([]byte(`{"id":"` + testProjectID + `","status":"running","progress":{},"chunks":[],"outputs":{},"notes":[]}`))
		case calls.Add(1) <= int32(flaky):
			hj, _ := w.(http.Hijacker)
			conn, _, _ := hj.Hijack()
			_ = conn.Close() // a dropped connection
		default:
			_, _ = w.Write([]byte(`{"id":"` + testProjectID + `","status":"done","progress":{},"chunks":[],"outputs":{},"notes":[]}`))
		}
	}))
	defer srv.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	src := writeScript(t, "Привет.")
	flaky = pollRetries - 1
	if code := cmdProduce([]string{src}, io.Discard, io.Discard, time.Millisecond); code != 0 {
		t.Fatalf("transient errors must be waited out: exit %d", code)
	}
	calls.Store(0)
	flaky = 100
	var errb bytes.Buffer
	if code := cmdProduce([]string{src}, io.Discard, &errb, time.Millisecond); code != 1 || strings.Count(errb.String(), "lost contact") != 1 || !strings.Contains(errb.String(), "produce status "+testProjectID) {
		t.Fatalf("exit %d, stderr %q", code, errb.String())
	}
	srv404 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			w.WriteHeader(http.StatusAccepted)
			_, _ = w.Write([]byte(`{"id":"` + testProjectID + `","status":"running","progress":{},"chunks":[],"outputs":{},"notes":[]}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":{"message":"no such voiceover project"}}`))
	}))
	defer srv404.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv404.URL, "http://"))
	errb.Reset()
	if code := cmdProduce([]string{src}, io.Discard, &errb, time.Millisecond); code != 1 || !strings.Contains(errb.String(), "was removed") {
		t.Fatalf("404: exit %d %q", code, errb.String())
	}
}

// No "new takes" hint after a run that did not finish.
// Mutation: internal/cli/produce_chunk.go chunk, drop the final-status check -> RED.
func TestProduceRegenHintOnlyAfterFinish(t *testing.T) {
	newFakeProduce(t, "failed")
	var out bytes.Buffer
	if code := cmdProduce([]string{"chunk", testProjectID, "1", "--regen", "2"}, &out, io.Discard, time.Millisecond); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if strings.Contains(out.String(), "new takes") || strings.Contains(out.String(), "--pick") {
		t.Fatalf("a failed run must not offer new takes:\n%s", out.String())
	}
}

// cancel of a project that is not running says so (exit 1, no "cancelling").
// Mutation: internal/cli/produce.go cancel, print "cancelling" before the call result -> RED.
func TestProduceCancelNotRunning(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"error":{"message":"this voiceover is not running, so there is nothing to cancel"}}`))
	}))
	defer srv.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	var out, errb bytes.Buffer
	if code := cmdProduce([]string{"cancel", testProjectID}, &out, &errb, time.Millisecond); code != 1 || strings.Contains(out.String()+errb.String(), "cancelling") || !strings.Contains(errb.String(), "not running") {
		t.Fatalf("exit %d out %q err %q", code, out.String(), errb.String())
	}
}

// The progress line never wraps on a terminal.
// Mutation: internal/cli/produce.go fitLine, return line unchanged -> RED.
func TestFitLine(t *testing.T) {
	long := strings.Repeat("я", 200)
	got := fitLine(long, 40)
	if n := len([]rune(got)); n >= 40 {
		t.Fatalf("%d runes for a 40-column terminal", n)
	}
	if fitLine("short", 40) != "short" {
		t.Fatal("a short line must stay")
	}
}
