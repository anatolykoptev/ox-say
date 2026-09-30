package cli

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/config"
)

// pullFlags must find flags in ANY position: Go's flag package stops at the
// first positional, which made `voice add <name> <audio> --ref-text t` (the
// documented form) unreachable and silently swallowed `say text -v ben` into
// the spoken text.
func TestPullFlags(t *testing.T) {
	cases := []struct {
		name  string
		args  []string
		names []string
		vals  map[string]string
		pos   []string
	}{
		{
			name:  "flags after positionals (documented voice add form)",
			args:  []string{"ben", "./clip.wav", "--ref-text", "hello there"},
			names: []string{"ref-text"},
			vals:  map[string]string{"ref-text": "hello there"},
			pos:   []string{"ben", "./clip.wav"},
		},
		{
			name:  "flags first also work",
			args:  []string{"--ref-text=hi", "ben", "clip.wav"},
			names: []string{"ref-text"},
			vals:  map[string]string{"ref-text": "hi"},
			pos:   []string{"ben", "clip.wav"},
		},
		{
			name:  "say: trailing -v not swallowed into text",
			args:  []string{"hello", "-v", "ben"},
			names: []string{"v"},
			vals:  map[string]string{"v": "ben"},
			pos:   []string{"hello"},
		},
		{
			name:  "double dash ends flag parsing",
			args:  []string{"-v", "ben", "--", "-o", "not-a-flag"},
			names: []string{"v", "o"},
			vals:  map[string]string{"v": "ben"},
			pos:   []string{"-o", "not-a-flag"},
		},
		{
			name:  "unknown dashes stay positional",
			args:  []string{"-1", "degrees"},
			names: []string{"v"},
			vals:  map[string]string{},
			pos:   []string{"-1", "degrees"},
		},
		{
			name:  "single-dash equals form",
			args:  []string{"-f=mp3", "hi"},
			names: []string{"f"},
			vals:  map[string]string{"f": "mp3"},
			pos:   []string{"hi"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			vals, pos, err := pullFlags(tc.args, tc.names...)
			if err != nil {
				t.Fatalf("pullFlags: %v", err)
			}
			if !reflect.DeepEqual(vals, tc.vals) {
				t.Fatalf("vals = %v, want %v", vals, tc.vals)
			}
			if !reflect.DeepEqual(pos, tc.pos) {
				t.Fatalf("pos = %v, want %v", pos, tc.pos)
			}
		})
	}
}

func TestPullFlagsMissingValue(t *testing.T) {
	if _, _, err := pullFlags([]string{"hi", "-v"}, "v"); err == nil {
		t.Fatal("expected error for a flag with no value")
	}
}

// captureBody runs one CLI command against a stub daemon and returns the
// last POSTed JSON body.
func captureBody(t *testing.T, args ...string) (map[string]any, int) {
	t.Helper()
	bodyCh := make(chan map[string]any, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		bodyCh <- body
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))

	var outBuf, errBuf strings.Builder
	code := Run(args, &outBuf, &errBuf, "test")
	select {
	case body := <-bodyCh:
		return body, code
	default:
		return nil, code
	}
}

// `voice add` must send an absolute audio_path: the daemon's cwd is "/"
// under launchd, a relative path resolves somewhere unexpected.
// Mutation: drop the filepath.Abs in cmdVoice -> RED (the recorded
// audio_path is relative).
func TestVoiceAddSendsAbsolutePath(t *testing.T) {
	body, code := captureBody(t, "voice", "add", "ben", "clip.wav")
	if code != 0 {
		t.Fatalf("voice add exit code = %d", code)
	}
	p, _ := body["audio_path"].(string)
	if !filepath.IsAbs(p) {
		t.Fatalf("audio_path = %q, want absolute", p)
	}
}

// `transcribe` uploads the file as multipart to /v1/audio/transcriptions:
// file content, model/language/prompt fields and the default text format.
// Mutation: send JSON instead of multipart (or the wrong field name) -> RED.
func TestTranscribeSendsMultipart(t *testing.T) {
	var gotCT, gotPath string
	var gotFile []byte
	var fields map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotCT = r.Header.Get("Content-Type")
		if mr, err := r.MultipartReader(); err == nil {
			fields = map[string]string{}
			for {
				p, err := mr.NextPart()
				if err != nil {
					break
				}
				data, _ := io.ReadAll(p)
				if p.FormName() == "file" {
					gotFile = data
				} else {
					fields[p.FormName()] = string(data)
				}
			}
		}
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte("the transcript"))
	}))
	defer srv.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))

	src := filepath.Join(t.TempDir(), "clip.wav")
	if err := os.WriteFile(src, []byte("RIFF-fake-audio"), 0o644); err != nil {
		t.Fatal(err)
	}
	var outBuf, errBuf strings.Builder
	code := Run([]string{"transcribe", "-e", "whisper", "-l", "ru", "--prompt", "ctx", src}, &outBuf, &errBuf, "test")
	if code != 0 {
		t.Fatalf("transcribe exit = %d (stderr %s)", code, errBuf.String())
	}
	if gotPath != "/v1/audio/transcriptions" {
		t.Fatalf("path = %q", gotPath)
	}
	if !strings.HasPrefix(gotCT, "multipart/form-data") {
		t.Fatalf("content-type = %q", gotCT)
	}
	if string(gotFile) != "RIFF-fake-audio" {
		t.Fatalf("file part = %q", gotFile)
	}
	if fields["model"] != "whisper" || fields["language"] != "ru" || fields["prompt"] != "ctx" || fields["response_format"] != "text" {
		t.Fatalf("fields = %v", fields)
	}
	if strings.TrimSpace(outBuf.String()) != "the transcript" {
		t.Fatalf("stdout = %q", outBuf.String())
	}
}

// transcribe usage errors: no file, a bad engine, a missing file.
func TestTranscribeUsageErrors(t *testing.T) {
	var outBuf, errBuf strings.Builder
	if code := Run([]string{"transcribe"}, &outBuf, &errBuf, "test"); code != 2 {
		t.Fatalf("no file: exit = %d, want 2", code)
	}
	if code := Run([]string{"transcribe", "-e", "bogus", "x.wav"}, &outBuf, &errBuf, "test"); code != 2 {
		t.Fatalf("bad engine: exit = %d, want 2", code)
	}
	if code := Run([]string{"transcribe", "--json", "--srt", "x.wav"}, &outBuf, &errBuf, "test"); code != 2 {
		t.Fatalf("--json --srt: exit = %d, want 2", code)
	}
	if code := Run([]string{"transcribe", filepath.Join(t.TempDir(), "nope.wav")}, &outBuf, &errBuf, "test"); code != 1 {
		t.Fatalf("missing file: exit = %d, want 1", code)
	}
}

// Without -f, `say -o` infers the format from the output extension.
func TestSayInfersFormatFromOutExt(t *testing.T) {
	cases := []struct {
		out  string
		want string
	}{
		{filepath.Join(t.TempDir(), "a.mp3"), "mp3"},
		{filepath.Join(t.TempDir(), "a.ogg"), "opus"},
		{filepath.Join(t.TempDir(), "a.opus"), "opus"},
		{filepath.Join(t.TempDir(), "a.wav"), "wav"},
		{filepath.Join(t.TempDir(), "a.pcm"), "pcm"},
	}
	for _, tc := range cases {
		body, code := captureBody(t, "say", "-o", tc.out, "hi")
		if code != 0 {
			t.Fatalf("%s: exit code %d", tc.out, code)
		}
		if got := body["response_format"]; got != tc.want {
			t.Fatalf("%s: response_format = %v, want %s", tc.out, got, tc.want)
		}
	}
	// An explicit -f beats inference.
	body, _ := captureBody(t, "say", "-f", "wav", "-o", filepath.Join(t.TempDir(), "a.mp3"), "hi")
	if got := body["response_format"]; got != "wav" {
		t.Fatalf("explicit -f: response_format = %v, want wav", got)
	}
}

// --json asks for ox_json (the engine's own words), --srt for srt.
// Mutation: map --json to verbose_json in cmdTranscribe -> RED.
func TestTranscribeFormatFlags(t *testing.T) {
	var got string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if mr, err := r.MultipartReader(); err == nil {
			for {
				p, err := mr.NextPart()
				if err != nil {
					break
				}
				data, _ := io.ReadAll(p)
				if p.FormName() == "response_format" {
					got = string(data)
				}
			}
		}
		_, _ = w.Write([]byte("{}"))
	}))
	defer srv.Close()
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	src := filepath.Join(t.TempDir(), "clip.wav")
	if err := os.WriteFile(src, []byte("RIFF"), 0o644); err != nil {
		t.Fatal(err)
	}
	for flag, want := range map[string]string{"--json": "ox_json", "--srt": "srt"} {
		var outBuf, errBuf strings.Builder
		if code := Run([]string{"transcribe", flag, src}, &outBuf, &errBuf, "test"); code != 0 {
			t.Fatalf("%s: exit %d (%s)", flag, code, errBuf.String())
		}
		if got != want {
			t.Fatalf("%s sent response_format %q, want %q", flag, got, want)
		}
	}
}

// `status` shows the resident STT server's own failure state — last_error
// and crash restarts — and omits the line entirely for an older daemon
// whose /status has no stt_server key.
// Mutation: drop the st.STTServer != nil guard -> RED ("stt server:" prints
// for a keyless payload); drop the LastErr print -> RED.
func TestStatusSTTServerLine(t *testing.T) {
	statusOut := func(payload string) string {
		t.Helper()
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(payload))
		}))
		defer srv.Close()
		t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
		var outBuf, errBuf strings.Builder
		if code := Run([]string{"status"}, &outBuf, &errBuf, "test"); code != 0 {
			t.Fatalf("status: exit %d (%s)", code, errBuf.String())
		}
		return outBuf.String()
	}

	out := statusOut(`{"engine":{"state":"ready","pid":1,"uptime_s":3,"starts":1,"restarts":0},` +
		`"stt_server":{"state":"crashed","restarts":2,"last_error":"engine exited unexpectedly: exit status 1"},` +
		`"voices":[],"version":"test"}`)
	if !strings.Contains(out, "stt server: crashed") {
		t.Fatalf("stt server state missing: %q", out)
	}
	if !strings.Contains(out, "crash restarts: 2") {
		t.Fatalf("stt server restarts missing: %q", out)
	}
	if !strings.Contains(out, "exit status 1") {
		t.Fatalf("stt server last error missing: %q", out)
	}

	// OX_SAY_STT_SERVER=off still reports the key — the line stays, as "off".
	out = statusOut(`{"engine":{"state":"ready","starts":1,"restarts":0},"stt_server":{"state":"off"},"voices":[],"version":"test"}`)
	if !strings.Contains(out, "stt server: off") {
		t.Fatalf("stt server off state missing: %q", out)
	}

	// An older daemon has no stt_server key: no empty "stt server:" line.
	out = statusOut(`{"engine":{"state":"stopped","starts":0,"restarts":0},"voices":[],"version":"test"}`)
	if strings.Contains(out, "stt server") {
		t.Fatalf("stt server line printed for a keyless payload: %q", out)
	}
}

// env-keys is the installer's allowlist source: it must print exactly the
// daemon's env-key table, one per line.
// Mutation: drop the "env-keys" case in Run -> RED (exit 2, usage text).
func TestEnvKeysCommand(t *testing.T) {
	var outBuf, errBuf strings.Builder
	if code := Run([]string{"env-keys"}, &outBuf, &errBuf, "test"); code != 0 {
		t.Fatalf("env-keys: exit %d (%s)", code, errBuf.String())
	}
	got := strings.Fields(outBuf.String())
	want := config.EnvKeys()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("env-keys = %v, want %v", got, want)
	}
}
