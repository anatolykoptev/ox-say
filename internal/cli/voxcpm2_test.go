package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// recordedCall is one request the stub daemon saw.
type recordedCall struct {
	method, path string
	body         map[string]any
}

// stubCalls answers every request with reply and records each one.
func stubCalls(t *testing.T, reply []byte) *[]recordedCall {
	t.Helper()
	var calls []recordedCall
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c := recordedCall{method: r.Method, path: r.URL.Path}
		_ = json.NewDecoder(r.Body).Decode(&c.body)
		calls = append(calls, c)
		_, _ = w.Write(reply)
	}))
	t.Cleanup(srv.Close)
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	return &calls
}

// say forwards every quality flag as a typed JSON field.
// Mutation: internal/cli/cli.go addQualityFlags, store the raw string for --cfg
// (no strconv) -> the body carries "cfg_value":"2.5" -> RED.
func TestSayForwardsQualityFlags(t *testing.T) {
	calls := stubCalls(t, testutil.TinyWAV())
	out := filepath.Join(t.TempDir(), "o.wav")
	var so, se strings.Builder
	code := cmdSay([]string{"-m", "voxcpm2", "-i", "calm, slow", "--seed", "9", "--cfg", "2.5", "--steps", "16",
		"--clone-mode", "reference", "--loudness", "-16", "-o", out, "Привет"}, &so, &se)
	if code != 0 {
		t.Fatalf("exit %d: %s", code, se.String())
	}
	got := (*calls)[0].body
	want := map[string]any{"model": "voxcpm2", "instructions": "calm, slow", "seed": float64(9), "cfg_value": 2.5,
		"inference_timesteps": float64(16), "clone_mode": "reference", "loudness_lufs": float64(-16)}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %#v, want %#v", k, got[k], v)
		}
	}
}

// A client that passes none of the new flags sends the body it always sent.
// Mutation: internal/cli/cli.go cmdSay, set body["model"] unconditionally -> RED.
func TestSayWithoutNewFlagsSendsLegacyBody(t *testing.T) {
	calls := stubCalls(t, testutil.TinyWAV())
	out := filepath.Join(t.TempDir(), "o.wav")
	var so, se strings.Builder
	if code := cmdSay([]string{"-v", "ben", "-l", "Russian", "-o", out, "Привет"}, &so, &se); code != 0 {
		t.Fatalf("exit %d: %s", code, se.String())
	}
	got := (*calls)[0].body
	want := map[string]any{"input": "Привет", "response_format": "wav", "voice": "ben", "language": "Russian"}
	if len(got) != len(want) {
		t.Fatalf("body = %v, want exactly %v", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %#v, want %#v", k, got[k], v)
		}
	}
}

// A malformed number is a plain message and exit 2; nothing reaches the daemon.
// Mutation: internal/cli/cli.go addQualityFlags, ignore the parse error -> RED.
func TestSayBadNumberExits2(t *testing.T) {
	calls := stubCalls(t, testutil.TinyWAV())
	for _, flagName := range []string{"seed", "cfg", "steps", "loudness"} {
		var so, se strings.Builder
		code := cmdSay([]string{"--" + flagName, "abc", "-o", filepath.Join(t.TempDir(), "o.wav"), "hi"}, &so, &se)
		want := "ox-say: --" + flagName + " abc: not a number\n"
		if code != 2 || se.String() != want {
			t.Errorf("--%s: exit %d stderr %q, want exit 2 %q", flagName, code, se.String(), want)
		}
	}
	if len(*calls) != 0 {
		t.Errorf("a bad number reached the daemon: %v", *calls)
	}
}

// voice add carries the metadata only when it was given.
// Mutation: internal/cli/cli.go cmdVoice add, drop the "designed_from" entry -> RED.
func TestVoiceAddForwardsMetadata(t *testing.T) {
	calls := stubCalls(t, []byte(`{"name":"ru"}`))
	var so, se strings.Builder
	code := Run([]string{"voice", "add", "ru", "clip.wav", "--engine", "voxcpm2", "--style", "calm", "--designed-from", "a narrator"}, &so, &se, "test")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, se.String())
	}
	got := (*calls)[0].body
	for k, v := range map[string]string{"engine": "voxcpm2", "style": "calm", "designed_from": "a narrator"} {
		if got[k] != v {
			t.Errorf("%s = %#v, want %q", k, got[k], v)
		}
	}
	*calls = nil
	if code := Run([]string{"voice", "add", "ru", "clip.wav"}, &so, &se, "test"); code != 0 {
		t.Fatalf("exit %d", code)
	}
	for _, k := range []string{"engine", "style", "designed_from"} {
		if _, ok := (*calls)[0].body[k]; ok {
			t.Errorf("%s sent although not given", k)
		}
	}
}

// voice set PATCHes only the flags that were given; --style "" clears.
// Mutation: internal/cli/cli.go cmdVoiceSet, send style always (even absent) -> RED.
func TestVoiceSetPatchesGivenFieldsOnly(t *testing.T) {
	calls := stubCalls(t, []byte(`{"name":"ru"}`))
	var so, se strings.Builder
	if code := Run([]string{"voice", "set", "ru", "--style", ""}, &so, &se, "test"); code != 0 {
		t.Fatalf("exit %d: %s", code, se.String())
	}
	c := (*calls)[0]
	if c.method != http.MethodPatch || c.path != "/v1/audio/voices/ru" {
		t.Fatalf("request %s %s", c.method, c.path)
	}
	if s, ok := c.body["style"]; !ok || s != "" {
		t.Errorf("style = %#v (present %v), want empty string present", s, ok)
	}
	if _, ok := c.body["engine"]; ok {
		t.Error("engine sent although not given")
	}
	*calls = nil
	if code := Run([]string{"voice", "set", "ru", "--engine", "voxcpm2"}, &so, &se, "test"); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if b := (*calls)[0].body; b["engine"] != "voxcpm2" || len(b) != 1 {
		t.Errorf("body = %v, want only engine", b)
	}
}

// voice set with nothing to change, or no name, never reaches the daemon.
func TestVoiceSetUsage(t *testing.T) {
	calls := stubCalls(t, []byte(`{}`))
	for _, args := range [][]string{{"voice", "set"}, {"voice", "set", "ru"}} {
		var so, se strings.Builder
		if code := Run(args, &so, &se, "test"); code != 2 || !strings.Contains(se.String(), "usage: ox-say voice set") {
			t.Errorf("%v: exit %d %q", args, code, se.String())
		}
	}
	if len(*calls) != 0 {
		t.Errorf("reached the daemon: %v", *calls)
	}
}

// The usage text lists every new flag and verb, so `ox-say` alone teaches them.
func TestUsageMentionsVoxCPM2Surface(t *testing.T) {
	var sb strings.Builder
	usage(&sb)
	for _, s := range []string{"-m model", "-i instructions", "--seed", "--cfg", "--steps", "--clone-mode", "--loudness",
		"--engine", "--style", "--designed-from", "voice set"} {
		if !strings.Contains(sb.String(), s) {
			t.Errorf("usage lacks %q", s)
		}
	}
}

// voice ls marks a voice that prefers an engine, and prints a plain voice as before.
// Mutation: internal/cli/cli.go cmdVoice ls, drop the engine mark -> RED.
func TestVoiceLsShowsEngine(t *testing.T) {
	stubCalls(t, []byte(`{"voices":[{"name":"ben","created":"x"},{"name":"ru","ref_text":"t","engine":"voxcpm2","created":"x"}]}`))
	var so, se strings.Builder
	if code := Run([]string{"voice", "ls"}, &so, &se, "test"); code != 0 {
		t.Fatalf("exit %d: %s", code, se.String())
	}
	if want := "ben\nru (ref_text) [voxcpm2]\n"; so.String() != want {
		t.Fatalf("out %q, want %q", so.String(), want)
	}
}

// status shows the studio voice: its state, or the plain reason it cannot run;
// an older daemon without the key prints no line.
// Mutation: internal/cli/cli.go cmdStatus, drop the studio voice line -> RED.
func TestStatusStudioVoiceLine(t *testing.T) {
	statusOut := func(payload string) string {
		t.Helper()
		stubCalls(t, []byte(payload))
		var so, se strings.Builder
		if code := Run([]string{"status"}, &so, &se, "test"); code != 0 {
			t.Fatalf("exit %d: %s", code, se.String())
		}
		return so.String()
	}
	base := `{"engine":{"state":"ready","starts":1,"restarts":0},"voices":[],"version":"t"`
	out := statusOut(base + `,"voxcpm2":{"available":true,"state":"ready","pid":7,"uptime_s":3,"starts":1,"restarts":0}}`)
	if !strings.Contains(out, "studio voice (voxcpm2): ready (pid 7, up 3s)") {
		t.Errorf("ready line missing: %q", out)
	}
	out = statusOut(base + `,"voxcpm2":{"available":false,"reason":"Studio voices (VoxCPM2) need a Mac with Apple Silicon.","state":"stopped","starts":0,"restarts":0}}`)
	if !strings.Contains(out, "studio voice (voxcpm2): unavailable: Studio voices (VoxCPM2) need a Mac with Apple Silicon.") {
		t.Errorf("unavailable line missing: %q", out)
	}
	if out = statusOut(base + `}`); strings.Contains(out, "studio voice") {
		t.Errorf("studio voice line printed for a keyless payload: %q", out)
	}
}

// NaN, Inf and a fraction where a whole number is due are refused before
// anything is sent.
// Mutation: internal/cli/voxcpm2.go parseNumber, delete the math.IsNaN/IsInf
// test -> RED (NaN is sent); replace the ParseInt step by returning int64(f)
// -> RED (--seed 1.5 is accepted).
func TestSayRejectsNonFiniteAndFractionalNumbers(t *testing.T) {
	calls := stubCalls(t, testutil.TinyWAV())
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"--cfg", "NaN"}, "ox-say: --cfg NaN: not a number\n"},
		{[]string{"--loudness", "Inf"}, "ox-say: --loudness Inf: not a number\n"},
		{[]string{"--loudness", "-inf"}, "ox-say: --loudness -inf: not a number\n"},
		{[]string{"--seed", "1.5"}, "ox-say: --seed 1.5: not a whole number\n"},
		{[]string{"--steps", "2.5"}, "ox-say: --steps 2.5: not a whole number\n"},
	} {
		var so, se strings.Builder
		args := append(tc.args, "-o", filepath.Join(t.TempDir(), "o.wav"), "hi")
		if code := cmdSay(args, &so, &se); code != 2 || se.String() != tc.want {
			t.Errorf("%v: exit %d stderr %q, want exit 2 %q", tc.args, code, se.String(), tc.want)
		}
	}
	if len(*calls) != 0 {
		t.Errorf("reached the daemon: %v", *calls)
	}
}

// say tells the person, on stderr, the seed, the warning, and when another
// engine spoke than the one asked for; stdout and the audio file stay as they
// were, and a plain say prints nothing extra.
// Mutation: internal/cli/cli.go cmdSay, delete the reportRender call -> RED.
func TestSayReportsSeedWarningAndFallback(t *testing.T) {
	var hdr map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		for k, v := range hdr {
			w.Header().Set(k, v)
		}
		_, _ = w.Write(testutil.TinyWAV())
	}))
	t.Cleanup(srv.Close)
	t.Setenv("OX_SAY_ADDR", strings.TrimPrefix(srv.URL, "http://"))
	run := func(args ...string) (string, string, []byte) {
		out := filepath.Join(t.TempDir(), "o.wav")
		var so, se strings.Builder
		if code := cmdSay(append(args, "-o", out, "hi"), &so, &se); code != 0 {
			t.Fatalf("exit %d: %s", code, se.String())
		}
		audio, _ := os.ReadFile(out)
		return strings.ReplaceAll(so.String(), out, "OUT"), se.String(), audio
	}

	hdr = map[string]string{"X-Ox-Say-Model": "qwen3-tts", "X-Ox-Say-Seed": "42",
		"X-Ox-Say-Warning": "spoken by qwen3-tts: Studio voices need a Mac with Apple Silicon."}
	so, se, audio := run("-m", "voxcpm2")
	if so != "OUT\n" || !bytes.Equal(audio, testutil.TinyWAV()) {
		t.Errorf("stdout %q / audio changed", so)
	}
	for _, want := range []string{"seed 42\n", "warning: spoken by qwen3-tts: Studio voices need a Mac with Apple Silicon.\n",
		"note: you asked for voxcpm2, and qwen3-tts spoke\n"} {
		if !strings.Contains(se, want) {
			t.Errorf("stderr lacks %q: %q", want, se)
		}
	}
	// No model asked: no mismatch note. No headers: nothing at all.
	if _, se, _ = run(); strings.Contains(se, "note:") {
		t.Errorf("a note without a model asked: %q", se)
	}
	hdr = nil
	if _, se, _ = run("-m", "voxcpm2"); se != "" {
		t.Errorf("stderr %q, want empty", se)
	}
}
