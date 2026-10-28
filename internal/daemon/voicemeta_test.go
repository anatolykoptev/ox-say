package daemon

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/testutil"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

// metaServer is a daemon with its routes mounted on a test server.
func metaServer(t *testing.T) (*Daemon, string, string) {
	t.Helper()
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	mux := http.NewServeMux()
	d.Routes(mux)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return d, srv.URL, dir
}

func doJSON(t *testing.T, method, url, body string) (int, string) {
	t.Helper()
	req, err := http.NewRequest(method, url, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(raw)
}

func readMeta(t *testing.T, d *Daemon, name string) string {
	t.Helper()
	raw, err := os.ReadFile(strings.TrimSuffix(d.Store.WAVPath(name), ".wav") + ".json")
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// PATCH changes engine/style, refuses an unknown engine, an over-long style and
// an unknown voice, and leaves the stored file untouched on every refusal.
// Mutation A: internal/daemon/voicemeta.go UpdateVoice — delete the
// validateEngine call -> RED (the bogus engine is stored).
// Mutation B: same function — delete the validateStyle call -> RED.
func TestPatchVoiceValidates(t *testing.T) {
	d, url, _ := metaServer(t)
	seedStoredVoice(t, d, "nar", 8, "hello")
	code, body := doJSON(t, http.MethodPatch, url+"/v1/audio/voices/nar", `{"engine":"voxcpm2","style":"calm, warm"}`)
	if code != http.StatusOK || !strings.Contains(body, `"engine":"voxcpm2"`) || !strings.Contains(body, `"style":"calm, warm"`) {
		t.Fatalf("PATCH = %d %s", code, body)
	}
	good := readMeta(t, d, "nar")
	for name, tc := range map[string]struct {
		path, body string
		want       int
	}{
		"bad engine": {"nar", `{"engine":"bogus"}`, http.StatusBadRequest},
		"long style": {"nar", `{"style":"` + strings.Repeat("x", maxStyleChars+1) + `"}`, http.StatusBadRequest},
		"bad json":   {"nar", `{`, http.StatusBadRequest},
		"unknown":    {"nobody", `{"style":"x"}`, http.StatusNotFound},
		"bad name":   {"BAD", `{"style":"x"}`, http.StatusBadRequest},
	} {
		if code, body := doJSON(t, http.MethodPatch, url+"/v1/audio/voices/"+tc.path, tc.body); code != tc.want {
			t.Errorf("%s: PATCH = %d %s, want %d", name, code, body, tc.want)
		}
	}
	if got := readMeta(t, d, "nar"); got != good {
		t.Fatalf("a refused PATCH changed the file:\n%s\n%s", good, got)
	}
	// "" clears; absent leaves alone.
	if code, body := doJSON(t, http.MethodPatch, url+"/v1/audio/voices/nar", `{"style":""}`); code != http.StatusOK || strings.Contains(body, "style") || !strings.Contains(body, `"engine":"voxcpm2"`) {
		t.Fatalf("clear style = %d %s", code, body)
	}
}

// A stored recording longer than the VoxCPM2 encoder window cannot be switched
// to voxcpm2; one inside it can, and qwen3-tts is not affected by length.
// Mutation: internal/daemon/voicemeta.go UpdateVoice — delete the
// checkStoredVoxReference call -> RED (the long voice is switched).
func TestPatchEngineRefusesOverlongReference(t *testing.T) {
	d, url, _ := metaServer(t)
	seedStoredVoice(t, d, "huge", voxMaxRefSeconds+5, "x")
	seedStoredVoice(t, d, "edge", voxMaxRefSeconds, "x")
	before := readMeta(t, d, "huge")
	code, body := doJSON(t, http.MethodPatch, url+"/v1/audio/voices/huge", `{"engine":"voxcpm2"}`)
	if code != http.StatusBadRequest || !strings.Contains(body, "at most 30 seconds") || !strings.Contains(body, "shorter clip") {
		t.Fatalf("PATCH over-long = %d %s", code, body)
	}
	if got := readMeta(t, d, "huge"); got != before {
		t.Fatalf("refused PATCH rewrote the voice: %s", got)
	}
	if code, body := doJSON(t, http.MethodPatch, url+"/v1/audio/voices/huge", `{"engine":"qwen3-tts"}`); code != http.StatusOK {
		t.Fatalf("qwen3-tts on a long clip = %d %s", code, body)
	}
	if code, body := doJSON(t, http.MethodPatch, url+"/v1/audio/voices/edge", `{"engine":"voxcpm2"}`); code != http.StatusOK {
		t.Fatalf("clip exactly at the limit = %d %s", code, body)
	}
}

// A voice added with engine voxcpm2 never stores a reference past the encoder
// window: the existing add flow cuts it at the store's own cap, which sits
// below the encoder's.
// Mutation: internal/voices/refcut.go MaxRefSeconds = 20.0 -> 40.0 -> RED
// (this test, and TestVoxReferenceLimitCoversStoreCap).
func TestAddVoxVoiceStoresTrimmedReference(t *testing.T) {
	d, url, dir := metaServer(t)
	src := testutil.WriteSilentWAV(t, dir, "long.wav", 3*voxMaxRefSeconds)
	body := fmt.Sprintf(`{"name":"long","audio_path":%q,"engine":"voxcpm2","style":"slow","designed_from":"a narrator"}`, src)
	code, resp := doJSON(t, http.MethodPost, url+"/v1/audio/voices", body)
	if code != http.StatusOK {
		t.Fatalf("POST = %d %s", code, resp)
	}
	secs, err := voices.WAVSeconds(d.Store.WAVPath("long"))
	if err != nil || secs > voxMaxRefSeconds {
		t.Fatalf("stored reference = %.1f s (%v), want <= %d", secs, err, voxMaxRefSeconds)
	}
	v, err := d.Store.Get("long")
	if err != nil || v.Engine != config.TTSModelVoxCPM2 || v.Style != "slow" || v.DesignedFrom != "a narrator" {
		t.Fatalf("stored voice = %+v, %v", v, err)
	}
}

// The store's reference cap must stay inside the encoder window, or a clip the
// store accepts would crash the engine.
func TestVoxReferenceLimitCoversStoreCap(t *testing.T) {
	if voices.MaxRefSeconds > voxMaxRefSeconds {
		t.Fatalf("voices.MaxRefSeconds = %v exceeds the VoxCPM2 window %d s", voices.MaxRefSeconds, voxMaxRefSeconds)
	}
}

func TestAddVoiceMetaRefusals(t *testing.T) {
	d, url, dir := metaServer(t)
	src := testutil.WriteSilentWAV(t, dir, "c.wav", 3)
	for name, extra := range map[string]string{
		"engine":        `"engine":"bogus"`,
		"style":         `"style":"` + strings.Repeat("x", maxStyleChars+1) + `"`,
		"designed_from": `"designed_from":"` + strings.Repeat("x", maxDesignedFromChars+1) + `"`,
	} {
		body := fmt.Sprintf(`{"name":"v","audio_path":%q,%s}`, src, extra)
		if code, resp := doJSON(t, http.MethodPost, url+"/v1/audio/voices", body); code != http.StatusBadRequest {
			t.Errorf("%s: POST = %d %s, want 400", name, code, resp)
		}
	}
	if _, err := d.Store.Get("v"); !errors.Is(err, voices.ErrNotFound) {
		t.Fatalf("a refused add stored a voice: %v", err)
	}
	// An add without metadata still answers with the original three keys.
	body := fmt.Sprintf(`{"name":"v","audio_path":%q}`, src)
	if code, resp := doJSON(t, http.MethodPost, url+"/v1/audio/voices", body); code != http.StatusOK || strings.Contains(resp, `"engine":`) {
		t.Fatalf("plain add = %d %s", code, resp)
	}
}

// The startup repair pass goes through RepairVoices; the voice's metadata
// survives it.
// Mutation: internal/voices/repair.go Apply — marshal the old three-field
// Voice{Name, RefText, Created} literal -> RED.
func TestRepairVoicesKeepsMeta(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	seedStoredVoice(t, d, "longref", 20, strings.TrimSpace(strings.Repeat("word ", 90)))
	d.Store.SetTranscriber(func(context.Context, string) ([]voices.Word, error) { return fakeWords(60), nil })
	engine, style := config.TTSModelVoxCPM2, "calm"
	if _, err := d.UpdateVoice("longref", &engine, &style); err != nil {
		t.Fatal(err)
	}
	d.RepairVoices(context.Background())
	v, err := d.Store.Get("longref")
	if err != nil || !strings.HasPrefix(v.RefText, "wa wb") {
		t.Fatalf("voice not repaired: %+v %v", v, err)
	}
	if v.Engine != engine || v.Style != style {
		t.Fatalf("repair dropped metadata: %+v", v.Meta)
	}
}

func TestSynthStatus(t *testing.T) {
	for _, tc := range []struct {
		err  error
		want int
	}{
		{&requestError{"x"}, http.StatusBadRequest},
		{fmt.Errorf("wrapped: %w", &requestError{"x"}), http.StatusBadRequest},
		{fmt.Errorf("w: %w", voices.ErrNotFound), http.StatusNotFound},
		{&unavailableError{"x"}, http.StatusUnprocessableEntity}, // a 4xx naming the reason, never a 5xx
		{&engineError{status: http.StatusServiceUnavailable, msg: "busy"}, http.StatusServiceUnavailable},
		{fmt.Errorf("%w: %v", errEngineStart, "no port"), http.StatusServiceUnavailable},
		{errors.New("boom"), http.StatusInternalServerError},
	} {
		if got := synthStatus(tc.err); got != tc.want {
			t.Errorf("synthStatus(%v) = %d, want %d", tc.err, got, tc.want)
		}
	}
}

// PATCH refuses a field it does not apply instead of answering 200 with
// nothing changed (#141.3): designed_from is deliberately not updatable.
// Mutation: internal/daemon/http.go handleUpdateVoice — delete the
// DisallowUnknownFields call -> RED (200, nothing applied).
func TestPatchVoiceRefusesUnknownField(t *testing.T) {
	d, url, _ := metaServer(t)
	seedStoredVoice(t, d, "nar", 8, "hello")
	good := readMeta(t, d, "nar")
	for _, body := range []string{`{"designed_from":"x"}`, `{"style":"calm","seed":1}`, `{"enginee":"x"}`} {
		code, resp := doJSON(t, http.MethodPatch, url+"/v1/audio/voices/nar", body)
		if code != http.StatusBadRequest {
			t.Errorf("PATCH %s = %d %s, want 400", body, code, resp)
		}
	}
	if got := readMeta(t, d, "nar"); got != good {
		t.Fatalf("a refused PATCH changed the file:\n%s\n%s", good, got)
	}
}
