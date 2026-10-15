package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/testutil"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

const (
	testDesc = "a deep calm narrator"
	testText = "Привет."
)

// designFixture is a vox daemon whose configured default voice is "nar".
func designFixture(t *testing.T) (d *Daemon, dir, logPath string) {
	t.Helper()
	d, dir, logPath = voxFixture(t, func(c *config.Config) {
		c.Voice = "nar"
		c.CacheDir = filepath.Join(t.TempDir(), "cache")
	})
	clip := testutil.WriteSilentWAV(t, dir, "c.wav", 3)
	if _, _, err := d.AddVoice(context.Background(), "nar", clip, ""); err != nil {
		t.Fatal(err)
	}
	return d, dir, logPath
}

func designThree(t *testing.T, d *Daemon) *DesignResult {
	t.Helper()
	seed := int64(100)
	res, err := d.DesignVoice(context.Background(), DesignInput{Description: testDesc, Text: testText, Takes: 3, Seed: &seed})
	if err != nil {
		t.Fatal(err)
	}
	return res
}

// Design renders N takes with consecutive seeds, no voice (not even the
// configured default voice), the description as the style tag, and writes each
// into the design dir under a name with the description slug and the seed.
// Mutation D-voice: design.go DesignVoice, drop `"voice": "default"` -> the
// configured OX_SAY_VOICE is cloned -> voice_ref present -> RED.
func TestDesignVoiceTakes(t *testing.T) {
	d, _, logPath := designFixture(t)
	res := designThree(t, d)
	if len(res.Takes) != 3 {
		t.Fatalf("takes %d", len(res.Takes))
	}
	reqs := voxLog(t, logPath)
	if len(reqs) != 3 {
		t.Fatalf("engine requests %d, want 3", len(reqs))
	}
	for i, r := range reqs {
		if r["input"] != "(a deep calm narrator)Привет." || r["voice_ref"] != nil || r["prompt_audio"] != nil || r["seed"] != float64(100+i) {
			t.Errorf("request %d: %v", i, r)
		}
		take := res.Takes[i]
		if _, err := os.Stat(take.Path); err != nil || take.Seed != int64(100+i) {
			t.Errorf("take %d: %+v %v", i, take, err)
		}
		if filepath.Dir(take.Path) != d.designDir() || !strings.Contains(filepath.Base(take.Path), "a-deep-calm-narrator") {
			t.Errorf("take %d path %q", i, take.Path)
		}
		if !strings.HasSuffix(filepath.Base(take.Path), "-10"+string(rune('0'+i))+".wav") {
			t.Errorf("take %d name %q does not end with its seed", i, take.Path)
		}
	}
	for i, take := range res.Takes {
		want := "ox-say voice save " + suggestVoiceName(testDesc, i+1) + " '" + take.Path + "'"
		if take.SuggestedName != suggestVoiceName(testDesc, i+1) || !strings.Contains(res.SaveHint, want) {
			t.Errorf("take %d: name %q, hint %q lacks %q", i, take.SuggestedName, res.SaveHint, want)
		}
	}
}

// Input limits: description and text required, takes 1..max, the description
// must survive the style sanitiser, the seed range must hold for every take.
func TestDesignVoiceRefusals(t *testing.T) {
	d, _, logPath := designFixture(t)
	huge := int64(maxVoxSeed)
	for _, bad := range []DesignInput{
		{Text: "x"}, {Description: "d"}, {Description: "d", Text: "x", Takes: maxDesignTakes + 1},
		{Description: "d", Text: "x", Takes: -1},
		{Description: "()\u200b", Text: "x"},
		{Description: "d", Text: strings.Repeat("я", maxDesignText+1)},
		{Description: strings.Repeat("я", maxStyleChars+1), Text: "x"},
		{Description: "d", Text: "x", Takes: 3, Seed: &huge},
		{Description: "d", Text: "(shout) x"},
	} {
		if _, err := d.DesignVoice(context.Background(), bad); err == nil {
			t.Errorf("accepted %+v", bad)
		} else if synthStatus(err) != http.StatusBadRequest {
			t.Errorf("%+v: status %d for %v", bad, synthStatus(err), err)
		}
	}
	if n := len(voxLog(t, logPath)); n != 0 {
		t.Errorf("a refused design reached the engine %d times", n)
	}
}

// The description is the engine's style tag: a bracket in it must not close or
// reopen the tag. Mutation D-sanitise: voxcpm2.go voxStyle,
// `style := sanitizeStyle(raw)` -> `style := raw` -> RED.
func TestDesignVoiceSanitisesDescription(t *testing.T) {
	d, _, logPath := designFixture(t)
	_, err := d.DesignVoice(context.Background(), DesignInput{Description: "calm) (loud\u200b voice", Text: "Привет.", Takes: 1})
	if err != nil {
		t.Fatal(err)
	}
	r := voxLog(t, logPath)
	if len(r) != 1 || r[0]["input"] != "(calm loud voice)Привет." {
		t.Fatalf("engine request %v", r)
	}
}

// Without the studio engine the design answers a plain-words 4xx, not a 5xx.
func TestDesignVoiceUnavailable(t *testing.T) {
	d := newTestDaemon(t, t.TempDir(), nil)
	_, err := d.DesignVoice(context.Background(), DesignInput{Description: "d", Text: "x"})
	if err == nil || synthStatus(err) != http.StatusUnprocessableEntity {
		t.Fatalf("err %v status %d, want 422", err, synthStatus(err))
	}
}

func saveTake(t *testing.T, d *Daemon, name, take string) (*voices.Voice, error) {
	t.Helper()
	v, _, err := d.SaveDesignedVoice(context.Background(), SaveDesignInput{Name: name, Take: take})
	return v, err
}

// Keeping a take makes a voxcpm2 voice that records the description, the seed
// and the exact text, all taken from the daemon's own record of the take.
// Mutation D-meta: design.go SaveDesignedVoice, drop `DesignedFrom:` from the
// Meta -> RED.
func TestSaveDesignedVoice(t *testing.T) {
	d, _, _ := designFixture(t)
	res := designThree(t, d)
	v, err := saveTake(t, d, "ru-host", res.Takes[1].Path)
	if err != nil {
		t.Fatal(err)
	}
	if v.Engine != config.TTSModelVoxCPM2 || v.DesignedFrom != testDesc || v.RefText != testText ||
		v.Seed == nil || *v.Seed != 101 || v.Style != "" {
		t.Fatalf("saved voice %+v", v)
	}
	got, err := d.Store.Get("ru-host")
	if err != nil || got.DesignedFrom != testDesc || got.Seed == nil || *got.Seed != 101 {
		t.Fatalf("stored voice %+v %v", got, err)
	}
}

func postJSONTo(d *Daemon, path, body string) *httptest.ResponseRecorder {
	mux := http.NewServeMux()
	d.Routes(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, path, strings.NewReader(body)))
	return rec
}

// A client cannot choose what the saved voice says about itself: designed_from,
// ref_text, engine, seed and style in the save request are ignored.
// Mutation D-forge: http.go/design.go handleSaveDesign, copy a client
// designed_from into SaveDesignInput.DesignedFrom -> RED.
func TestSaveDesignedVoiceIgnoresClientMetadata(t *testing.T) {
	d, _, _ := designFixture(t)
	res := designThree(t, d)
	body, _ := json.Marshal(map[string]any{
		"name": "ru-host", "take": res.Takes[0].Path,
		"designed_from": "forged", "ref_text": "forged", "engine": "qwen3-tts", "seed": 7, "style": "forged",
	})
	rec := postJSONTo(d, "/v1/audio/voices/design/save", string(body))
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}
	v, err := d.Store.Get("ru-host")
	if err != nil {
		t.Fatal(err)
	}
	if v.DesignedFrom != testDesc || v.RefText != testText || v.Engine != config.TTSModelVoxCPM2 ||
		v.Seed == nil || *v.Seed != 100 || v.Style != "" {
		t.Fatalf("client metadata leaked into %+v", v)
	}
}

// The take path comes from the client: it must stay inside the design dir.
// Traversal, absolute paths elsewhere, a symlinked file, a symlinked directory,
// a relative path and a WAV the design never made are all refused, and no
// voice is created.
// Mutation D-confine: design.go resolveTake, delete the within-dir check
// (`rel == ".."` ... branch) -> the outside file is accepted -> RED.
func TestSaveDesignedVoiceConfinedToDesignDir(t *testing.T) {
	d, dir, _ := designFixture(t)
	res := designThree(t, d)
	outside := testutil.WriteSilentWAV(t, dir, "outside.wav", 2)
	// A sidecar next to the outside file would make it look like a take.
	if err := os.WriteFile(strings.TrimSuffix(outside, ".wav")+".json", []byte(`{"description":"x","text":"y","seed":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(d.designDir(), "link.wav")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d.designDir(), "link.json"), []byte(`{"description":"x","text":"y","seed":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	dirLink := filepath.Join(d.designDir(), "sub")
	if err := os.Symlink(dir, dirLink); err != nil {
		t.Fatal(err)
	}
	stray := filepath.Join(d.designDir(), "stray.wav")
	if err := os.WriteFile(stray, testutil.SilentWAV(1), 0o644); err != nil {
		t.Fatal(err)
	}
	// A real take whose record is a symlink (even to a genuine record).
	recLink := strings.TrimSuffix(link, ".wav") + "-x.wav"
	if err := os.WriteFile(recLink, testutil.SilentWAV(1), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(strings.TrimSuffix(res.Takes[0].Path, ".wav")+".json", strings.TrimSuffix(recLink, ".wav")+".json"); err != nil {
		t.Fatal(err)
	}
	traversal, err := filepath.Rel(d.designDir(), outside)
	if err != nil || !strings.HasPrefix(traversal, "..") {
		t.Fatalf("traversal fixture %q %v", traversal, err)
	}
	for name, take := range map[string]string{
		"traversal":        d.designDir() + "/" + traversal,
		"absolute outside": outside,
		"symlinked file":   link,
		"symlinked dir":    filepath.Join(dirLink, "outside.wav"),
		"relative":         filepath.Base(res.Takes[0].Path),
		"no sidecar":       stray,
		"not a wav":        strings.TrimSuffix(res.Takes[0].Path, ".wav") + ".json",
		"record symlink":   recLink,
		"empty":            "",
	} {
		if _, err := saveTake(t, d, "stolen", take); err == nil {
			t.Errorf("%s: accepted %q", name, take)
		} else if synthStatus(err) != http.StatusBadRequest || (name != "empty" && !strings.Contains(err.Error(), "not a take made by voice design")) {
			t.Errorf("%s: status %d for %v", name, synthStatus(err), err)
		} else if name == "not a wav" && !strings.Contains(err.Error(), ".wav") {
			t.Errorf("%s: refused for the wrong reason: %v", name, err)
		}
	}
	if _, err := d.Store.Get("stolen"); err == nil {
		t.Fatal("a refused save created a voice")
	}
	if _, err := saveTake(t, d, "ok", res.Takes[0].Path); err != nil {
		t.Fatalf("a genuine take refused: %v", err)
	}
}

// A take longer than the reference window never reaches the engine as a voice:
// the save is refused in plain words and nothing is stored.
// Mutation D-limit: service.go AddVoiceMeta, delete the `checkVoxReference(secs)`
// call -> the voice is stored with engine voxcpm2 -> RED.
func TestSaveDesignedVoiceRefusesOverlongTake(t *testing.T) {
	d, _, _ := designFixture(t)
	t.Setenv("OXSAY_FAKE_VOX_SECS", "3")
	res := designThree(t, d)
	old := voxRefLimit
	voxRefLimit = 1
	t.Cleanup(func() { voxRefLimit = old })
	_, err := saveTake(t, d, "toolong", res.Takes[0].Path)
	if err == nil || !strings.Contains(err.Error(), "shorter clip") {
		t.Fatalf("err %v, want the plain-words refusal", err)
	}
	if _, gerr := d.Store.Get("toolong"); gerr == nil {
		t.Fatal("an over-long take was stored")
	}
}

// Over HTTP: design returns the takes, a missing field is a 400.
func TestDesignVoiceHTTP(t *testing.T) {
	d, _, _ := designFixture(t)
	rec := postJSONTo(d, "/v1/audio/voices/design", `{"description":"d","text":"Привет.","takes":2,"seed":5}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}
	var res DesignResult
	if err := json.Unmarshal(rec.Body.Bytes(), &res); err != nil || len(res.Takes) != 2 || res.Takes[1].Seed != 6 {
		t.Fatalf("%+v %v", res, err)
	}
	if rec := postJSONTo(d, "/v1/audio/voices/design", `{"text":"x"}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("missing description = %d", rec.Code)
	}
	if rec := postJSONTo(d, "/v1/audio/voices/design/save", `{"name":"x"}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("missing take = %d", rec.Code)
	}
}

// The MCP tools are thin layers over the same functions: design returns the
// takes, save returns the recorded provenance.
// Mutation D-mcp: design.go saveDesignResult, `Name: v.Name` -> `Name: ""` -> RED.
func TestDesignMCPTools(t *testing.T) {
	d, _, _ := designFixture(t)
	_, res, err := d.toolVoiceDesign(context.Background(), nil, DesignInput{Description: testDesc, Text: testText, Takes: 2})
	if err != nil || len(res.Takes) != 2 {
		t.Fatalf("%+v %v", res, err)
	}
	_, saved, err := d.toolVoiceDesignSave(context.Background(), nil, SaveDesignInput{Name: "agent-voice", Take: res.Takes[1].Path})
	if err != nil || saved.Name != "agent-voice" || saved.DesignedFrom != testDesc || saved.Seed != res.Takes[1].Seed || saved.Engine != config.TTSModelVoxCPM2 {
		t.Fatalf("%+v %v", saved, err)
	}
}

// MCP voice_design runs a cold start plus up to maxDesignTakes takes of the
// longest allowed text; go-mcpserver's 90 s default would cut it off mid-take.
// Mutation R-timeout: guard.go ServerConfig, delete the "voice_design" entry -> RED.
func TestDesignToolTimeoutCoversWorstCase(t *testing.T) {
	d, _, _ := designFixture(t)
	perTake := time.Duration(lengthBudget(strings.Repeat("я", maxDesignText)) * float64(time.Second))
	need := voxStartupTimeout + maxDesignTakes*perTake
	got := d.ServerConfig("test").ToolTimeouts["voice_design"]
	if got < need {
		t.Fatalf("voice_design tool timeout %v, worst case needs %v", got, need)
	}
}

// A runaway take (longer than its text plausibly needs) is reported on the
// take, not dropped. Mutation R-warn: design.go designTake, drop `Warning:`
// from the DesignTake literal -> RED.
func TestDesignTakeCarriesRenderWarning(t *testing.T) {
	d, _, _ := designFixture(t)
	t.Setenv("OXSAY_FAKE_VOX_SECS", "30")
	res, err := d.DesignVoice(context.Background(), DesignInput{Description: testDesc, Text: testText, Takes: 1})
	if err != nil || len(res.Takes) != 1 || !strings.Contains(res.Takes[0].Warning, "babble") {
		t.Fatalf("%+v %v", res, err)
	}
}

// The text cap keeps a take inside the reference window at the slowest
// measured pace, and a take that still runs over is flagged and not savable.
// Mutation R-long: design.go SaveDesignedVoice, delete the `secs > voices.MaxRefSeconds`
// refusal -> the clip is trimmed via STT instead -> RED.
func TestDesignTextCapAndOverlongTake(t *testing.T) {
	if float64(maxDesignText)/designSlowCharsPerSec > voices.MaxRefSeconds {
		t.Fatalf("maxDesignText %d can exceed %v s at %v chars/s", maxDesignText, voices.MaxRefSeconds, designSlowCharsPerSec)
	}
	d, _, _ := designFixture(t)
	t.Setenv("OXSAY_FAKE_VOX_SECS", "25")
	res, err := d.DesignVoice(context.Background(), DesignInput{Description: testDesc, Text: strings.Repeat("я", maxDesignText), Takes: 1})
	if err != nil || !strings.Contains(res.Takes[0].Warning, "shorter line") {
		t.Fatalf("%+v %v", res, err)
	}
	_, err = saveTake(t, d, "toolong", res.Takes[0].Path)
	if err == nil || synthStatus(err) != http.StatusBadRequest || !strings.Contains(err.Error(), "shorter line") {
		t.Fatalf("save of a 25 s take: %v", err)
	}
	if _, gerr := d.Store.Get("toolong"); gerr == nil {
		t.Fatal("an over-long take was stored")
	}
}

// Saving onto an existing name is refused (409) unless replace is set, and a
// replaced designed voice does not inherit the old voice's style.
// Mutation R-exists: design.go SaveDesignedVoice, delete the exists check -> RED.
// Mutation R-style: design.go SaveDesignedVoice, delete the style clear -> RED.
func TestSaveDesignedVoiceExistingName(t *testing.T) {
	d, _, _ := designFixture(t)
	res := designThree(t, d)
	if _, err := saveTake(t, d, "dup", res.Takes[0].Path); err != nil {
		t.Fatal(err)
	}
	style := "whisper"
	if _, err := d.UpdateVoice("dup", nil, &style); err != nil {
		t.Fatal(err)
	}
	_, err := saveTake(t, d, "dup", res.Takes[1].Path)
	if err == nil || synthStatus(err) != http.StatusConflict || !strings.Contains(err.Error(), `"dup" already exists`) {
		t.Fatalf("save onto an existing name: %v (status %d)", err, synthStatus(err))
	}
	if v, _ := d.Store.Get("dup"); v.Seed == nil || *v.Seed != 100 || v.Style != style {
		t.Fatalf("a refused save changed the voice: %+v", v)
	}
	body, _ := json.Marshal(map[string]any{"name": "dup", "take": res.Takes[1].Path, "replace": true})
	if rec := postJSONTo(d, "/v1/audio/voices/design/save", string(body)); rec.Code != http.StatusOK {
		t.Fatalf("replace: %d %s", rec.Code, rec.Body.String())
	}
	if v, _ := d.Store.Get("dup"); v.Seed == nil || *v.Seed != 101 || v.Style != "" {
		t.Fatalf("replaced voice %+v, want seed 101 and no inherited style", v)
	}
}

func TestSuggestVoiceName(t *testing.T) {
	for _, tc := range []struct {
		desc string
		n    int
		want string
	}{
		{"энергичная молодая ведущая, тёплый голос", 2, "energichnaya-molodaya-2"},
		{"A deep calm narrator", 1, "a-deep-calm-narrator-1"},
		{"()  ъь", 3, "voice-3"},
	} {
		got := suggestVoiceName(tc.desc, tc.n)
		if got != tc.want || voices.ValidateName(got) != nil {
			t.Errorf("suggestVoiceName(%q, %d) = %q, want %q", tc.desc, tc.n, got, tc.want)
		}
	}
}

// Error bodies on the design routes and tools carry no absolute paths: the
// detail goes to the log.
// Mutation R-disk: design.go diskError, return `err` instead of the plain
// message -> RED. (publicError itself is covered by TestPublicErrorWithholdsPaths.)
func TestDesignErrorsCarryNoPaths(t *testing.T) {
	d, dir, _ := designFixture(t)
	blocker := filepath.Join(dir, "blocker")
	if err := os.WriteFile(blocker, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	d.Cfg.CacheDir = filepath.Join(blocker, "cache") // MkdirAll must fail
	rec := postJSONTo(d, "/v1/audio/voices/design", `{"description":"d","text":"x"}`)
	if rec.Code != http.StatusInternalServerError || strings.Contains(rec.Body.String(), dir) || strings.Contains(rec.Body.String(), "blocker") {
		t.Fatalf("design: %d %s", rec.Code, rec.Body.String())
	}
	if _, _, err := d.toolVoiceDesign(context.Background(), nil, DesignInput{Description: "d", Text: "x"}); err == nil || strings.Contains(err.Error(), "blocker") {
		t.Fatalf("tool error %v", err)
	}
	rec = postJSONTo(d, "/v1/audio/voices/design/save", `{"name":"n","take":"`+filepath.Join(dir, "gone.wav")+`"}`)
	if strings.Contains(rec.Body.String(), dir) {
		t.Fatalf("save: %d %s", rec.Code, rec.Body.String())
	}
}

// A random base near the top of the seed range is clamped so every take's seed
// stays valid; the random source is injected.
// Mutation R-clamp: design.go DesignVoice, `base := min(designSeed(), ...)` ->
// `base := designSeed()` -> the engine refuses seed > max -> RED.
func TestDesignRandomSeedClamped(t *testing.T) {
	d, _, logPath := designFixture(t)
	old := designSeed
	designSeed = func() int64 { return maxVoxSeed }
	t.Cleanup(func() { designSeed = old })
	res, err := d.DesignVoice(context.Background(), DesignInput{Description: testDesc, Text: testText, Takes: 3})
	if err != nil {
		t.Fatal(err)
	}
	if got := res.Takes[2].Seed; got != maxVoxSeed || res.Takes[0].Seed != maxVoxSeed-2 {
		t.Fatalf("seeds %+v", res.Takes)
	}
	if len(voxLog(t, logPath)) != 3 {
		t.Fatal("not all takes rendered")
	}
}

// Mutation R-scrub: design.go publicError, `return err` as the first statement -> RED.
func TestPublicErrorWithholdsPaths(t *testing.T) {
	d, _, _ := designFixture(t)
	err := d.publicError(&requestError{"voices: audio: stat /Users/me/секрет/take.wav: no such file or directory"})
	if strings.Contains(err.Error(), "/Users") || !strings.Contains(err.Error(), "[path]") || synthStatus(err) != http.StatusBadRequest {
		t.Fatalf("%v (status %d)", err, synthStatus(err))
	}
	if keep := d.publicError(&requestError{"seed must be 0..5 and/or more"}); keep.Error() != "seed must be 0..5 and/or more" {
		t.Fatalf("a message without a path was changed: %v", keep)
	}
}
