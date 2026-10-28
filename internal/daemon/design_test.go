package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
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
	d.voxRefMax = 1
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
// Mutation R-exists: design.go SaveDesignedVoice, delete the early exists check AND service.go addVoice's createOnly check -> RED.
// Mutation R-style: service.go addVoice, delete the `pending.Fresh()` call -> RED.
// (R-exists also holds at the early check, and under voiceMu: see TestConcurrentSavesOntoOneNameKeepOne.)
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

// #160.8: the exists check and the write are one step under voiceMu. Two saves
// of different takes onto the same new name both pass the early check while
// each other's Prepare is in flight; exactly one may land, the other is a 409,
// and the voice on disk is the winner's, not a silent replacement.
// Mutation: service.go addVoice, delete the `d.Store.Get(name)` create-only
// check under voiceMu -> both succeed -> RED.
func TestConcurrentSavesOntoOneNameKeepOne(t *testing.T) {
	d, _, _ := designFixture(t)
	res := designThree(t, d)
	var arrived atomic.Int32
	d.slowPrepare = func() { // both saves are past the early check before either commits
		arrived.Add(1)
		for deadline := time.Now().Add(5 * time.Second); arrived.Load() < 2 && time.Now().Before(deadline); {
			time.Sleep(time.Millisecond)
		}
	}
	t.Cleanup(func() { d.slowPrepare = nil })
	errs := make([]error, 2)
	var wg sync.WaitGroup
	for i := range errs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, errs[i] = saveTake(t, d, "race", res.Takes[i].Path)
		}()
	}
	wg.Wait()
	won := -1
	for i, err := range errs {
		switch {
		case err == nil && won < 0:
			won = i
		case err == nil:
			t.Fatalf("both saves succeeded: the later one silently replaced the first")
		case synthStatus(err) != http.StatusConflict:
			t.Fatalf("save %d: %v (status %d), want 409", i, err, synthStatus(err))
		}
	}
	if won < 0 {
		t.Fatal("neither save succeeded")
	}
	if v, _ := d.Store.Get("race"); v == nil || v.Seed == nil || *v.Seed != res.Takes[won].Seed {
		t.Fatalf("stored voice %+v is not the winner's take (seed %d)", v, res.Takes[won].Seed)
	}
}

// #160.8: a failure to read the existing voice other than "not found" is an
// error, not "absent": saving over a voice whose metadata cannot be read would
// replace it unseen.
// Mutation: design.go SaveDesignedVoice, treat every Get error as absent again
// (`gerr == nil && !in.Replace` stays, drop the ErrNotFound test) -> RED.
func TestSaveRefusesWhenExistingVoiceUnreadable(t *testing.T) {
	d, _, _ := designFixture(t)
	res := designThree(t, d)
	if _, err := saveTake(t, d, "dup", res.Takes[0].Path); err != nil {
		t.Fatal(err)
	}
	meta := strings.TrimSuffix(d.Store.WAVPath("dup"), ".wav") + ".json"
	if err := os.Chmod(meta, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(meta, 0o644) })
	_, err := saveTake(t, d, "dup", res.Takes[1].Path)
	if err == nil {
		t.Fatal("a save onto an unreadable voice succeeded")
	}
	if strings.Contains(d.publicError(err).Error(), "/") {
		t.Fatalf("the refusal shows a path: %v", err)
	}
	if got, ierr := os.Stat(d.Store.WAVPath("dup")); ierr != nil || got.Size() == 0 {
		t.Fatal("the unreadable voice's audio was replaced")
	}
}

// #160.7: the scrub knows the daemon's own folders. A root with a space in it
// ("Application Support", the default home) must not leave its tail in the
// message, and a URL-like route in the text stays readable.
// Mutation: design.go publicError, delete the loop over d.privateRoots() ->
// the generic pattern stops at the space -> RED.
func TestPublicErrorScrubsKnownRootsWithSpaces(t *testing.T) {
	d, _, _ := designFixture(t)
	d.Cfg.Home = filepath.Join(t.TempDir(), "Library", "Application Support", "ox-say")
	d.Cfg.CacheDir = filepath.Join(d.Cfg.Home, "cache dir")
	for _, msg := range []string{
		"stat " + d.Cfg.Home + "/voices/nar.wav: no such file",
		"open " + d.Cfg.CacheDir + "/design/a.wav: permission denied",
	} {
		got := d.publicError(&requestError{msg}).Error()
		if strings.Contains(got, "Support") || strings.Contains(got, "cache dir") || strings.Contains(got, "ox-say") ||
			strings.Contains(got, "nar.wav") || !strings.Contains(got, "[path]") {
			t.Errorf("%q -> %q: a part of the path survived", msg, got)
		}
	}
	if got := d.publicError(&requestError{"POST /v1/audio/speech failed"}).Error(); !strings.Contains(got, "/v1/audio/speech") {
		t.Errorf("a route was rewritten: %q", got)
	}
}

// #160.4: the description a voice records is the one the engine heard
// (sanitised), not the raw request text with its brackets and line breaks.
// Mutation: design.go designTake, record `in.Description` instead of
// `sanitizeStyle(in.Description)` -> RED.
func TestDesignedFromRecordsTheSanitisedDescription(t *testing.T) {
	d, _, _ := designFixture(t)
	res, err := d.DesignVoice(context.Background(), DesignInput{Description: "calm) (loud\n​ voice", Text: testText, Takes: 1})
	if err != nil {
		t.Fatal(err)
	}
	v, err := saveTake(t, d, "clean", res.Takes[0].Path)
	if err != nil {
		t.Fatal(err)
	}
	if v.DesignedFrom != "calm loud voice" {
		t.Fatalf("designed_from = %q, want %q", v.DesignedFrom, "calm loud voice")
	}
}

// #160.5: takes are private to the user: a 0700 folder (also one made earlier
// as 0755) and 0600 files.
// Mutation: design.go designTake, writeFileMode(..., 0o600) -> 0o644 -> RED;
// DesignVoice, drop the os.Chmod(designDir, 0o700) -> RED.
func TestDesignTakesArePrivate(t *testing.T) {
	d, _, _ := designFixture(t)
	if err := os.MkdirAll(d.designDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	res := designThree(t, d)
	if st, err := os.Stat(d.designDir()); err != nil || st.Mode().Perm()&0o077 != 0 {
		t.Fatalf("design folder mode %v (%v), want no group/other access", st.Mode().Perm(), err)
	}
	for _, tk := range res.Takes {
		for _, p := range []string{tk.Path, strings.TrimSuffix(tk.Path, takeExt) + takeMetaExt} {
			if st, err := os.Stat(p); err != nil || st.Mode().Perm()&0o077 != 0 {
				t.Errorf("%s mode %v (%v), want no group/other access", filepath.Base(p), st.Mode().Perm(), err)
			}
		}
	}
}

// #160.1: takes older than a week are removed when a new design starts; newer
// ones, a take's record and files that are not takes are left alone.
// Mutation: design.go DesignVoice, delete the d.pruneOldTakes() call -> RED.
func TestDesignPrunesOldTakes(t *testing.T) {
	d, _, _ := designFixture(t)
	if err := os.MkdirAll(d.designDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	mk := func(name string, age time.Duration) string {
		p := filepath.Join(d.designDir(), name)
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		at := time.Now().Add(-age)
		if err := os.Chtimes(p, at, at); err != nil {
			t.Fatal(err)
		}
		return p
	}
	oldWAV, oldJSON := mk("old.wav", 8*24*time.Hour), mk("old.json", 8*24*time.Hour)
	newWAV, newJSON := mk("new.wav", 24*time.Hour), mk("new.json", 24*time.Hour)
	other := mk("notes.txt", 30*24*time.Hour)
	designThree(t, d)
	for _, p := range []string{oldWAV, oldJSON} {
		if _, err := os.Stat(p); err == nil {
			t.Errorf("%s survived", filepath.Base(p))
		}
	}
	for _, p := range []string{newWAV, newJSON, other} {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("%s was removed", filepath.Base(p))
		}
	}
}

// #160.10: the save hint tells how to overwrite a name that exists.
func TestDesignSaveHintMentionsReplace(t *testing.T) {
	d, _, _ := designFixture(t)
	if res := designThree(t, d); !strings.Contains(res.SaveHint, "--replace") {
		t.Fatalf("save hint %q does not mention --replace", res.SaveHint)
	}
}

// scrubRoot keeps the rest of the message when nothing delimits the path, and
// matches whole path components only.
// Mutation: design.go scrubRoot, end the path at a quote/colon/paren only (drop
// whitespace from the cut set) -> the first row loses " no such file" -> RED. Mutation:
// make boundedAfter always true -> "/database" is rewritten -> RED. Mutation:
// make boundedBefore always true -> "/x/data" is rewritten -> RED.
func TestScrubRootBoundariesAndRemainder(t *testing.T) {
	for _, tc := range []struct{ in, root, want string }{
		{"stat /data/voices/a.wav no such file", "/data", "stat [path] no such file"},
		{"stat /data/voices/a.wav", "/data", "stat [path]"},
		{"open /data: denied", "/data", "open [path]: denied"},
		{"open /database/x: denied", "/data", "open /database/x: denied"},
		{"open /x/data/y: denied", "/data", "open /x/data/y: denied"},
		{"a /data/1 and (/data/2) end", "/data", "a [path] and ([path]) end"},
		// #310.2: any character that cannot sit inside a path segment is a
		// boundary, not a hand-listed few.
		{"GET file:///Users/x/v/a.wav failed", "/Users/x", "GET file://[path] failed"},
		{"see [/Users/x/v/a.wav] now", "/Users/x", "see [[path]] now"},
		{"see [/Users/x] now", "/Users/x", "see [[path]] now"},
		{"ran `/Users/x/bin/tool` twice", "/Users/x", "ran `[path]` twice"},
		{"a,/Users/x/v;b", "/Users/x", "a,[path]"},
		{"a;/Users/x,b", "/Users/x", "a;[path],b"},
		{`C:\/Users/x\y`, "/Users/x", `C:\[path]\y`},
		{"cannot open /Users/x.", "/Users/x", "cannot open [path]."},
		{"cannot open /Users/x/a.wav.", "/Users/x", "cannot open [path]."},
		{"cannot open /Users/x/a.wav, retry", "/Users/x", "cannot open [path], retry"},
		{"<b>/Users/x/a</b>", "/Users/x", "<b>[path]</b>"},
		{"путь /Users/x/Иван/а.wav нет", "/Users/x", "путь [path] нет"},
		// A file name keeps its odd characters: the whole tail is scrubbed.
		{"open /Users/x/Movies/clip#2,final.wav now", "/Users/x", "open [path] now"},
		{"open /Users/x/Movies/a&b!.wav now", "/Users/x", "open [path] now"},
		{`open /Users/x/a\b.wav now`, "/Users/x", "open [path] now"},
		{"open /Users/x/a$b{c}.wav now", "/Users/x", "open [path] now"},
		{"open /Users/x/a.wav!", "/Users/x", "open [path]!"},
		{"open (/Users/x/a.wav, b) and /Users/x/c.wav; then", "/Users/x", "open ([path], b) and [path]; then"},
		{"/Users/xavier/a", "/Users/x", "/Users/xavier/a"},
		{"/Users/x.bak/a", "/Users/x", "/Users/x.bak/a"},
		{"a/Users/x/b", "/Users/x", "a/Users/x/b"},
		{"/Users/xé/a", "/Users/x", "/Users/xé/a"},
		// #323.1: a delimiter inside a file name (the next character continues
		// the name) is part of the name; one that ends a word is a boundary.
		{"open /Users/x/a]b.wav now", "/Users/x", "open [path] now"},
		{"open /Users/x/a(1).wav now", "/Users/x", "open [path] now"},
		{"open /Users/x/it's.wav now", "/Users/x", "open [path] now"},
		{`open /Users/x/a"b.wav now`, "/Users/x", "open [path] now"},
		{"open /Users/x/a:b.wav now", "/Users/x", "open [path] now"},
		{"open /Users/x/a`b.wav now", "/Users/x", "open [path] now"},
		{"stat '/Users/x/a.wav': denied", "/Users/x", "stat '[path]': denied"},
		{"open /Users/x/a.wav:12 now", "/Users/x", "open [path] now"},
		{"open /Users/x/take[1]-2.wav now", "/Users/x", "open [path] now"},
		{"open /Users/x/a(1)-b.wav now", "/Users/x", "open [path] now"},
		{"open /Users/x/a(1)#b&c.wav now", "/Users/x", "open [path] now"},
		{"failed: /Users/x/a.wav (retrying)", "/Users/x", "failed: [path] (retrying)"},
		{"open /Users/x/a.wav: permission denied", "/Users/x", "open [path]: permission denied"},
		{`{"path":"/Users/x/a.wav","n":1}`, "/Users/x", `{"path":"[path]","n":1}`},
		{`{"path":"/Users/x/a.wav"}`, "/Users/x", `{"path":"[path]"}`},
		{"see [a](/Users/x/a.wav) now", "/Users/x", "see [a]([path]) now"},
		{"see `/Users/x/a.wav`, ok", "/Users/x", "see `[path]`, ok"},
	} {
		if got := scrubRoot(tc.in, tc.root); got != tc.want {
			t.Errorf("scrubRoot(%q, %q) = %q, want %q", tc.in, tc.root, got, tc.want)
		}
	}
}

// Saving over a voice that cannot be read: damaged settings point to replace,
// a file nobody may read says to check its permissions (never to re-record).
// Mutation: voxcpm2.go voiceReadError, drop the `saving` branch -> "add the
// voice again" in the save flow -> RED.
func TestSaveOverUnreadableVoiceMessages(t *testing.T) {
	d, _, _ := designFixture(t)
	res := designThree(t, d)
	meta := func(name string) string { return strings.TrimSuffix(d.Store.WAVPath(name), ".wav") + ".json" }
	if _, err := saveTake(t, d, "dup", res.Takes[0].Path); err != nil {
		t.Fatal(err)
	}
	good, _ := os.ReadFile(meta("dup"))
	if err := os.WriteFile(meta("dup"), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := saveTake(t, d, "dup", res.Takes[1].Path)
	if err == nil || synthStatus(err) != http.StatusBadRequest || !strings.Contains(err.Error(), "replace") || strings.Contains(err.Error(), "add the voice again") {
		t.Fatalf("damaged: %v (status %d), want a 400 pointing to replace", err, synthStatus(err))
	}
	if err := os.WriteFile(meta("dup"), good, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(meta("dup"), 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(meta("dup"), 0o644) })
	_, err = saveTake(t, d, "dup", res.Takes[1].Path)
	if err == nil || synthStatus(err) != http.StatusBadRequest || !strings.Contains(err.Error(), "permissions") ||
		strings.Contains(err.Error(), "try again") || strings.Contains(err.Error(), "damaged") {
		t.Fatalf("unreadable file: %v (status %d), want a 400 about permissions", err, synthStatus(err))
	}
}

// #160.9: the design text cap is a spoken-duration cap, so a script that is
// spoken slowly per character (CJK) gets fewer characters than Russian does.
// Mutation: design.go validate, count every rune as one Latin/Cyrillic rune
// (cost := units per rune only) -> the Chinese row is accepted -> RED.
func TestDesignTextCapFollowsSpokenDuration(t *testing.T) {
	in := func(text string) *DesignInput { return &DesignInput{Description: "d", Text: text, Takes: 1} }
	for _, tc := range []struct {
		name string
		text string
		ok   bool
	}{
		{"cyrillic at the cap", strings.Repeat("я", maxDesignText), true},
		{"cyrillic over", strings.Repeat("я", maxDesignText+1), false},
		{"chinese 80", strings.Repeat("好", 80), true},
		{"chinese 81", strings.Repeat("好", 81), false},
		{"chinese 150", strings.Repeat("好", 150), false},
		{"kana 120", strings.Repeat("あ", 120), true},
		{"kana 121", strings.Repeat("あ", 121), false},
		{"hangul 121", strings.Repeat("가", 121), false},
		{"mixed", strings.Repeat("好", 60) + strings.Repeat("a", 60), false},
	} {
		err := in(tc.text).validate(1 << 20)
		if (err == nil) != tc.ok {
			t.Errorf("%s: validate = %v, want ok=%v", tc.name, err, tc.ok)
		}
	}
	err := in(strings.Repeat("好", 150)).validate(1 << 20)
	if err == nil || !strings.Contains(err.Error(), "longer than 80 characters") {
		t.Errorf("the refusal for Chinese must state its own cap, got %v", err)
	}
}

// #323.2: a voice removed while a speak was reading it is "no such voice", not
// "damaged": the re-read tells removed from half-removed.
// Mutation: voxcpm2.go voiceReadError, drop the ErrNotExist re-Get -> the row
// for a fully removed voice says "damaged" -> RED.
func TestVoiceReadErrorTellsRemovedFromHalfRemoved(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	placeVoxVoice(t, d, "half", config.TTSModelVoxCPM2, "", "", 2)
	if err := os.Remove(d.Store.WAVPath("half")); err != nil {
		t.Fatal(err)
	}
	gone := fmt.Errorf("open wav: %w", fs.ErrNotExist)
	if err := d.voiceReadError("half", gone, false); err == nil || !strings.Contains(err.Error(), "damaged") {
		t.Errorf("half-removed (json present): %v, want damaged", err)
	}
	if err := d.voiceReadError("never", gone, false); err == nil || strings.Contains(err.Error(), "damaged") || synthStatus(err) != http.StatusBadRequest {
		t.Errorf("removed (json gone): %v (status %d), want the no-such-voice 400", err, synthStatus(err))
	}
}

// #328.1: a stray path glued to a Markdown or tag edge is still a path.
// Mutation: design.go absPathStart, drop `[`, backtick, `<` and `>` from the
// start class -> every row but the first leaks -> RED.
func TestScrubStrayPathAfterMarkupEdge(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"see [/tmp/a](x) now", "see [[path]](x) now"},
		{"<b>/tmp/c</b>", "<b>[path]</b>"},
		{"ran `/tmp/a.wav` twice", "ran `[path]` twice"},
		{"a>/tmp/a.wav now", "a>[path] now"},
		{"x <b>/v1</b> y", "x <b>/v1</b> y"},
		{"open (/tmp/a.wav)", "open ([path])"},
	} {
		if got := scrubStrayPath(tc.in); got != tc.want {
			t.Errorf("scrubStrayPath(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// #328.2: a bare API word ("/v1", "/v2") is not a path; a comma or colon glued
// to a file name stays inside it (a name may hold both), so the rest of the
// word is scrubbed with it rather than leaked.
// Mutation: design.go scrubStrayPath, accept only the "/v1/" prefix again ->
// the "/v1" and "/v2" rows are scrubbed -> RED.
func TestScrubStrayPathKeepsBareAPIWord(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"GET /v1 failed", "GET /v1 failed"},
		{"GET /v1: denied", "GET /v1: denied"},
		{"GET /v2/models failed", "GET /v2/models failed"},
		{"GET /v1x failed", "GET [path] failed"},
		{"GET /v10 failed", "GET /v10 failed"},
		{"open /Users/x/a.wav,b now", "open [path] now"},
		{"open /Users/x/a.wav:permission now", "open [path] now"},
		{"open /tmp/clip#2,final.wav now", "open [path] now"},
	} {
		if got := scrubStrayPath(tc.in); got != tc.want {
			t.Errorf("scrubStrayPath(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// #323.1 / #160.7: a path outside every known root is cut by the same rule as
// the tail under a root, so a quote inside its file name does not leak.
// Mutation: design.go scrubStrayPath, end the path at the first quote again
// (regex `[^\s"'():]+`) -> the first row leaks "s.wav" -> RED.
func TestScrubStrayPathKeepsGluedDelimiterInName(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"cannot open '/stray/it's.wav'", "cannot open '[path]'"},
		{"cannot open /stray/take[1]-2.wav now", "cannot open [path] now"},
		{"stat /stray/a.wav: denied", "stat [path]: denied"},
		{"POST /v1/audio/speech failed", "POST /v1/audio/speech failed"},
		{"a / b", "a / b"},
	} {
		if got := scrubStrayPath(tc.in); got != tc.want {
			t.Errorf("scrubStrayPath(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
