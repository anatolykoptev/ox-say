package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/voiceclean"
)

func requireFFmpeg(t *testing.T) {
	t.Helper()
	for _, tool := range []string{"ffmpeg", "ffprobe"} {
		if _, err := exec.LookPath(tool); err != nil {
			if os.Getenv("CI") != "" {
				t.Fatalf("%s is required on CI: %v", tool, err)
			}
			t.Skipf("%s not on PATH", tool)
		}
	}
}

func setOS(t *testing.T, major int) {
	t.Helper()
	old := osMajor
	osMajor = func() (int, bool) { return major, true }
	t.Cleanup(func() { osMajor = old })
}

func setArch(t *testing.T, arch string) {
	t.Helper()
	old := goArch
	goArch = arch
	t.Cleanup(func() { goArch = old })
}

// stubEngine writes a shell script standing in for ox-clean. body runs after the `--version` and argument-shape
// checks; it can read $IN and $OUT. Every call's arguments are appended to the returned log.
func stubEngine(t *testing.T, body string) (bin, log string) {
	t.Helper()
	dir := t.TempDir()
	bin, log = filepath.Join(dir, "ox-clean"), filepath.Join(dir, "calls.log")
	script := `#!/bin/sh
if [ "$1" = "--version" ]; then echo "ox-clean 1 (model stub)"; exit 0; fi
IN=$1; OUT=$2
[ "$3" = "--models" ] || { echo "bad args: $*" >&2; exit 9; }
echo "$*" >> ` + log + `
` + body + "\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, log
}

func seedCleanModels(t *testing.T, cfg *config.Config) {
	t.Helper()
	dir := filepath.Join(cfg.CleanModelsDir(), "mossformer2-se-48k")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".ox-say-revision"), []byte(config.CleanModelsRevision+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// newCleanDaemon is a daemon on a macOS 26 arm64-unified Mac with the stub engine and models seeded.
func newCleanDaemon(t *testing.T, engineBody string) (*Daemon, http.Handler, string) {
	t.Helper()
	return newCleanDaemonOn(t, engineBody, true)
}

// newCleanDaemonOn is newCleanDaemon on a Mac with unified memory (arm64) or without (Intel: the TTS supervisor is
// wired to the GPU lease, with the fake engine child).
func newCleanDaemonOn(t *testing.T, engineBody string, unified bool) (*Daemon, http.Handler, string) {
	t.Helper()
	requireFFmpeg(t)
	setOS(t, 26)
	setArch(t, "arm64")
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemon(t, dir, nil)
	if unified {
		d.Cfg.GPUMemory = config.GPUMemoryUnified
	}
	bin, log := stubEngine(t, engineBody)
	d.Cfg.CleanBin = bin
	seedCleanModels(t, d.Cfg)
	if err := os.MkdirAll(filepath.Join(d.Cfg.Home, "meetings", "m1"), 0o700); err != nil {
		t.Fatal(err)
	}
	return d, servedFor(t, d), log
}

func makeWav(t *testing.T, path string, seconds int) {
	t.Helper()
	out, err := exec.Command("ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
		"sine=frequency=440:sample_rate=48000:duration="+strconv.Itoa(seconds), "-ac", "2", path).CombinedOutput()
	if err != nil {
		t.Fatalf("ffmpeg: %v %s", err, out)
	}
}

func cleanBody(in, out string) string {
	b, _ := json.Marshal(map[string]any{"in_path": in, "out_path": out})
	return string(b)
}

func postClean(h http.Handler, body string) *httptest.ResponseRecorder {
	return serve(h, appRequest("POST", "/v1/audio/clean", body))
}

func errCode(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var e struct {
		Error struct{ Code, Message string } `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &e); err != nil {
		t.Fatalf("not an error envelope: %s", rec.Body)
	}
	return e.Error.Code
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func shortQuiet(t *testing.T, cap time.Duration) {
	t.Helper()
	oc, op := cleanQuietCap, cleanQuietPoll
	cleanQuietCap, cleanQuietPoll = cap, 10*time.Millisecond
	t.Cleanup(func() { cleanQuietCap, cleanQuietPoll = oc, op })
}

// Readiness, in order: an old macOS, then a missing engine, then missing models. Intel is enabled (decision 8): an
// amd64 build has no cpu_unsupported. Mutation: clean.go cleanReady, delete the `major < cleanMinMacOS` branch (F5)
// -> RED at the first assertion.
func TestCleanReadinessReasonsInOrder(t *testing.T) {
	d := newTestDaemon(t, t.TempDir(), nil)
	setOS(t, 14)
	if code, reason := d.cleanReady(); code != "os_too_old" || reason == "" {
		t.Fatalf("macOS 14: %q %q", code, reason)
	}
	osMajor = func() (int, bool) { return 0, false }
	if code, _ := d.cleanReady(); code != "os_too_old" {
		t.Fatalf("a system that will not say its version must fail closed, got %q", code)
	}
	setOS(t, 26)
	setArch(t, "amd64")
	d.Cfg.CleanBin = filepath.Join(t.TempDir(), "absent")
	if code, _ := d.cleanReady(); code != "engine_missing" {
		t.Fatalf("Intel with no engine: got %q (Intel is enabled: never cpu_unsupported)", code)
	}
	d.Cfg.CleanBin, _ = stubEngine(t, "exit 0")
	if code, _ := d.cleanReady(); code != "models_missing" {
		t.Fatalf("got %q", code)
	}
	seedCleanModels(t, d.Cfg)
	if code, _ := d.cleanReady(); code != "" {
		t.Fatalf("got %q", code)
	}
}

func TestCleanRouteCleansAFileAndReportsIt(t *testing.T) {
	d, h, log := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	dir := t.TempDir()
	in, out := filepath.Join(dir, "in.wav"), filepath.Join(dir, "out.wav")
	makeWav(t, in, 2)
	rec := postClean(h, cleanBody(in, out))
	if rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	var res CleanResult
	if err := json.Unmarshal(rec.Body.Bytes(), &res); err != nil {
		t.Fatal(err)
	}
	if res.OutPath != out || res.Video || res.Channels != 2 || res.SampleRate != 48000 || res.Wet != cleanWet ||
		res.InputSeconds < 1.9 || res.InputSeconds > 2.1 || res.ElapsedSeconds <= 0 || res.Dropped == nil {
		t.Errorf("body %+v", res)
	}
	if !strings.Contains(rec.Body.String(), `"lag_ms"`) || !strings.Contains(rec.Body.String(), `"dropped":[]`) {
		t.Errorf("lag_ms and dropped must be in the body: %s", rec.Body)
	}
	if st, err := os.Stat(out); err != nil || st.Size() == 0 {
		t.Fatalf("no output: %v", err)
	}
	calls, _ := os.ReadFile(log)
	lines := strings.Split(strings.TrimSpace(string(calls)), "\n")
	if len(lines) != 1 || !strings.HasSuffix(lines[0], "--models "+d.Cfg.CleanModelsDir()) {
		t.Errorf("engine calls %q", lines)
	}
	var st struct {
		Busy struct{ Cleaning int } `json:"busy"`
	}
	rec = serve(h, httptest.NewRequest("GET", "http://127.0.0.1:8094/status", nil))
	_ = json.Unmarshal(rec.Body.Bytes(), &st)
	if st.Busy.Cleaning != 0 || d.cleanRunning.Load() != 0 {
		t.Errorf("busy.cleaning %d running %d after the run", st.Busy.Cleaning, d.cleanRunning.Load())
	}
}

// A present wet of 0 is honoured: the answer says 0, not the default.
// Mutation (F6): Wet in cleanRequest/CleanInput as a float64 where 0 means the default -> RED.
func TestWetZeroIsHonoured(t *testing.T) {
	_, h, _ := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	dir := t.TempDir()
	in := filepath.Join(dir, "in.wav")
	makeWav(t, in, 1)
	rec := postClean(h, `{"in_path":"`+in+`","out_path":"`+filepath.Join(dir, "o.wav")+`","wet":0}`)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"wet":0,`) {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
}

// The whole "never meetings" guarantee: a meeting file, an output into meetings, a symlink into meetings and a hard
// link to a meeting file are all 403, and the engine never runs.
// Mutation (F1): clean.go Clean, delete the `Forbidden:` line -> RED.
func TestCleanRefusesAnythingUnderTheMeetingsDirectory(t *testing.T) {
	d, h, log := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	dir := t.TempDir()
	m := filepath.Join(d.Cfg.Home, "meetings", "m1", "them.wav")
	makeWav(t, m, 1)
	plain := filepath.Join(dir, "plain.wav")
	makeWav(t, plain, 1)
	link := filepath.Join(dir, "link.wav")
	if err := os.Symlink(m, link); err != nil {
		t.Fatal(err)
	}
	hard := filepath.Join(dir, "hard.wav")
	if err := os.Link(m, hard); err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		"a meeting file":     cleanBody(m, filepath.Join(dir, "o1.wav")),
		"output in meetings": cleanBody(plain, filepath.Join(d.Cfg.Home, "meetings", "m1", "x.wav")),
		"symlink to meeting": cleanBody(link, filepath.Join(dir, "o3.wav")),
		"hard link":          cleanBody(hard, filepath.Join(dir, "o4.wav")),
	}
	for name, body := range cases {
		rec := postClean(h, body)
		if rec.Code != 403 || errCode(t, rec) != "forbidden_path" {
			t.Errorf("%s: %d %s", name, rec.Code, rec.Body)
		}
	}
	if _, err := os.Stat(log); err == nil {
		t.Error("the engine ran for a forbidden path")
	}
	if _, err := os.Stat(filepath.Join(d.Cfg.Home, "meetings", "m1", "x.wav")); err == nil {
		t.Error("an output was written into meetings")
	}
}

func TestCleanIsRefusedAcrossSitesAndWithoutJSON(t *testing.T) {
	_, h, log := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	dir := t.TempDir()
	in := filepath.Join(dir, "in.wav")
	makeWav(t, in, 1)
	body := cleanBody(in, filepath.Join(dir, "o.wav"))

	req := appRequest("POST", "/v1/audio/clean", body)
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	if rec := serve(h, req); rec.Code != 403 {
		t.Errorf("cross-site: %d", rec.Code)
	}
	req = appRequest("POST", "/v1/audio/clean", body)
	req.Header.Set("Content-Type", "text/plain")
	if rec := serve(h, req); rec.Code != 415 {
		t.Errorf("text/plain: %d", rec.Code)
	}
	req = appRequest("POST", "/v1/audio/clean", body)
	req.Host = "evil.example"
	if rec := serve(h, req); rec.Code != 403 {
		t.Errorf("bad host: %d", rec.Code)
	}
	if _, err := os.Stat(log); err == nil {
		t.Error("the engine ran for a refused request")
	}
}

// Mutation (F3): http.go registers the route through the interactive wrapper -> not testable by name alone, so the
// check is on the list the producer yields to.
func TestCleanIsNotAnInteractiveRoute(t *testing.T) {
	for _, p := range interactiveRoutes {
		if strings.Contains(p, "/v1/audio/clean") {
			t.Fatalf("%q is in interactiveRoutes: the producer would yield to a file tool", p)
		}
	}
}

// Mutation (F4): clean.go Clean, delete the `d.cleaning.CompareAndSwap` guard -> RED (both requests run).
func TestASecondCleanWhileOneRunsIs409(t *testing.T) {
	d, h, _ := newCleanDaemon(t, `sleep 1; cp "$IN" "$OUT"`)
	dir := t.TempDir()
	in := filepath.Join(dir, "in.wav")
	makeWav(t, in, 1)
	first := make(chan *httptest.ResponseRecorder, 1)
	go func() { first <- postClean(h, cleanBody(in, filepath.Join(dir, "a.wav"))) }()
	waitFor(t, "the first cleanup to start", func() bool { return d.cleanRunning.Load() == 1 })
	rec := postClean(h, cleanBody(in, filepath.Join(dir, "b.wav")))
	if rec.Code != 409 || errCode(t, rec) != "busy" {
		t.Errorf("second: %d %s", rec.Code, rec.Body)
	}
	if rec := <-first; rec.Code != 200 {
		t.Errorf("first: %d %s", rec.Code, rec.Body)
	}
}

func TestCleanTimeoutFromTheSpeedFloors(t *testing.T) {
	setArch(t, "arm64")
	if got := cleanTimeout(10 * 60); got != cleanMinTimeout {
		t.Errorf("arm64, 10 min: %v", got)
	}
	// arm64 floor 50 -> 25x allowed: 4 h of audio is 576 s
	if got := cleanTimeout(4 * 3600); got != 576*time.Second {
		t.Errorf("arm64, 4 h: %v", got)
	}
	setArch(t, "amd64") // cpuOnly floor 2 -> 1x allowed
	if got := cleanTimeout(4 * 3600); got != 4*time.Hour {
		t.Errorf("amd64, 4 h: %v", got)
	}
	if got := cleanTimeout(60); got != cleanMinTimeout {
		t.Errorf("amd64, 1 min: %v", got)
	}
}

func readSwift(t *testing.T, rel string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "engine", "clean", "Sources", "OxCleanCore", rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// Mutation (F2): cleanMinMacOS = 14 -> RED.
func TestCleanMinMacOSMatchesTheHelper(t *testing.T) {
	m := regexp.MustCompile(`minimumMajor\s*=\s*(\d+)`).FindStringSubmatch(readSwift(t, "Platform.swift"))
	if m == nil {
		t.Fatal("minimumMajor not found in Platform.swift")
	}
	if n, _ := strconv.Atoi(m[1]); n != cleanMinMacOS {
		t.Fatalf("helper %d, daemon %d", n, cleanMinMacOS)
	}
}

func TestCleanSpeedFloorsMatchTheHelper(t *testing.T) {
	src := readSwift(t, "ComputePlan.swift")
	for name, want := range map[string]float64{"appleGPU": cleanFloorAppleGPU, "intelDiscreteGPU": cleanFloorIntelDGPU, "intelCPUOnly": cleanFloorIntelCPUOnly} {
		m := regexp.MustCompile(`static let ` + name + `: Double = (\d+(?:\.\d+)?)`).FindStringSubmatch(src)
		if m == nil {
			t.Fatalf("%s not found in ComputePlan.swift", name)
		}
		if got, _ := strconv.ParseFloat(m[1], 64); got != want {
			t.Errorf("%s: helper %v, daemon %v", name, got, want)
		}
	}
}

func TestStatusReportsVoiceCleanAndTheModelsRowAgrees(t *testing.T) {
	d, h, _ := newCleanDaemon(t, "exit 0")
	check := func(wantCode string, available bool) {
		t.Helper()
		var st struct {
			VoiceClean cleanStatus `json:"voice_clean"`
		}
		rec := serve(h, httptest.NewRequest("GET", "http://127.0.0.1:8094/status", nil))
		if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil {
			t.Fatal(err)
		}
		if st.VoiceClean.Available != available || st.VoiceClean.ReasonCode != wantCode || st.VoiceClean.ModelRevision != config.CleanModelsRevision {
			t.Fatalf("status %+v", st.VoiceClean)
		}
		if available && st.VoiceClean.EngineVersion != "ox-clean 1 (model stub)" {
			t.Errorf("engine_version %q", st.VoiceClean.EngineVersion)
		}
		var models struct{ Models []modelEntry }
		rec = serve(h, httptest.NewRequest("GET", "http://127.0.0.1:8094/v1/models", nil))
		_ = json.Unmarshal(rec.Body.Bytes(), &models)
		var row *modelEntry
		for i := range models.Models {
			if models.Models[i].ID == "voice_cleanup" {
				row = &models.Models[i]
			}
		}
		if row == nil || row.ReasonCode != wantCode || row.Installed != available || row.Kind != "cleanup" || row.Optional ||
			row.Bytes != config.CleanModelsBytes {
			t.Fatalf("models row %+v", row)
		}
	}
	check("", true)
	if err := os.Remove(filepath.Join(d.Cfg.CleanModelsDir(), "mossformer2-se-48k", ".ox-say-revision")); err != nil {
		t.Fatal(err)
	}
	check("models_missing", false)
	setOS(t, 14)
	check("os_too_old", false)
}

// ---- engine failures ----------------------------------------------------------------------------------------------

func TestEngineFailureMapsExitCodesAndReasons(t *testing.T) {
	cases := []struct {
		exit   int
		tail   string
		status int
		code   string
		reason string
		inMsg  string
	}{
		{3, "ox-clean: the model answered wrongly [reason=known_answer]\n", 502, "model_wrong_answer", "known_answer", "wrong answer on this Mac, so nothing was cleaned"},
		{3, "ox-clean: no models [reason=missing]", 503, "models_unusable", "missing", "model files"},
		{4, "x [reason=empty]", 502, "engine_input", "empty", "could not read"},
		{5, "x [reason=os_too_old]", 503, "os_too_old", "os_too_old", "macOS 15"},
		{6, "x [reason=out_exists]", 502, "engine_output", "out_exists", "disk space"},
		{1, "x [reason=write_failed]", 502, "engine_failed", "write_failed", "Your file was not changed"},
		{2, "x [reason=usage]", 502, "engine_usage", "usage", "bug"},
		{130, "", 503, "engine_interrupted", "", "stopped"},
		{-1, "", 503, "engine_interrupted", "", "stopped"},
		{1, "no token at all", 502, "engine_failed", "", "Your file was not changed"},
	}
	for _, c := range cases {
		e := engineFailure(c.exit, c.tail)
		if e.Status != c.status || e.Code != c.code || e.Reason != c.reason || !strings.Contains(e.Msg, c.inMsg) {
			t.Errorf("exit %d %q -> %+v", c.exit, c.tail, e)
		}
	}
}

// Through the route: the exit code and the stderr token reach the answer; stdout (Core ML noise on Intel) is ignored.
func TestCleanRouteMapsAKnownAnswerFailure(t *testing.T) {
	_, h, _ := newCleanDaemon(t, `echo "MPSGraph noise [reason=bogus]"; echo "ox-clean: wrong answer [reason=known_answer]" >&2; exit 3`)
	dir := t.TempDir()
	in, out := filepath.Join(dir, "in.wav"), filepath.Join(dir, "o.wav")
	makeWav(t, in, 1)
	rec := postClean(h, cleanBody(in, out))
	var e struct {
		Error struct{ Code, Reason, Message string }
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &e)
	if rec.Code != 502 || e.Error.Code != "model_wrong_answer" || e.Error.Reason != "known_answer" ||
		!strings.Contains(e.Error.Message, "wrong answer on this Mac") {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	if _, err := os.Stat(out); err == nil {
		t.Error("an output exists after a failed run")
	}
}

// Every voiceclean code has its status, and the fixed sentences replace the ones that carry a tool's output.
func TestEveryVoicecleanCodeMapsToItsStatus(t *testing.T) {
	d := newTestDaemon(t, t.TempDir(), nil)
	want := map[string]int{
		voiceclean.CodeInvalidRequest: 400, voiceclean.CodeNotFound: 404, voiceclean.CodeExists: 409,
		voiceclean.CodeSameFile: 409, voiceclean.CodeForbiddenPath: 403, voiceclean.CodeNoAudio: 422,
		voiceclean.CodeUnsupportedChannels: 422, voiceclean.CodeUnsupportedStreams: 422, voiceclean.CodeTooLong: 422,
		voiceclean.CodeDiskSpace: 507, voiceclean.CodeEngineFailed: 502, voiceclean.CodeLagUnverified: 502,
		voiceclean.CodeUnavailable: 503,
	}
	for code, status := range want {
		ve := &voiceclean.Error{Code: code, Msg: "ffmpeg failed: SECRET-TOOL-OUTPUT", Status: status}
		got := d.mapCleanError(t.Context(), ve, &engineOutcome{}).(*CleanError)
		if got.Status != status || got.Code != code {
			t.Errorf("%s: %+v", code, got)
		}
		if (code == voiceclean.CodeEngineFailed || code == voiceclean.CodeLagUnverified) && strings.Contains(got.Msg, "SECRET") {
			t.Errorf("%s: the sentence carries a tool's output: %q", code, got.Msg)
		}
	}
}

// ---- yielding to the rest of the daemon --------------------------------------------------------------------------

// A cleanup waits while dictation, speech or a job is in flight and starts the moment it ends.
// Mutation (F7): clean.go cleanGate.enter, delete the `waitCleanQuiet` call -> RED (the engine runs at once).
func TestCleanWaitsForQuietAndStartsWhenItDrops(t *testing.T) {
	d, h, log := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	shortQuiet(t, 30*time.Second)
	dir := t.TempDir()
	in := filepath.Join(dir, "in.wav")
	makeWav(t, in, 1)
	d.transcribing.Add(1) // a dictation-like job holds the GPU
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- postClean(h, cleanBody(in, filepath.Join(dir, "o.wav"))) }()
	time.Sleep(300 * time.Millisecond)
	if _, err := os.Stat(log); err == nil {
		t.Fatal("the cleanup ran while a transcription was in flight")
	}
	if d.busy().Cleaning != 1 {
		t.Errorf("busy.cleaning = %d while waiting", d.busy().Cleaning)
	}
	d.transcribing.Add(-1)
	select {
	case rec := <-done:
		if rec.Code != 200 {
			t.Fatalf("%d %s", rec.Code, rec.Body)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the cleanup never started after the daemon went quiet")
	}
}

func TestCleanAnswers503BusyAfterTheCap(t *testing.T) {
	d, h, log := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	shortQuiet(t, 200*time.Millisecond)
	dir := t.TempDir()
	in, out := filepath.Join(dir, "in.wav"), filepath.Join(dir, "o.wav")
	makeWav(t, in, 1)
	d.speaking.Add(1)
	defer d.speaking.Add(-1)
	rec := postClean(h, cleanBody(in, out))
	if rec.Code != 503 || errCode(t, rec) != "busy" || !strings.Contains(rec.Body.String(), "busy with dictation or another job") {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	if _, err := os.Stat(log); err == nil {
		t.Error("the engine ran")
	}
	if d.cleaning.Load() != 0 || d.cleanRunning.Load() != 0 {
		t.Error("counters left set")
	}
}

// On unified memory (arm64) a cleanup holds no lease and no lock the interactive path takes: while one runs,
// beginInteractive and /status return at once, and a transcription that starts after the cleanup passed its wait does
// not stop it (they share the GPU briefly, by design). This does not cover Intel, where speech takes turns with the
// cleanup (TestSpeechStartDuringACleanupGetsAClearError).
func TestDictationIsNotBlockedByACleanup(t *testing.T) {
	d, h, _ := newCleanDaemon(t, `sleep 1; cp "$IN" "$OUT"`)
	dir := t.TempDir()
	in := filepath.Join(dir, "in.wav")
	makeWav(t, in, 1)
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- postClean(h, cleanBody(in, filepath.Join(dir, "o.wav"))) }()
	waitFor(t, "the cleanup to run", func() bool { return d.cleanRunning.Load() == 1 })
	t0 := time.Now()
	end := d.beginInteractive() // what every interactive route does first
	d.transcribing.Add(1)
	if time.Since(t0) > 200*time.Millisecond {
		t.Error("starting interactive work waited")
	}
	rec := serve(h, httptest.NewRequest("GET", "http://127.0.0.1:8094/status", nil))
	if rec.Code != 200 || time.Since(t0) > 500*time.Millisecond {
		t.Errorf("/status during a cleanup: %d after %v", rec.Code, time.Since(t0))
	}
	d.transcribing.Add(-1)
	end()
	if rec := <-done; rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
}

// A voiceover render does not start while a cleanup runs.
// Mutation: interactive.go waitQuiet, delete `&& d.cleanRunning.Load() == 0` -> RED.
func TestWaitQuietWaitsForARunningCleanup(t *testing.T) {
	d := newTestDaemon(t, t.TempDir(), nil)
	oq, op := interactiveQuiet, quietPoll
	interactiveQuiet, quietPoll = 0, 10*time.Millisecond
	t.Cleanup(func() { interactiveQuiet, quietPoll = oq, op })
	d.cleanRunning.Add(1)
	var returned atomic.Bool
	go func() { _ = d.waitQuiet(t.Context(), func() {}); returned.Store(true) }()
	time.Sleep(200 * time.Millisecond)
	if returned.Load() {
		t.Fatal("waitQuiet returned during a cleanup")
	}
	d.cleanRunning.Add(-1)
	waitFor(t, "waitQuiet to return", returned.Load)
}

// On a Mac that arbitrates its GPU (not unified memory) the cleanup holds the lease for its run, tagged "clean"; on
// unified memory it takes nothing.
func TestCleanTakesTheGPULeaseWhereItIsArbitrated(t *testing.T) {
	for _, unified := range []bool{false, true} {
		d, h, _ := newCleanDaemonOn(t, `sleep 1; cp "$IN" "$OUT"`, unified)
		dir := t.TempDir()
		in := filepath.Join(dir, "in.wav")
		makeWav(t, in, 1)
		done := make(chan *httptest.ResponseRecorder, 1)
		go func() { done <- postClean(h, cleanBody(in, filepath.Join(dir, "o.wav"))) }()
		waitFor(t, "the cleanup to run", func() bool { return d.cleanRunning.Load() == 1 })
		if held, owner := d.gpu.Held(), d.gpu.Owner(); held != !unified || (held && owner != "clean") {
			t.Errorf("unified=%v: lease held=%v owner=%q", unified, held, owner)
		}
		if rec := <-done; rec.Code != 200 {
			t.Fatalf("%d %s", rec.Code, rec.Body)
		}
		if d.gpu.Held() {
			t.Error("the lease was not released")
		}
	}
}

// A lease held by the TTS engine makes the cleanup wait, then answer 503 busy; nothing is left held.
func TestCleanGivesUpWhenTheGPULeaseStaysTaken(t *testing.T) {
	d, h, log := newCleanDaemonOn(t, `cp "$IN" "$OUT"`, false)
	shortQuiet(t, 200*time.Millisecond)
	if !d.gpu.TryAs("tts") {
		t.Fatal("lease")
	}
	defer d.gpu.Release()
	dir := t.TempDir()
	in := filepath.Join(dir, "in.wav")
	makeWav(t, in, 1)
	rec := postClean(h, cleanBody(in, filepath.Join(dir, "o.wav")))
	if rec.Code != 503 || errCode(t, rec) != "gpu_busy" || !strings.Contains(rec.Body.String(), "The graphics card is busy with speech; try again in a moment.") ||
		strings.Contains(rec.Body.String(), "dictation") {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	if _, err := os.Stat(log); err == nil {
		t.Error("the engine ran without the lease")
	}
	if d.cleanRunning.Load() != 0 || d.gpu.Owner() != "tts" {
		t.Error("state left behind")
	}
}

// ---- the lazy model download ---------------------------------------------------------------------------------------

func installScript(t *testing.T, d *Daemon) {
	t.Helper()
	if err := os.MkdirAll(d.Cfg.Home, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d.Cfg.Home, fetchModelsScript), []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

// Two concurrent requests, then three more in turn, start exactly one fetch, and every answer says so.
// Mutation (F8): clean_install.go startCleanInstall, delete the `if c.running` early return -> RED.
func TestMissingModelsStartExactlyOneFetch(t *testing.T) {
	d, h, _ := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	if err := os.Remove(filepath.Join(d.Cfg.CleanModelsDir(), "mossformer2-se-48k", ".ox-say-revision")); err != nil {
		t.Fatal(err)
	}
	installScript(t, d)
	release := filepath.Join(t.TempDir(), "release")
	var starts atomic.Int32
	old := cleanFetchStart
	cleanFetchStart = func(ctx_ context.Context, script, dest string, tail *bytes.Buffer) (*exec.Cmd, error) {
		starts.Add(1)
		if script != filepath.Join(d.Cfg.Home, fetchModelsScript) || dest != filepath.Join(d.Cfg.Home, "models") {
			t.Errorf("fetch %s %s", script, dest)
		}
		cmd := exec.CommandContext(ctx_, "/bin/sh", "-c", `while [ ! -e "$1" ]; do sleep 0.02; done`, "sh", release)
		return cmd, cmd.Start()
	}
	t.Cleanup(func() { cleanFetchStart = old })

	dir := t.TempDir()
	in := filepath.Join(dir, "in.wav")
	makeWav(t, in, 1)
	body := cleanBody(in, filepath.Join(dir, "o.wav"))
	var wg sync.WaitGroup
	codes := make(chan string, 8)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rec := postClean(h, body)
			codes <- strconv.Itoa(rec.Code) + " " + errCode(t, rec)
		}()
	}
	wg.Wait()
	for range 3 {
		rec := postClean(h, body)
		if rec.Code != 503 || errCode(t, rec) != "models_downloading" {
			t.Errorf("later request: %d %s", rec.Code, rec.Body)
		}
	}
	close(codes)
	for c := range codes {
		if c != "503 models_downloading" && c != "409 busy" {
			t.Errorf("concurrent request answered %q", c)
		}
	}
	if n := starts.Load(); n != 1 {
		t.Fatalf("%d fetches started, want 1", n)
	}
	if d.cleanInstalling() != 1 || !d.cleanStatus().Installing {
		t.Error("status does not show the download")
	}
	var models struct{ Models []modelEntry }
	_ = json.Unmarshal(serve(h, httptest.NewRequest("GET", "http://127.0.0.1:8094/v1/models", nil)).Body.Bytes(), &models)
	for _, m := range models.Models {
		if m.ID == "voice_cleanup" && !m.Installing {
			t.Error("the models row does not show the download")
		}
	}
	if f, err := os.Create(release); err == nil {
		_ = f.Close()
	}
	waitFor(t, "the fetch to end", func() bool { return d.cleanInstalling() == 0 })
}

func TestMissingModelsWithoutTheFetchScriptSaysSo(t *testing.T) {
	d, h, _ := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	_ = os.Remove(filepath.Join(d.Cfg.CleanModelsDir(), "mossformer2-se-48k", ".ox-say-revision"))
	dir := t.TempDir()
	in := filepath.Join(dir, "in.wav")
	makeWav(t, in, 1)
	rec := postClean(h, cleanBody(in, filepath.Join(dir, "o.wav")))
	if rec.Code != 503 || errCode(t, rec) != "models_missing" || !strings.Contains(rec.Body.String(), "Reinstall") {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
}

// ---- Intel: one GPU job at a time ----------------------------------------------------------------------------------

// An idle TTS child holds the lease for its whole life; a cleanup stops it through the supervisor and starts at once
// instead of being refused for the idle-stop window.
// Mutation: clean.go cleanGate.enter, delete the `stopIdleTTS` call -> RED (503 gpu_busy after the wait).
func TestCleanStopsAnIdleTTSChildToTakeTheGPU(t *testing.T) {
	d, h, log := newCleanDaemonOn(t, `cp "$IN" "$OUT"`, false)
	shortQuiet(t, 400*time.Millisecond)
	if _, err := d.Sup.EnsureReady(t.Context()); err != nil {
		t.Fatal(err)
	}
	pid := d.Sup.Status().PID
	if pid <= 0 || d.gpu.Owner() != "tts" {
		t.Fatalf("pid %d, lease owner %q", pid, d.gpu.Owner())
	}
	dir := t.TempDir()
	in := filepath.Join(dir, "in.wav")
	makeWav(t, in, 1)
	rec := postClean(h, cleanBody(in, filepath.Join(dir, "o.wav")))
	if rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	if calls, _ := os.ReadFile(log); len(calls) == 0 {
		t.Error("the engine did not run")
	}
	waitFor(t, "the TTS child to be gone", func() bool { return !alive(pid) })
}

// A speech request that needs the TTS child while a cleanup holds the card gives up with a clear, stable error, not
// the generic engine-start failure. A card held by something else keeps the generic one.
// Mutation: speak.go speechOn, drop the LeaseWaitError branch -> RED; engine supervisor, return err instead of
// &LeaseWaitError -> RED.
func TestSpeechStartDuringACleanupGetsAClearError(t *testing.T) {
	d, _, _ := newCleanDaemonOn(t, "exit 0", false)
	if !d.gpu.TryAs("clean") {
		t.Fatal("lease")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 300*time.Millisecond)
	defer cancel()
	_, err := d.speechOn(ctx, d.Sup, map[string]any{"input": "hello"})
	var sbe *speechBlockedError
	if !errors.As(err, &sbe) || err.Error() != "Voice cleanup is using the graphics card; speech will be available when it finishes." {
		t.Fatalf("got %v", err)
	}
	if synthStatus(err) != 503 {
		t.Errorf("status %d", synthStatus(err))
	}
	rec := httptest.NewRecorder()
	writeSynthErr(rec, err)
	var body struct {
		Error struct{ Code, Message, Type string }
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if rec.Code != 503 || body.Error.Code != "gpu_busy_cleanup" || body.Error.Message != err.Error() {
		t.Errorf("%d %s", rec.Code, rec.Body)
	}
	d.gpu.Release()

	if !d.gpu.TryAs("transcription") {
		t.Fatal("lease")
	}
	defer d.gpu.Release()
	ctx2, cancel2 := context.WithTimeout(t.Context(), 300*time.Millisecond)
	defer cancel2()
	_, err = d.speechOn(ctx2, d.Sup, map[string]any{"input": "hello"})
	if err == nil || errors.As(err, &sbe) {
		t.Errorf("a card held by a transcription must not read as a cleanup: %v", err)
	}
}

// ---- review round: errors, bodies, backoff ------------------------------------------------------------------------

// The daemon's own outer time cap is a 504 with a log line; a client that left gets nothing written.
// Mutation: clean.go Clean, delete the `cleanOuterCap` DeadlineExceeded branch -> RED (500).
func TestOuterCapIs504AndAClientThatLeftGetsNoAnswer(t *testing.T) {
	_, h, _ := newCleanDaemon(t, `sleep 5; cp "$IN" "$OUT"`)
	dir := t.TempDir()
	in := filepath.Join(dir, "in.wav")
	makeWav(t, in, 1)
	old := cleanOuterCap
	cleanOuterCap = 600 * time.Millisecond
	t.Cleanup(func() { cleanOuterCap = old })
	rec := postClean(h, cleanBody(in, filepath.Join(dir, "o.wav")))
	if rec.Code != 504 || errCode(t, rec) != "engine_timeout" {
		t.Fatalf("outer cap: %d %s", rec.Code, rec.Body)
	}
	cleanOuterCap = old

	ctx, cancel := context.WithCancel(t.Context())
	req := appRequest("POST", "/v1/audio/clean", cleanBody(in, filepath.Join(dir, "o2.wav"))).WithContext(ctx)
	time.AfterFunc(700*time.Millisecond, cancel)
	rec = serve(h, req)
	if rec.Body.Len() != 0 {
		t.Errorf("an answer was written to a client that left: %d %s", rec.Code, rec.Body)
	}
}

// No ffprobe text reaches the JSON.
func TestFFprobeTextNeverReachesTheResponse(t *testing.T) {
	_, h, _ := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	dir := t.TempDir()
	bad := filepath.Join(dir, "bad.wav")
	if err := os.WriteFile(bad, []byte("not audio SECRETWORDS"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := postClean(h, cleanBody(bad, filepath.Join(dir, "o.wav")))
	body := rec.Body.String()
	if rec.Code != 400 || errCode(t, rec) != "invalid_request" || !strings.Contains(body, "This file is not audio or video OxSay can read.") {
		t.Fatalf("%d %s", rec.Code, body)
	}
	for _, leak := range []string{"ffprobe", "Invalid data", "SECRETWORDS", "moov"} {
		if strings.Contains(body, leak) {
			t.Errorf("response leaks %q: %s", leak, body)
		}
	}
}

func TestCleanBodyIsStrict(t *testing.T) {
	_, h, log := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	dir := t.TempDir()
	in := filepath.Join(dir, "in.wav")
	makeWav(t, in, 1)
	ok := cleanBody(in, filepath.Join(dir, "o.wav"))
	for name, body := range map[string]string{
		"unknown field": `{"in_path":"` + in + `","out_path":"` + filepath.Join(dir, "o.wav") + `","wett":0.1}`,
		"trailing data": ok + ` {"x":1}`,
		"trailing junk": ok + ` junk`,
		"not json":      `in_path`,
	} {
		if rec := postClean(h, body); rec.Code != 400 {
			t.Errorf("%s: %d %s", name, rec.Code, rec.Body)
		}
	}
	if _, err := os.Stat(log); err == nil {
		t.Error("the engine ran for a malformed body")
	}
	if rec := postClean(h, ok+"\n  \n"); rec.Code != 200 {
		t.Errorf("trailing whitespace: %d %s", rec.Code, rec.Body)
	}
}

// A broken engine is not run again on every /status.
// Mutation: clean.go cleanVersion, delete the failedAt check -> RED (a call per status).
func TestFailedVersionProbeIsRememberedForAWhile(t *testing.T) {
	d := newTestDaemon(t, t.TempDir(), nil)
	log := filepath.Join(t.TempDir(), "v.log")
	bin := filepath.Join(t.TempDir(), "ox-clean")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\necho x >> "+log+"\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	d.Cfg.CleanBin = bin
	calls := func() int { b, _ := os.ReadFile(log); return strings.Count(string(b), "x") }
	d.cleanVersion()
	d.cleanVersion()
	d.cleanVersion()
	if calls() != 1 {
		t.Fatalf("%d runs for three calls", calls())
	}
	old := cleanVersionFailTTL
	cleanVersionFailTTL = 10 * time.Millisecond
	t.Cleanup(func() { cleanVersionFailTTL = old })
	time.Sleep(30 * time.Millisecond)
	d.cleanVersion()
	if calls() != 2 {
		t.Errorf("after the TTL: %d runs", calls())
	}
}

// After a failed download the next request does not start another within the backoff, and the 503 says why.
// Mutation: clean_install.go startCleanInstall, delete the failedAt check -> RED (a second start).
func TestFailedFetchBacksOff(t *testing.T) {
	d, h, _ := newCleanDaemon(t, `cp "$IN" "$OUT"`)
	_ = os.Remove(filepath.Join(d.Cfg.CleanModelsDir(), "mossformer2-se-48k", ".ox-say-revision"))
	installScript(t, d)
	var starts atomic.Int32
	old := cleanFetchStart
	cleanFetchStart = func(ctx context.Context, script, dest string, tail *bytes.Buffer) (*exec.Cmd, error) {
		starts.Add(1)
		tail.WriteString("curl: (22) The requested URL returned error: 404\n")
		cmd := exec.CommandContext(ctx, "/bin/sh", "-c", "exit 22")
		return cmd, cmd.Start()
	}
	t.Cleanup(func() { cleanFetchStart = old })
	dir := t.TempDir()
	in := filepath.Join(dir, "in.wav")
	makeWav(t, in, 1)
	body := cleanBody(in, filepath.Join(dir, "o.wav"))
	if rec := postClean(h, body); errCode(t, rec) != "models_downloading" {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	waitFor(t, "the fetch to fail", func() bool { r, e, _ := d.cleanInst.state(); return !r && e != "" })
	rec := postClean(h, body)
	if rec.Code != 503 || errCode(t, rec) != "models_download_failed" || !strings.Contains(rec.Body.String(), "The download failed") {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	if starts.Load() != 1 {
		t.Errorf("%d fetches", starts.Load())
	}
	old2 := cleanFetchBackoff
	cleanFetchBackoff = time.Millisecond
	t.Cleanup(func() { cleanFetchBackoff = old2 })
	time.Sleep(10 * time.Millisecond)
	postClean(h, body)
	if starts.Load() != 2 {
		t.Errorf("after the backoff: %d fetches", starts.Load())
	}
}

// produce's wait log names the cleanup, not dictation.
func TestWaitQuietLogNamesTheCleanup(t *testing.T) {
	d := newTestDaemon(t, t.TempDir(), nil)
	oq, op, om := interactiveQuiet, quietPoll, maxYield
	interactiveQuiet, quietPoll, maxYield = 0, 10*time.Millisecond, 100*time.Millisecond
	t.Cleanup(func() { interactiveQuiet, quietPoll, maxYield = oq, op, om })
	var buf bytes.Buffer
	d.log = slog.New(slog.NewTextHandler(&buf, nil))
	d.cleanRunning.Add(1)
	_ = d.waitQuiet(t.Context(), func() {})
	d.cleanRunning.Add(-1)
	if !strings.Contains(buf.String(), "reason=voice_cleanup") || strings.Contains(buf.String(), "reason=dictation") {
		t.Errorf("log: %s", buf.String())
	}
}
