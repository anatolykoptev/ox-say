package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
	"unicode"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/testutil"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

// newVoxTestDaemon is newTestDaemonVox on unified memory with the test binary as
// audiocpp_server and an empty model file, so VoxCPM2Unavailable() == "".
func newVoxTestDaemon(t *testing.T, dir string, edit func(*config.Config)) *Daemon {
	t.Helper()
	model := filepath.Join(dir, config.VoxCPM2ModelFile)
	if err := os.WriteFile(model, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	return newTestDaemonVox(t, dir, func(c *config.Config) {
		c.GPUMemory = config.GPUMemoryUnified
		c.VoxCPM2Bin = os.Args[0]
		c.VoxCPM2Model = model
		c.VoxCPM2Port = testutil.FreePort(t)
		if edit != nil {
			edit(c)
		}
	}, nil, nil, nil)
}

// The voxcpm2 child is spawned with --config <run>/voxcpm2-server.json (and
// nothing else) naming the model, the loopback IP — never "localhost" or
// "[::1]", which audio.cpp's guard refuses — the configured port, and the
// encoder capacity a 17 s reference voice needs; it reaches Ready.
// Mutation A: voxcpm2.go voxcpm2ServerArgs, `return nil` -> the fake never
// starts -> RED. Mutation B: voxcpm2.go voxcpm2ServerConfig, host
// voxLoopbackHost -> "localhost" -> RED. Mutation C: drop the
// "voxcpm2.audiovae_encoder_sample_capacity" entry -> RED.
func TestVoxCPM2ChildSpawnsWithServerConfig(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_VOX", "1")
	d := newVoxTestDaemon(t, dir, nil)
	base, err := d.VoxSup.EnsureReady(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	cfgPath := filepath.Join(d.Cfg.RunDir(), voxcpm2ServerFile)
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	var sc struct {
		Host   string `json:"host"`
		Port   int    `json:"port"`
		Models []struct {
			ID, Family, Path string
			Options          map[string]float64 `json:"session_options"`
		} `json:"models"`
	}
	if err := json.Unmarshal(raw, &sc); err != nil {
		t.Fatal(err)
	}
	if sc.Host != "127.0.0.1" || base != fmt.Sprintf("http://127.0.0.1:%d", sc.Port) || sc.Port != d.Cfg.VoxCPM2Port ||
		len(sc.Models) != 1 || sc.Models[0].Family != "voxcpm2" || sc.Models[0].Path != d.Cfg.VoxCPM2Model {
		t.Fatalf("server config %s, base %s", raw, base)
	}
	const capKey = "voxcpm2.audiovae_encoder_sample_capacity"
	if got := sc.Models[0].Options[capKey]; got != voxEncoderSampleCapacity {
		t.Fatalf("%s = %v, want %d (the default 240000 fails a 17 s reference)", capKey, got, voxEncoderSampleCapacity)
	}
	stamps, _ := filepath.Glob(filepath.Join(dir, "vox-spawn-*"))
	if len(stamps) != 1 {
		t.Fatalf("spawn stamps = %v", stamps)
	}
	argv, _ := os.ReadFile(stamps[0])
	if want := "--config\n" + cfgPath + "\n--no-ui"; string(argv) != want {
		t.Fatalf("child argv = %q, want %q", argv, want)
	}
	if st := d.Status().VoxCPM2; !st.Available || st.State != engine.StateReady {
		t.Fatalf("status voxcpm2 = %+v", st)
	}
}

// The argv builder never emits --parallel-jobs (that server path has neither
// the loopback Host guard nor prompt_audio, issue #137.1) nor --log (input text
// would reach voxcpm2.log). Pinned on the real builder, not a copy.
// Mutation: voxcpm2.go voxcpm2ServerArgs, append "--parallel-jobs" -> RED.
func TestVoxCPM2ServerArgsNeverParallelJobs(t *testing.T) {
	cfg := &config.Config{Home: t.TempDir(), VoxCPM2Model: "m.gguf"}
	if err := os.MkdirAll(cfg.RunDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	args := voxcpm2ServerArgs(cfg, testutil.FreePort(t), testLogger(t))
	if len(args) != 3 || args[0] != "--config" || args[2] != "--no-ui" {
		t.Fatalf("argv = %v", args)
	}
	for _, a := range args {
		if a == "--parallel-jobs" || a == "--log" || a == "--log-file" {
			t.Fatalf("argv %v carries %s", args, a)
		}
	}
	if _, err := os.Stat(args[1]); err != nil {
		t.Fatalf("server config not written: %v", err)
	}
}

// /status voxcpm2 is something a UI can render: Intel and a missing model are
// "unavailable" with a plain reason (no daemon-side child at all on Intel); an
// installed engine is available and "stopped" before first use.
// Mutation: service.go newDaemon, drop the `if cfg.UnifiedMemory()` guard
// around newVoxSupervisor -> the Intel daemon gets a VoxSup -> RED.
func TestVoxCPM2StatusStates(t *testing.T) {
	intel := newTestDaemonSTT(t, t.TempDir(), nil, nil, nil)
	if intel.VoxSup != nil {
		t.Fatal("a discrete-memory daemon built a voxcpm2 supervisor")
	}
	if st := intel.Status().VoxCPM2; st.Available || st.State != "unavailable" || !strings.Contains(st.Reason, "Apple Silicon") {
		t.Fatalf("Intel status = %+v", st)
	}

	noModel := newTestDaemonSTT(t, t.TempDir(), func(c *config.Config) {
		c.GPUMemory = config.GPUMemoryUnified
		c.VoxCPM2Model = filepath.Join(t.TempDir(), "absent.gguf")
	}, nil, nil)
	if st := noModel.Status().VoxCPM2; st.Available || st.State != "unavailable" || !strings.Contains(st.Reason, "model is not downloaded") {
		t.Fatalf("binary without model status = %+v", st)
	}

	ok := newVoxTestDaemon(t, t.TempDir(), nil)
	st := ok.Status()
	if !st.VoxCPM2.Available || st.VoxCPM2.State != engine.StateStopped || st.VoxCPM2.Reason != "" {
		t.Fatalf("installed status = %+v", st.VoxCPM2)
	}
	raw, err := json.Marshal(st)
	if err != nil || !strings.Contains(string(raw), `"voxcpm2":{"available":true,"state":"stopped"`) {
		t.Fatalf("status JSON = %s (%v)", raw, err)
	}
	if got := st.Config["tts_model"]; got != config.TTSModelQwen {
		t.Fatalf("status config tts_model = %v", got)
	}
}

// The child holds ~4 GB while loaded, so the daemon's idle stop must apply to
// it: Ready -> Stopped after OX_SAY_IDLE_STOP_SECS without use.
// Mutation: voxcpm2.go newVoxSupervisor, delete the `IdleStop: cfg.IdleStop,`
// line -> the child never stops -> RED.
func TestVoxCPM2IdleStopWired(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_VOX", "1")
	const idle = 300 * time.Millisecond
	d := newVoxTestDaemon(t, dir, func(c *config.Config) { c.IdleStop = idle })
	if _, err := d.VoxSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for d.Status().VoxCPM2.State != engine.StateStopped {
		if time.Now().After(deadline) {
			t.Fatalf("voxcpm2 still %q well past an idle stop of %v", d.Status().VoxCPM2.State, idle)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// Daemon.Shutdown must stop the voxcpm2 child: a ~4 GB audiocpp_server left
// behind survives until the next start's orphan reaper (issue #139.1), and the
// supervisor must refuse new work afterwards.
// Mutation: service.go Daemon.Shutdown, delete the `d.VoxSup.Shutdown()` call
// -> the stamped pid stays alive -> RED.
func TestDaemonShutdownStopsVoxChild(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	t.Setenv("OXSAY_FAKE_VOX", "1")
	d := newVoxTestDaemon(t, dir, nil)
	if _, err := d.VoxSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	stamps, _ := filepath.Glob(filepath.Join(dir, "vox-spawn-*"))
	if len(stamps) != 1 {
		t.Fatalf("spawn stamps = %v", stamps)
	}
	pid, err := strconv.Atoi(strings.TrimPrefix(filepath.Base(stamps[0]), "vox-spawn-"))
	if err != nil || pid <= 0 {
		t.Fatalf("stamp %s: unusable pid", stamps[0])
	}
	t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) }) // never leak a failing run's child
	if !alive(pid) {
		t.Fatalf("child %d is not running before Shutdown", pid)
	}
	d.Shutdown()
	if alive(pid) {
		t.Fatalf("voxcpm2 child %d survived Daemon.Shutdown", pid)
	}
	if _, err := d.VoxSup.EnsureReady(context.Background()); !errors.Is(err, engine.ErrShutdown) {
		t.Fatalf("EnsureReady after Shutdown = %v, want engine.ErrShutdown", err)
	}
}

// voxLog reads the speech bodies the fake audiocpp_server recorded.
func voxLog(t *testing.T, path string) []map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatal(err)
		}
		out = append(out, m)
	}
	return out
}

// voxFixture is a vox-enabled daemon whose fake child logs to logPath.
func voxFixture(t *testing.T, edit func(*config.Config)) (d *Daemon, dir, logPath string) {
	t.Helper()
	dir = t.TempDir()
	fakeEnv(t, dir)
	logPath = filepath.Join(dir, "vox.log")
	t.Setenv("OXSAY_FAKE_VOX", "1")
	t.Setenv("OXSAY_FAKE_VOX_LOG", logPath)
	return newVoxTestDaemon(t, dir, edit), dir, logPath
}

// postSpeech POSTs body to the daemon's speech handler.
func postSpeech(d *Daemon, body string) *httptest.ResponseRecorder {
	mux := http.NewServeMux()
	d.Routes(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/audio/speech", strings.NewReader(body)))
	return rec
}

// bodyText is the response body, cut short: a wrongly accepted request answers
// with a whole WAV, which must not flood a failure message.
func bodyText(rec *httptest.ResponseRecorder) string {
	const limit = 200
	b := rec.Body.Bytes()
	if len(b) > limit {
		b = b[:limit]
	}
	return string(b)
}

// placeVoxVoice writes a voice straight into the store, bypassing the add
// path (and its reference cut), as a legacy or hand-placed voice would be.
func placeVoxVoice(t *testing.T, d *Daemon, name, engineName, style, refText string, secs float64) {
	t.Helper()
	if err := os.WriteFile(d.Store.WAVPath(name), testutil.SilentWAV(secs), 0o644); err != nil {
		t.Fatal(err)
	}
	meta, _ := json.Marshal(map[string]any{
		"name": name, "ref_text": refText, "engine": engineName, "style": style, "created": "2026-10-04T14:28:00Z",
	})
	if err := os.WriteFile(strings.TrimSuffix(d.Store.WAVPath(name), ".wav")+".json", meta, 0o644); err != nil {
		t.Fatal(err)
	}
}

// FF1: every engine request carries the engine's own runaway guard at the
// upstream defaults, a take longer than the plausibility budget carries a
// warning, and the request's seed reaches the engine and comes back.
// Mutation F-guard: voxcpm2.go buildVoxCPM2, delete the "options" entry
// -> the retry_badcase assertion is RED. Mutation F-budget: drop the
// `dur > req.budgetSec` condition (make it false) -> Warning empty -> RED.
// Mutation F-seed: speak.go Speak, delete the `params[fieldSeed] = *in.Seed`
// line -> the engine gets a random seed -> RED.
func TestVoxCPM2RunawayGuard(t *testing.T) {
	d, _, logPath := voxFixture(t, nil)
	t.Setenv("OXSAY_FAKE_VOX_SECS", "30") // 15 chars -> budget 5.5 s
	seed := int64(41)
	res, err := d.Speak(context.Background(), SpeakInput{Text: "ox-say is ready", Model: "voxcpm2", Seed: &seed})
	if err != nil {
		t.Fatal(err)
	}
	reqs := voxLog(t, logPath)
	if len(reqs) != 1 {
		t.Fatalf("engine requests = %d, want 1 (no daemon-side retry)", len(reqs))
	}
	opts, _ := reqs[0]["options"].(map[string]any)
	if opts["retry_badcase"] != true || opts["retry_badcase_max_times"] != float64(voxRetryTimes) ||
		opts["retry_badcase_ratio_threshold"] != float64(voxRetryRatio) {
		t.Fatalf("engine guard not sent: %v", reqs[0])
	}
	if reqs[0]["seed"] != float64(seed) {
		t.Fatalf("seed %d did not reach the engine: %v", seed, reqs[0])
	}
	if _, set := reqs[0]["max_tokens"]; set {
		t.Fatalf("max_tokens must be left to the engine's ratio bound: %v", reqs[0])
	}
	if res.Warning == "" || res.Model != "voxcpm2" || res.Seed == nil || *res.Seed != seed {
		t.Fatalf("result %+v", res)
	}
}

// The seed over HTTP: json.Number keeps its value, the engine gets it, the
// response says which seed was used (also when the daemon drew it), and a seed
// outside the engine's range is refused before any engine work.
// Mutation F-seed-http: voxcpm2.go voxSeed, `return randomSeed(), nil` as the
// first statement -> the engine gets a random seed -> RED.
func TestVoxCPM2SeedOverHTTP(t *testing.T) {
	d, _, logPath := voxFixture(t, nil)
	rec := postSpeech(d, `{"input":"Проверка.","model":"voxcpm2","seed":5}`)
	if rec.Code != http.StatusOK || rec.Header().Get("X-Ox-Say-Model") != "voxcpm2" || rec.Header().Get("X-Ox-Say-Seed") != "5" {
		t.Fatalf("%d %v", rec.Code, rec.Header())
	}
	if r := voxLog(t, logPath); len(r) != 1 || r[0]["seed"] != float64(5) {
		t.Fatalf("engine requests %v", r)
	}
	rec = postSpeech(d, `{"input":"Проверка.","model":"voxcpm2"}`)
	drawn, err := strconv.ParseInt(rec.Header().Get("X-Ox-Say-Seed"), 10, 64)
	if rec.Code != http.StatusOK || err != nil {
		t.Fatalf("unseeded: %d %v", rec.Code, rec.Header())
	}
	if r := voxLog(t, logPath); len(r) != 2 || r[1]["seed"] != float64(drawn) {
		t.Fatalf("header seed %d is not the engine's: %v", drawn, r)
	}
	if rec = postSpeech(d, `{"input":"x","model":"voxcpm2","seed":4294967296}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("seed past uint32 = %d %s", rec.Code, bodyText(rec))
	}
}

// FF2: nothing set -> qwen; model voxcpm2 or a voice preferring it -> voxcpm2;
// an explicit qwen model beats the voice preference (this is how the
// dictation app's speak-selection stays on the fast engine); an OpenAI name
// keeps the default. Through the HTTP handler too, and the default model is
// qwen3-tts.
// Mutation F-default: tts_route.go prepareSpeech, `model = d.Cfg.TTSModel` ->
// `model = config.TTSModelVoxCPM2` -> cases 1 and 4 route to voxcpm2 -> RED.
// Mutation F-voice: drop the voice-engine branch (`model = v.Engine`) ->
// case 2 goes to qwen -> RED.
func TestSpeechRoutesByModel(t *testing.T) {
	d, dir, logPath := voxFixture(t, nil)
	clip := testutil.WriteSilentWAV(t, dir, "c.wav", 3)
	if _, _, err := d.AddVoiceMeta(context.Background(), "nar", clip, "", voices.Meta{Engine: "voxcpm2", Style: "calm"}); err != nil {
		t.Fatal(err)
	}
	if d.Cfg.TTSModel != config.TTSModelQwen {
		t.Fatalf("test daemon default model = %q", d.Cfg.TTSModel)
	}
	cases := []struct {
		in   SpeakInput
		want string
	}{
		{SpeakInput{Text: "a"}, "qwen3-tts"},
		{SpeakInput{Text: "b", Voice: "nar"}, "voxcpm2"},
		{SpeakInput{Text: "c", Voice: "nar", Model: "qwen3-tts"}, "qwen3-tts"},
		{SpeakInput{Text: "d", Model: "tts-1-hd"}, "qwen3-tts"},
	}
	for _, tc := range cases {
		res, err := d.Speak(context.Background(), tc.in)
		if err != nil {
			t.Fatalf("%+v: %v", tc.in, err)
		}
		if res.Model != tc.want {
			t.Errorf("%+v routed to %s, want %s", tc.in, res.Model, tc.want)
		}
	}
	rec := postSpeech(d, `{"input":"e","voice":"nar","model":"qwen3-tts","response_format":"wav"}`)
	if rec.Code != http.StatusOK || rec.Header().Get("X-Ox-Say-Model") == "voxcpm2" {
		t.Fatalf("handler: %d %v", rec.Code, rec.Header())
	}
	reqs := voxLog(t, logPath)
	if len(reqs) != 1 || reqs[0]["input"] != "(calm)b" {
		t.Fatalf("voxcpm2 requests %v; want 1, with the voice's default style", reqs)
	}
	rec = postSpeech(d, `{"input":"f","cfg_value":3}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "voxcpm2") {
		t.Fatalf("a voxcpm2 knob on qwen must be refused: %d %s", rec.Code, bodyText(rec))
	}
}

// H1: defaults run once. voice "default" means no voice even when OX_SAY_VOICE
// names one. Mutation: call applyVoiceDefault again inside synthesize -> the
// configured voice is cloned -> voice_ref present -> RED.
func TestVoxCPM2DefaultVoiceMeansNoVoice(t *testing.T) {
	d, dir, logPath := voxFixture(t, func(c *config.Config) { c.Voice = "nar" })
	clip := testutil.WriteSilentWAV(t, dir, "c.wav", 3)
	if _, _, err := d.AddVoice(context.Background(), "nar", clip, ""); err != nil {
		t.Fatal(err)
	}
	rec := postSpeech(d, `{"input":"Привет.","voice":"default","model":"voxcpm2","instructions":"a deep narrator"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, bodyText(rec))
	}
	if r := voxLog(t, logPath)[0]; r["voice_ref"] != nil || r["input"] != "(a deep narrator)Привет." {
		t.Fatalf("design request cloned a voice: %v", r)
	}
}

func TestBuildVoxCPM2Modes(t *testing.T) {
	v := &voices.Voice{Name: "r", RefText: "привет мир"}
	cfg := 2.5
	body := map[string]any{"input": "Текст.", "seed": int64(3), "cfg_value": cfg}
	r, err := buildVoxCPM2(body, v, "/v/r.wav")
	if err != nil {
		t.Fatal(err)
	}
	if r.body["prompt_audio"] != "/v/r.wav" || r.body["reference_text"] != "привет мир" || r.body["guidance_scale"] != cfg {
		t.Fatalf("auto, same script, no style must be ultimate: %v", r.body)
	}
	r, err = buildVoxCPM2(map[string]any{"input": "Hello there."}, v, "/v/r.wav")
	if err != nil || r.body["prompt_audio"] != nil || r.body["voice_ref"] == nil {
		t.Fatalf("auto across scripts must be reference cloning (M7): %v %v", r.body, err)
	}
	body["instructions"] = "(excited), fast"
	r, err = buildVoxCPM2(body, v, "/v/r.wav")
	if err != nil || r.body["input"] != "(excited, fast)Текст." || r.body["prompt_audio"] != nil {
		t.Fatalf("style must switch to reference cloning and sanitize parens: %v %v", r.body, err)
	}
	for _, bad := range []map[string]any{
		{"input": "x", "clone_mode": "ultimate"},                         // no voice (vv=nil below)
		{"input": "x", "instructions": "calm", "clone_mode": "ultimate"}, // style + ultimate
		{"input": "(aside) x", "instructions": "calm"},                   // two tags
		{"input": "x", "cfg_value": 9.0},
		{"input": "x", "inference_timesteps": 0},
		{"input": "x", "seed": int64(1) << 32},
		{"input": strings.Repeat("я", maxVoxChars+1)},
	} {
		vv := v
		if bad["clone_mode"] == "ultimate" && bad["instructions"] == nil {
			vv = nil
		}
		if _, err := buildVoxCPM2(bad, vv, "/v/r.wav"); err == nil {
			t.Errorf("accepted %v", bad)
		}
	}
}

// #141.1: a style (request or the voice's default) with ")", "(" or a newline
// must not close the engine's tag early or open a second one: the engine gets
// exactly one well-formed leading "(...)" group and the text after it is the
// caller's own.
// Mutation F-sanitise: voxcpm2.go voxStyle, `style = sanitizeStyle(style)` ->
// `style = strings.TrimSpace(style)` -> RED on every row.
func TestVoxCPM2StyleCannotBreakOutOfTheTag(t *testing.T) {
	d, dir, logPath := voxFixture(t, nil)
	clip := testutil.WriteSilentWAV(t, dir, "c.wav", 3)
	if _, _, err := d.AddVoiceMeta(context.Background(), "nar", clip, "", voices.Meta{Engine: "voxcpm2", Style: "calm\n) shout ("}); err != nil {
		t.Fatal(err)
	}
	const text = "Привет, мир."
	for name, body := range map[string]string{
		"request":       `{"input":"` + text + `","model":"voxcpm2","instructions":"a\nb) injected ("}`,
		"voice default": `{"input":"` + text + `","voice":"nar"}`,
		"controls":      `{"input":"` + text + `","model":"voxcpm2","instructions":"x\u0000\t\r\ny z"}`,
	} {
		before := len(voxLog(t, logPath))
		if rec := postSpeech(d, body); rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", name, rec.Code, bodyText(rec))
		}
		got := voxLog(t, logPath)[before]["input"].(string)
		tag, rest, ok := strings.Cut(strings.TrimPrefix(got, "("), ")")
		if !strings.HasPrefix(got, "(") || !ok || rest != text ||
			strings.ContainsAny(tag, "()") || strings.ContainsFunc(tag, unicode.IsControl) {
			t.Errorf("%s: engine input %q is not one clean (...) group followed by the text", name, got)
		}
	}
	if got := sanitizeStyle("a\nb) injected ("); got != "a b injected" {
		t.Errorf("sanitizeStyle = %q", got)
	}
	// Delegation to vscript.CleanStyle: a format character cannot survive.
	if got := sanitizeStyle("\u200b"); got != "" {
		t.Errorf("sanitizeStyle(U+200B) = %q, want empty", got)
	}
}

// Asking for voxcpm2 on a host that cannot run it is a 4xx in plain words that
// names the reason, and the child is never started: the supervisor exists on
// every unified-memory Mac, with or without the model. A voice that merely
// PREFERS voxcpm2 degrades to qwen with a warning (M2).
// Mutation F-unavail: voxcpm2.go synthesizeVoxCPM2, delete the
// `if why := d.voxUnavailable(); why != ""` block -> the request spawns the
// child and answers 200 (or 500) -> RED. Mutation F-degrade: tts_route.go
// prepareSpeech, make the degrade `if why := d.voxUnavailable(); false &&
// why != ""` -> the voice case errors -> RED.
func TestVoxCPM2RefusedWhereUnavailable(t *testing.T) {
	for name, edit := range map[string]func(*config.Config){
		"model missing": func(c *config.Config) { c.VoxCPM2Model = filepath.Join(filepath.Dir(c.VoxCPM2Model), "absent.gguf") },
		"discrete card": func(c *config.Config) { c.GPUMemory = config.GPUMemoryDiscrete },
	} {
		t.Run(name, func(t *testing.T) {
			d, dir, logPath := voxFixture(t, edit)
			want := map[string]string{"model missing": "not downloaded", "discrete card": "Apple Silicon"}[name]
			rec := postSpeech(d, `{"input":"hi","model":"voxcpm2"}`)
			if rec.Code < 400 || rec.Code >= 500 || !strings.Contains(rec.Body.String(), want) {
				t.Fatalf("%d %s, want a 4xx naming %q", rec.Code, bodyText(rec), want)
			}
			if stamps, _ := filepath.Glob(filepath.Join(dir, "vox-spawn-*")); len(stamps) != 0 || len(voxLog(t, logPath)) != 0 {
				t.Fatalf("the child was started for a refused request: %v", stamps)
			}
			placeVoxVoice(t, d, "nar", config.TTSModelVoxCPM2, "", "", 3)
			res, err := d.Speak(context.Background(), SpeakInput{Text: "hi", Voice: "nar"})
			if err != nil || res.Model != "qwen3-tts" || !strings.Contains(res.Warning, d.Cfg.VoxCPM2Unavailable()) {
				t.Fatalf("preference must degrade to qwen with a warning: %+v %v", res, err)
			}
		})
	}
}

// #141.2: the reference-length rule holds at speech time, for a voice the add
// path never checked (hand-placed, legacy), whether it is tagged voxcpm2 or
// reaches voxcpm2 through the global default.
// Mutation F-reflen: voxcpm2.go resolveVoxVoice, delete the `checkVoxReference`
// call (make the `if err := checkVoxReference(secs); err != nil` condition
// `err != nil && false`) -> the engine gets the long clip -> RED.
func TestVoxCPM2ChecksReferenceLengthAtSpeechTime(t *testing.T) {
	d, _, logPath := voxFixture(t, func(c *config.Config) { c.TTSModel = config.TTSModelVoxCPM2 })
	placeVoxVoice(t, d, "legacy", "", "", "", voxMaxRefSeconds+1)
	placeVoxVoice(t, d, "tagged", config.TTSModelVoxCPM2, "", "", voxMaxRefSeconds+1)
	placeVoxVoice(t, d, "edge", "", "", "", voxMaxRefSeconds)
	for _, name := range []string{"legacy", "tagged"} {
		rec := postSpeech(d, `{"input":"hi","voice":"`+name+`"}`)
		if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "at most 30 seconds") {
			t.Fatalf("%s: %d %s", name, rec.Code, bodyText(rec))
		}
	}
	if n := len(voxLog(t, logPath)); n != 0 {
		t.Fatalf("an over-long reference reached the engine (%d requests)", n)
	}
	if rec := postSpeech(d, `{"input":"hi","voice":"edge"}`); rec.Code != http.StatusOK {
		t.Fatalf("a reference exactly at the limit = %d %s", rec.Code, bodyText(rec))
	}
}

// Re-adding a voice without an engine inherits its stored one, so the add-time
// reference check must run on the inherited engine too.
// Mutation F-inherit: service.go AddVoiceMeta, `d.effectiveEngine(name, m)` ->
// `m.Engine` -> the re-add is accepted -> RED.
func TestAddVoiceMetaChecksInheritedEngine(t *testing.T) {
	d, dir, _ := voxFixture(t, nil)
	placeVoxVoice(t, d, "nar", config.TTSModelVoxCPM2, "", "", 2)
	placeVoxVoice(t, d, "plain", "", "", "", 2)
	old := voxRefLimit
	voxRefLimit = 1
	t.Cleanup(func() { voxRefLimit = old })
	clip := testutil.WriteSilentWAV(t, dir, "c.wav", 3)
	if _, _, err := d.AddVoice(context.Background(), "nar", clip, ""); err == nil || !strings.Contains(err.Error(), "shorter clip") {
		t.Fatalf("re-adding a voxcpm2 voice with a too-long clip = %v, want refusal", err)
	}
	if _, _, err := d.AddVoice(context.Background(), "plain", clip, ""); err != nil {
		t.Fatalf("a voice with no engine must not be checked: %v", err)
	}
}

// The per-request cap on voxcpm2 is 1000 characters (runes, not bytes), with a
// message that sends longer scripts to the long-form producer; the engine is
// never reached for a refused request.
// Mutation F-cap: voxcpm2.go buildVoxCPM2, `n > maxVoxChars` ->
// `n > maxVoxChars*100` -> the 1001-char request reaches the engine -> RED.
func TestVoxCPM2CapsInputAt1000Characters(t *testing.T) {
	d, _, logPath := voxFixture(t, nil)
	if rec := postSpeech(d, `{"model":"voxcpm2","input":"`+strings.Repeat("я", maxVoxChars)+`"}`); rec.Code != http.StatusOK {
		t.Fatalf("1000 characters = %d %s", rec.Code, bodyText(rec))
	}
	rec := postSpeech(d, `{"model":"voxcpm2","input":"`+strings.Repeat("я", maxVoxChars+1)+`"}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "long-form") {
		t.Fatalf("1001 characters = %d %s", rec.Code, bodyText(rec))
	}
	if n := len(voxLog(t, logPath)); n != 1 {
		t.Fatalf("engine requests = %d, want 1", n)
	}
}

// pcm and mp3 on the buffered path are encoded from the take, and the response
// says which engine rendered it.
func TestVoxCPM2BufferedFormats(t *testing.T) {
	d, _, _ := voxFixture(t, nil)
	rec := postSpeech(d, `{"model":"voxcpm2","input":"Привет.","response_format":"pcm"}`)
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "audio/pcm" || rec.Body.Len() < 40000 || rec.Body.Len()%2 != 0 {
		t.Fatalf("pcm: %d %v len=%d", rec.Code, rec.Header(), rec.Body.Len())
	}
	if rec = postSpeech(d, `{"model":"voxcpm2","input":"Привет.","response_format":"mp3"}`); rec.Code != http.StatusOK ||
		rec.Header().Get("Content-Type") != "audio/mpeg" || rec.Header().Get("X-Ox-Say-Model") != "voxcpm2" {
		t.Fatalf("mp3: %d %v", rec.Code, rec.Header())
	}
}

// #143 N3: an instruct that is empty only after cleaning (format characters)
// must fall back to the voice's default style, not mask it with "".
// Mutation: voxcpm2.go voxStyle, test `strings.TrimSpace(raw) == ""` before
// sanitising instead of `style == ""` after -> returns "" -> RED.
func TestVoxStyleCfOnlyInstructFallsBackToVoiceStyle(t *testing.T) {
	v := &voices.Voice{Name: "nar", Meta: voices.Meta{Style: "calm"}}
	for _, in := range []string{"\u200B", "\uFEFF\u202E", " \u200B "} {
		got, err := voxStyle(map[string]any{fieldInstruct: in}, v)
		if err != nil || got != "calm" {
			t.Errorf("instruct %q: style %q, err %v; want the voice default \"calm\"", in, got, err)
		}
	}
}
