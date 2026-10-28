package daemon

import (
	"context"
	"errors"
	"net/http"
	"os"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

// #143.1: a model name is matched without regard to case or surrounding
// space, and a near miss of "voxcpm2" is spoken by the default engine WITH a
// warning that names the right spelling — it must not look like a silent
// success. A foreign name ("tts-1") keeps today's meaning with no warning.
// Mutation: tts_route.go prepareSpeech, `strings.ToLower(strings.TrimSpace(m))`
// -> `strings.TrimSpace(m)` -> "VoxCPM2" lands on qwen -> RED. Mutation: delete
// the `strings.HasPrefix(low, "vox")` branch -> no warning -> RED.
func TestModelNamesAreForgivingAndNearMissesWarn(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	pick := func(m string) (string, string) {
		t.Helper()
		model, warning, err := d.prepareSpeech(map[string]any{fieldInput: "a", fieldModel: m})
		if err != nil {
			t.Fatalf("model %q: %v", m, err)
		}
		return model, warning
	}
	for _, m := range []string{"VoxCPM2", " voxcpm2 ", "VOXCPM2"} {
		if model, warning := pick(m); model != config.TTSModelVoxCPM2 || warning != "" {
			t.Errorf("model %q -> %q %q, want voxcpm2 with no warning", m, model, warning)
		}
	}
	if model, warning := pick("QWEN3-TTS"); model != config.TTSModelQwen || warning != "" {
		t.Errorf("QWEN3-TTS -> %q %q", model, warning)
	}
	for _, m := range []string{"voxcpm-2", "voxcpm", "vox-cpm2"} {
		if model, warning := pick(m); model != config.TTSModelQwen ||
			!strings.Contains(warning, `"`+m+`"`) || !strings.Contains(warning, "voxcpm2") {
			t.Errorf("near miss %q -> %q %q, want qwen3-tts with a warning naming it and voxcpm2", m, model, warning)
		}
	}
	if model, warning := pick("tts-1"); model != config.TTSModelQwen || warning != "" {
		t.Errorf("tts-1 -> %q %q, want qwen3-tts and no warning", model, warning)
	}
}

// #143.1: the passthrough qwen answer names its engine too, and carries the
// near-miss warning.
// Mutation: http.go handleSpeech, delete the `w.Header().Set("X-Ox-Say-Model", model)`
// line -> RED.
func TestQwenPassthroughSetsModelHeader(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	rec := postSpeech(d, `{"input":"e","model":"voxcpm-2","response_format":"wav"}`)
	if rec.Code != http.StatusOK || rec.Header().Get("X-Ox-Say-Model") != config.TTSModelQwen ||
		!strings.Contains(rec.Header().Get("X-Ox-Say-Warning"), "voxcpm-2") {
		t.Fatalf("%d %v", rec.Code, rec.Header())
	}
}

// #143.2: a voice preference overridden to qwen leaves a log line naming the
// voice and the reason.
// Mutation: tts_route.go prepareSpeech, delete the d.log.Warn call in the
// degrade branch -> RED.
func TestDegradeToQwenIsLogged(t *testing.T) {
	d, _, _ := voxFixture(t, func(c *config.Config) { c.GPUMemory = config.GPUMemoryDiscrete })
	placeVoxVoice(t, d, "nar", config.TTSModelVoxCPM2, "", "", 3)
	if _, err := d.Speak(context.Background(), SpeakInput{Text: "hi", Voice: "nar"}); err != nil {
		t.Fatal(err)
	}
	if !testLogSaw(t, "voice preference overridden") || !testLogSaw(t, "nar") {
		t.Fatal("the degrade to qwen3-tts was not logged with the voice")
	}
}

// #143.3: an engine that cannot be reached mid-request is a 502 (the qwen
// passthrough already answers 502 for the same failure), not a 500.
// Mutation: speak.go speechOn, return the plain fmt.Errorf("engine speech: %w")
// instead of the engineTransportError for the failed ec.Speech -> 500 -> RED.
func TestVoxCPM2TransportFailureIs502(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	t.Setenv("OXSAY_FAKE_VOX_DROP", "1")
	rec := postSpeech(d, `{"input":"hi","model":"voxcpm2"}`)
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("a dropped connection answered %d %s, want 502", rec.Code, bodyText(rec))
	}
	if strings.Contains(rec.Body.String(), "127.0.0.1") {
		t.Fatalf("the engine address leaked: %s", bodyText(rec))
	}
}

// #143.4: a voice that cannot be read answers in plain words, never with a
// path. Damaged files (a recording that is not a WAV, metadata that does not
// decode) are a 400 "add the voice again"; a read that failed just now is a
// 503 "try again" and never tells anyone to re-record a good voice.
// Mutation: voxcpm2.go resolveVoxVoice, return the old
// fmt.Errorf("voice %s: cannot read its recording: %w", name, err) -> the path
// is in the body (and the status 500) -> RED. Mutation: voiceReadError, drop
// the ErrBadWAV/json test (everything transient) -> the damaged rows answer 503
// -> RED. Mutation: drop the fs.ErrNotExist case -> the nowav row answers 503
// try-again -> RED. Mutation: drop the fs.ErrPermission case -> nometa and
// wavlocked answer 503 -> RED.
func TestVoxCPM2UnreadableVoiceDoesNotLeakPath(t *testing.T) {
	d, dir, _ := voxFixture(t, nil)
	for _, n := range []string{"badwav", "badmeta", "nometa", "nowav", "wavlocked"} {
		placeVoxVoice(t, d, n, config.TTSModelVoxCPM2, "", "", 3)
	}
	if err := os.WriteFile(d.Store.WAVPath("badwav"), []byte("not a wav at all"), 0o644); err != nil {
		t.Fatal(err)
	}
	metaOf := func(n string) string { return strings.TrimSuffix(d.Store.WAVPath(n), ".wav") + ".json" }
	if err := os.WriteFile(metaOf("badmeta"), []byte("{broken"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(metaOf("nometa"), 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(metaOf("nometa"), 0o644) })
	// #310.1: RemoveVoice used to drop the wav first, so a crash left a .json
	// whose recording is gone; and a recording nobody may read. Neither passes
	// by trying again.
	if err := os.Remove(d.Store.WAVPath("nowav")); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(d.Store.WAVPath("wavlocked"), 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(d.Store.WAVPath("wavlocked"), 0o644) })
	for name, want := range map[string]struct {
		code int
		text string
	}{
		"badwav":    {http.StatusBadRequest, "add the voice again"},
		"badmeta":   {http.StatusBadRequest, "add the voice again"},
		"nometa":    {http.StatusBadRequest, "permissions"},
		"wavlocked": {http.StatusBadRequest, "permissions"},
		"nowav":     {http.StatusBadRequest, "add the voice again"},
	} {
		rec := postSpeech(d, `{"input":"hi","model":"voxcpm2","voice":"`+name+`"}`)
		if rec.Code != want.code || !strings.Contains(rec.Body.String(), want.text) {
			t.Errorf("%s: %d %s, want %d containing %q", name, rec.Code, bodyText(rec), want.code, want.text)
		}
		if strings.Contains(rec.Body.String(), dir) || strings.Contains(rec.Body.String(), "/") {
			t.Errorf("%s: the body shows a path: %s", name, bodyText(rec))
		}
		if strings.Contains(rec.Body.String(), "try again") {
			t.Errorf("%s: a permanent failure says to try again: %s", name, bodyText(rec))
		}
	}
	if !testLogSaw(t, "badwav") {
		t.Error("the detail was not logged")
	}
}

// #143.3 / PR review: no engine address on any 502 path. The qwen passthrough
// (http.go) used to print the raw transport error, "Post http://127.0.0.1:port".
// Mutation: http.go handleSpeech, the ec.Speech failure writes
// fmt.Sprintf("engine speech: %v", err) -> RED.
func TestQwenPassthroughTransportFailureHasNoAddress(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	t.Setenv("OXSAY_FAKE_SPEECH_DROP", "1")
	rec := postSpeech(d, `{"input":"hi","response_format":"wav"}`)
	if rec.Code != http.StatusBadGateway || strings.Contains(rec.Body.String(), "127.0.0.1") {
		t.Fatalf("%d %s, want a 502 without the engine address", rec.Code, bodyText(rec))
	}
}

// A caller's own cancel keeps its reason and not the transport error, which
// names the child's address.
// Mutation: speak.go transportError, wrap `err` instead of `ctx.Err()` -> RED.
func TestTransportErrorOnCancelNamesNoAddress(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	got := d.transportError(ctx, errors.New(`Post "http://127.0.0.1:55437/v1/audio/speech": context canceled`))
	if strings.Contains(got.Error(), "127.0.0.1") || !errors.Is(got, context.Canceled) {
		t.Fatalf("%v", got)
	}
}

// The near-miss warning is a response header: a long or control-laden model
// name is cut and cleaned before it is echoed.
// Mutation: tts_route.go prepareSpeech, echo `name` instead of clipRunes(name,
// ...) -> RED.
func TestNearMissWarningClipsTheEchoedName(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	name := "vox" + strings.Repeat("é", 500) + "\r\nX-Evil: 1"
	_, warning, err := d.prepareSpeech(map[string]any{fieldInput: "a", fieldModel: name})
	if err != nil {
		t.Fatal(err)
	}
	if utf8.RuneCountInString(warning) > 64+200 || strings.ContainsAny(warning, "\r\n") {
		t.Fatalf("warning %d runes, control characters: %q", utf8.RuneCountInString(warning), warning)
	}
	if !strings.Contains(warning, "…") {
		t.Fatalf("the cut is not marked: %q", warning)
	}
}

// #143.9: instructions "()" (brackets only) is no instruction: the voice's own
// default style applies instead of the engine getting an empty "()" tag that
// would suppress it.
// Mutation: internal/vscript/style.go styleDrops, remove "()" from the string
// -> RED.
func TestVoxStyleBracketsOnlyInstructKeepsVoiceStyle(t *testing.T) {
	v := &voices.Voice{Name: "nar", Meta: voices.Meta{Style: "calm"}}
	for _, in := range []string{"()", " ( ) ", "（）"} {
		got, err := voxStyle(map[string]any{fieldInstruct: in}, v)
		if err != nil || got != "calm" {
			t.Errorf("instruct %q: style %q, err %v; want the voice default \"calm\"", in, got, err)
		}
	}
}

// #179: the voxcpm2 cap counts the text as the engine will get it, after
// Russian numbers are written out in words, so a short line dense with times
// can be refused although the caller's own text is well under the cap. The
// refusal says so, instead of quoting a length the caller cannot reproduce.
// Mutation: voxcpm2.go buildVoxCPM2, drop the "counted as spoken" clause from
// the message -> RED. (The cap itself: TestVoxCPM2CapsInputAt1000Characters.)
func TestVoxCPM2CapExplainsNumberExpansion(t *testing.T) {
	d, _, logPath := voxFixture(t, nil)
	text := strings.Repeat("в 14:30 ", 100) // 800 characters as typed
	rec := postSpeech(d, `{"model":"voxcpm2","language":"ru","input":"`+text+`"}`)
	if rec.Code != http.StatusBadRequest ||
		!strings.Contains(rec.Body.String(), "counted as spoken") || !strings.Contains(rec.Body.String(), "written out in words") {
		t.Fatalf("%d %s", rec.Code, bodyText(rec))
	}
	if n := len(voxLog(t, logPath)); n != 0 {
		t.Fatalf("a refused request reached the engine (%d)", n)
	}
}
