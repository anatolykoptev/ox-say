package cli

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
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
