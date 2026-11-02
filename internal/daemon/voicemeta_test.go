package daemon

import (
	"context"
	"encoding/json"
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
	if _, err := d.UpdateVoice("longref", &engine, &style, nil); err != nil {
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

// Mutation F1: internal/daemon/voicemeta.go UpdateVoice — delete the
// `v.Label = strings.TrimSpace(*label)` line -> RED.
// Mutation F3: internal/voices/repair.go Apply — marshal a literal that omits
// Meta -> RED (the repair assertion).
func TestVoiceLabelRoundTripsAndSurvivesRepair(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	// A long reference with a transcriber, as in TestRepairVoicesKeepsMeta:
	// without work to do, RepairVoices never rewrites the file and the repair
	// assertion below would pass whatever Apply marshals.
	seedStoredVoice(t, d, "moy-golos", 20, strings.TrimSpace(strings.Repeat("word ", 90)))
	d.Store.SetTranscriber(func(context.Context, string) ([]voices.Word, error) { return fakeWords(60), nil })
	label := "Мой голос"
	if _, err := d.UpdateVoice("moy-golos", nil, nil, &label); err != nil {
		t.Fatal(err)
	}
	v, err := d.Store.Get("moy-golos")
	if err != nil || v.Label != "Мой голос" {
		t.Fatalf("label not stored: %+v %v", v, err)
	}
	d.RepairVoices(context.Background())
	if v, _ = d.Store.Get("moy-golos"); !strings.HasPrefix(v.RefText, "wa wb") {
		t.Fatalf("the repair did not run, so this test proves nothing: %+v", v)
	}
	if v.Label != "Мой голос" {
		t.Fatalf("repair dropped the label: %+v", v.Meta)
	}
	empty := ""
	if _, err := d.UpdateVoice("moy-golos", nil, nil, &empty); err != nil {
		t.Fatal(err)
	}
	if v, _ = d.Store.Get("moy-golos"); v.Label != "" {
		t.Fatalf("an empty label must clear it: %q", v.Label)
	}
}

// A label is stored trimmed, and an update that names no label leaves it.
func TestVoiceLabelIsTrimmedAndKeptByOtherUpdates(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	seedStoredVoice(t, d, "nar", 8, "")
	label := "  Спокойный диктор  "
	if _, err := d.UpdateVoice("nar", nil, nil, &label); err != nil {
		t.Fatal(err)
	}
	style := "calm"
	if _, err := d.UpdateVoice("nar", nil, &style, nil); err != nil {
		t.Fatal(err)
	}
	if v, _ := d.Store.Get("nar"); v.Label != "Спокойный диктор" || v.Style != "calm" {
		t.Fatalf("stored = %+v", v.Meta)
	}
	bad := "a\nb"
	if _, err := d.UpdateVoice("nar", nil, nil, &bad); err == nil || synthStatus(err) != http.StatusBadRequest {
		t.Fatalf("a bad label must be a request error, got %v", err)
	}
	if v, _ := d.Store.Get("nar"); v.Label != "Спокойный диктор" {
		t.Fatalf("a refused label changed the voice: %q", v.Label)
	}
}

// Mutation F2: internal/daemon/voicemeta.go normalizeLabel — body -> `return nil`
// -> RED.
func TestVoiceLabelIsValidated(t *testing.T) {
	for name, bad := range map[string]string{
		"too long":       strings.Repeat("я", maxVoiceLabelChars+1),
		"newline":        "a\nb",
		"control":        "a\x07b",
		"tab":            "a\tb",
		"line separator": "a\u2028b",
		"bidi override":  "a\u202eb",
	} {
		if _, err := normalizeLabel(bad); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
	for name, ok := range map[string]string{
		"plain russian": "  Спокойный диктор  ",
		"at the limit":  strings.Repeat("я", maxVoiceLabelChars),
		"empty":         "",
	} {
		if _, err := normalizeLabel(ok); err != nil {
			t.Errorf("%s is valid: %v", name, err)
		}
	}
}

func TestPatchVoiceAcceptsLabelAndAddAcceptsLabelAndSource(t *testing.T) {
	d, url, dir := metaServer(t)
	src := testutil.WriteSilentWAV(t, dir, "c.wav", 3)
	add := fmt.Sprintf(`{"name":"v","audio_path":%q,"label":"Мой голос","source":"recorded"}`, src)
	if code, resp := doJSON(t, http.MethodPost, url+"/v1/audio/voices", add); code != http.StatusOK {
		t.Fatalf("POST = %d %s", code, resp)
	}
	if v, err := d.Store.Get("v"); err != nil || v.Label != "Мой голос" || v.Source != "recorded" {
		t.Fatalf("stored = %+v %v", v, err)
	}
	for name, extra := range map[string]string{
		"source":     `"source":"bogus"`,
		"label":      `"label":"x\ny"`,
		"long label": `"label":"` + strings.Repeat("я", maxVoiceLabelChars+1) + `"`,
	} {
		bad := fmt.Sprintf(`{"name":"w","audio_path":%q,%s}`, src, extra)
		if code, _ := doJSON(t, http.MethodPost, url+"/v1/audio/voices", bad); code != http.StatusBadRequest {
			t.Fatalf("add with bad %s = %d, want 400", name, code)
		}
	}
	if _, err := d.Store.Get("w"); !errors.Is(err, voices.ErrNotFound) {
		t.Fatalf("a refused add stored a voice: %v", err)
	}
	if code, resp := doJSON(t, http.MethodPatch, url+"/v1/audio/voices/v", `{"label":"Новый"}`); code != http.StatusOK || !strings.Contains(resp, `"label":"Новый"`) {
		t.Fatalf("PATCH label = %d %s", code, resp)
	}
	if code, _ := doJSON(t, http.MethodPatch, url+"/v1/audio/voices/v", `{"label":"x\ny"}`); code != http.StatusBadRequest {
		t.Fatalf("PATCH newline label = %d, want 400", code)
	}
	if code, _ := doJSON(t, http.MethodPatch, url+"/v1/audio/voices/v", `{"designed_from":"x"}`); code != http.StatusBadRequest {
		t.Fatalf("PATCH designed_from = %d, want 400 (strict decode)", code)
	}
	if code, _ := doJSON(t, http.MethodPatch, url+"/v1/audio/voices/v", `{"source":"file"}`); code != http.StatusBadRequest {
		t.Fatalf("PATCH source = %d, want 400 (source describes the audio)", code)
	}
	// Both readers serve them: the list and the single voice.
	for _, u := range []string{url + "/v1/audio/voices", url + "/v1/audio/voices/v"} {
		if code, resp := doJSON(t, http.MethodGet, u, ""); code != http.StatusOK || !strings.Contains(resp, `"label":"Новый"`) || !strings.Contains(resp, `"source":"recorded"`) {
			t.Fatalf("GET %s = %d %s", u, code, resp)
		}
	}
}

// The label that is checked is the label that is stored: the add path trims it
// before it is bounded and before the store sees it, so a blank label is no
// label (a re-add still inherits) and padding cannot dodge the length bound.
// Mutation: internal/daemon/voicemeta.go normalizeMeta — delete `m.Label = label`
// (the store gets the untrimmed value) -> RED.
func TestAddVoiceStoresTheTrimmedLabel(t *testing.T) {
	d, url, dir := metaServer(t)
	src := testutil.WriteSilentWAV(t, dir, "c.wav", 3)
	post := func(name, label string) int {
		t.Helper()
		body, _ := json.Marshal(map[string]string{"name": name, "audio_path": src, "label": label})
		code, _ := doJSON(t, http.MethodPost, url+"/v1/audio/voices", string(body))
		return code
	}
	max := strings.Repeat("я", maxVoiceLabelChars)
	for name, tc := range map[string]struct{ in, want string }{
		"leading newline":  {"\nabc", "abc"},
		"trailing newline": {"abc\n", "abc"},
		"blank":            {"   ", ""},
		"padded at limit":  {"  " + max + "  ", max},
	} {
		id := "v" + strings.ReplaceAll(name, " ", "")[:3]
		if code := post(id, tc.in); code != http.StatusOK {
			t.Fatalf("%s: POST = %d, want 200", name, code)
		}
		if v, err := d.Store.Get(id); err != nil || v.Label != tc.want {
			t.Errorf("%s: stored label = %q (%v), want %q", name, v.Label, err, tc.want)
		}
	}
	if code := post("toolong", max+"я"); code != http.StatusBadRequest {
		t.Fatalf("a label one character over the limit = %d, want 400", code)
	}
	if code := post("inner", "a\nb"); code != http.StatusBadRequest {
		t.Fatalf("an inner newline = %d, want 400", code)
	}
	// A blank label is "no label": a re-add inherits the earlier one.
	if code := post("keep", "Мой голос"); code != http.StatusOK {
		t.Fatal(code)
	}
	if code := post("keep", "   "); code != http.StatusOK {
		t.Fatal(code)
	}
	if v, _ := d.Store.Get("keep"); v.Label != "Мой голос" {
		t.Fatalf("a blank label on a re-add must inherit, got %q", v.Label)
	}
}
