package daemon

import (
	"bytes"
	"context"
	"encoding/binary"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/anatolykoptev/ox-say/internal/stt"
)

// meetingFixture is a daemon whose recognizer and notes model are fakes.
func meetingFixture(t *testing.T, edit func(*config.Config)) (*Daemon, *http.ServeMux) {
	t.Helper()
	d := newTestDaemonSTT(t, t.TempDir(), edit, nil, nil)
	d.Meet.Transcribe = func(context.Context, string) (*stt.Result, error) {
		text := "thanks everyone for joining today we will go through the plan and the open questions now and then agree who sends what by when so that nobody leaves with doubts about the next steps"
		var w []stt.Word
		for i, tok := range strings.Fields(text) {
			w = append(w, stt.Word{W: tok, S: 1 + float64(i)*0.4, E: 1.3 + float64(i)*0.4})
		}
		return &stt.Result{Words: w}, nil
	}
	d.Meet.Chat = cannedChat{`{"summary":"A planning call.","decisions":["Ship Friday"],"action_items":[{"who":"Me","what":"send the plan","when":"Friday"}],"open_questions":[],"numbers":[]}`}
	d.Meet.NotesReady = func() string { return "" }
	mux := http.NewServeMux()
	d.Routes(mux)
	return d, mux
}

type cannedChat struct{ reply string }

func (c cannedChat) Complete(context.Context, meeting.Request) (string, error) { return c.reply, nil }

func call(t *testing.T, mux http.Handler, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func writeTone(t *testing.T, path string, seconds int) {
	t.Helper()
	var buf bytes.Buffer
	s := make([]int16, seconds*meeting.SampleRate)
	for i := range s {
		s[i] = 5000
	}
	_ = binary.Write(&buf, binary.LittleEndian, s)
	if err := os.WriteFile(path, buf.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
}

// /status counts a queued meeting as busy: the app's version handshake must
// not restart the daemon under it.
// Mutation: internal/daemon/service.go busy, delete the `Meetings:` line ->
// RED (a restart would interrupt a transcription and look idle).
func TestStatusCountsMeetingsAsBusy(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	if !d.Status().Idle {
		t.Fatal("an empty daemon is idle")
	}
	m, _, _ := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	_, _ = d.Meet.Finish(m.ID, time.Now())
	st := d.Status()
	if st.Idle || st.Busy.Meetings != 1 {
		t.Fatalf("status = idle %v, busy %+v; want a busy meeting", st.Idle, st.Busy)
	}
}

func TestStatusReportsWhyNotesCannotRun(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	n := d.Status().Notes
	if n.Available || n.ReasonCode != config.NotesReasonEngineMissing {
		t.Fatalf("notes = %+v, want engine_missing for a daemon with no ox-llm", n)
	}
}

// The model download runs the installed fetch-models.sh --notes-only, reports
// progress from the .part file, and ends with the model in place.
// Mutation: internal/daemon/meetings.go InstallNotesModel, change
// `if d.notes.running {` to `if false {` -> RED (two downloads write one
// .part file).
func TestInstallNotesModelRunsTheFetchScript(t *testing.T) {
	var model string
	d, _ := meetingFixture(t, func(c *config.Config) {
		bin := filepath.Join(filepath.Dir(c.Home), "ox-llm")
		_ = os.MkdirAll(filepath.Dir(bin), 0o755)
		_ = os.WriteFile(bin, []byte("x"), 0o755)
		c.NotesBin = bin
		c.NotesModel = filepath.Join(c.Home, "models", config.NotesModelFile)
		model = c.NotesModel
	})
	script := filepath.Join(d.Cfg.Home, fetchModelsScript)
	_ = os.MkdirAll(d.Cfg.Home, 0o755)
	body := "#!/bin/sh\n[ \"$1\" = --notes-only ] || exit 9\nsleep 0.3\necho model > \"$2/" + config.NotesModelFile + "\"\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	if n := d.Status().Notes; n.ReasonCode != config.NotesReasonModelMissing {
		t.Fatalf("before: %+v", n)
	}
	if err := d.InstallNotesModel(); err != nil {
		t.Fatal(err)
	}
	if err := d.InstallNotesModel(); err == nil {
		t.Fatal("a second download must be refused while one runs")
	}
	if d.Status().Idle {
		t.Fatal("a running download is busy work")
	}
	deadline := time.Now().Add(5 * time.Second)
	for d.notesInstalling() == 1 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := os.Stat(model); err != nil {
		t.Fatalf("the script did not leave the model: %v", err)
	}
	if n := d.Status().Notes; !n.Available || n.InstallErr != "" {
		t.Fatalf("after: %+v", n)
	}
}

func TestInstallNotesModelReportsAFailure(t *testing.T) {
	d, _ := meetingFixture(t, func(c *config.Config) {
		bin := filepath.Join(filepath.Dir(c.Home), "ox-llm")
		_ = os.MkdirAll(filepath.Dir(bin), 0o755)
		_ = os.WriteFile(bin, []byte("x"), 0o755)
		c.NotesBin = bin
		c.NotesModel = filepath.Join(c.Home, "models", config.NotesModelFile)
	})
	_ = os.MkdirAll(d.Cfg.Home, 0o755)
	_ = os.WriteFile(filepath.Join(d.Cfg.Home, fetchModelsScript), []byte("#!/bin/sh\necho 'checksum mismatch' >&2\nexit 1\n"), 0o755)
	if err := d.InstallNotesModel(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for d.notesInstalling() == 1 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if n := d.Status().Notes; n.Available || !strings.Contains(n.InstallErr, "checksum mismatch") {
		t.Fatalf("notes = %+v, want the failure in plain words", n)
	}
}

func TestInstallNotesModelNeedsTheScript(t *testing.T) {
	d, _ := meetingFixture(t, func(c *config.Config) {
		bin := filepath.Join(filepath.Dir(c.Home), "ox-llm")
		_ = os.MkdirAll(filepath.Dir(bin), 0o755)
		_ = os.WriteFile(bin, []byte("x"), 0o755)
		c.NotesBin = bin
		c.NotesModel = filepath.Join(c.Home, "models", config.NotesModelFile)
	})
	if err := d.InstallNotesModel(); err == nil || !strings.Contains(err.Error(), fetchModelsScript) {
		t.Fatalf("err = %v, want it to name the missing script", err)
	}
}

// The notes server's key is rewritten on every spawn and is private; the
// server's CORS is limited to localhost origins.
// Mutation: internal/daemon/meetings.go writeNotesKey, change 0o600 to
// 0o644 -> RED.
// Mutation: internal/daemon/meetings.go notesServerArgs, delete the
// `"--cors-origins", "localhost",` line -> RED (CORS stays open to any page).
func TestNotesServerArgsWriteAPrivateKeyPerSpawn(t *testing.T) {
	cfg := testCfg(t, t.TempDir())
	cfg.NotesModel = "/m/notes.gguf"
	if err := notesPrepare(cfg); err != nil {
		t.Fatal(err)
	}
	a := notesServerArgs(cfg, 8098)
	key := filepath.Join(cfg.RunDir(), notesKeyFile)
	st, err := os.Stat(key)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("key file = %v, %v; want mode 0600", st, err)
	}
	first, _ := os.ReadFile(key)
	if err := notesPrepare(cfg); err != nil {
		t.Fatal(err)
	}
	second, _ := os.ReadFile(key)
	if bytes.Equal(first, second) {
		t.Fatal("the key must change on every spawn")
	}
	joined := " " + strings.Join(a, " ") + " "
	for _, want := range []string{" -c 16384 ", " --host 127.0.0.1 ", " --port 8098 ", " --jinja ", " -np 1 ", " --api-key-file " + key + " ", " -ngl 0 ", " --cors-origins localhost "} {
		if !strings.Contains(joined, want) {
			t.Errorf("argv lacks %q: %s", want, joined)
		}
	}
	if strings.Contains(joined, string(first[:len(first)-1])) {
		t.Error("the key itself must never be in the argv")
	}
	// `-ngl 0` (asserted above) and the Metal env go together (#238.c); the full pairing is in
	// TestNotesEnginePinsCPUDecodeAndMetalConcurrencyTogether.
	if env := notesEngineConfig(cfg, nil).Env; !slices.Equal(env, []string{"GGML_METAL_CONCURRENCY_DISABLE=1"}) {
		t.Errorf("with -ngl 0 the notes child env = %q, want GGML_METAL_CONCURRENCY_DISABLE=1", env)
	}
}

// ox-llm must be spawned by an absolute path: it finds its Metal library
// next to argv[0], and a relative binary path would resolve against the
// daemon's working directory, not the install (#238). The spawn argv is
// stamped by the fake child and checked here end to end.
// Mutation: internal/daemon/meetings.go notesBinPath, return cfg.NotesBin
// unchanged -> RED (the spawned argv[0] is relative).
func TestNotesBinSpawnsByAbsolutePath(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_LLM", "1")
	t.Setenv("OXSAY_FAKE_DIR", dir)
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	rel, err := filepath.Rel(cwd, os.Args[0])
	if err != nil {
		t.Fatal(err)
	}
	d, _ := meetingFixture(t, func(c *config.Config) {
		c.NotesBin = rel
		c.NotesModel = filepath.Join(dir, "notes.gguf")
	})
	if _, err := d.LLMSup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	marks, err := filepath.Glob(filepath.Join(dir, "llm-spawn-*"))
	if err != nil || len(marks) != 1 {
		t.Fatalf("spawn stamps = %v, %v", marks, err)
	}
	raw, _ := os.ReadFile(marks[0])
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if !filepath.IsAbs(lines[0]) {
		t.Fatalf("ox-llm spawned as argv[0] %q — not absolute", lines[0])
	}
	joined := " " + strings.Join(lines[1:], " ") + " "
	for _, want := range []string{" --host 127.0.0.1 ", " --api-key-file ", " --cors-origins localhost "} {
		if !strings.Contains(joined, want) {
			t.Errorf("spawn argv lacks %q: %s", want, joined)
		}
	}
}

// A notes call made while the model still loads must wait the bounded
// /health window: a loading llama-server answers 503 and an ungated call
// would spend the composer chunk retries on the load, not the notes (#235).
// The fake 503s /health and /v1/chat/completions for its start-delay.
// Mutation: internal/daemon/meetings.go llmChat.Complete, delete the
// EnsureReady call (POST at once) -> RED (the fake answers 503).
func TestNotesCallWaitsForTheModelToLoad(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_LLM", "1")
	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "400")
	d, _ := meetingFixture(t, func(c *config.Config) {
		c.NotesBin = os.Args[0]
		c.NotesModel = filepath.Join(dir, "notes.gguf")
	})
	start := time.Now()
	out, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"})
	if err != nil {
		t.Fatalf("the call did not wait the load out: %v", err)
	}
	if out == "" || time.Since(start) < 350*time.Millisecond {
		t.Fatalf("out = %q after %s — the call did not wait for /health", out, time.Since(start))
	}
}

// An ox-llm that fails to start is a failed engine, not "unsupported": the
// 8 GB Mac whose memory read 0 must show the real failure in /status (#243).
// Mutation: internal/daemon/meetings.go notesStatus, drop the
// `out.State, out.LastErr = st.State, st.LastErr` wiring (report stopped
// with no last_error) -> RED.
func TestAFailedNotesStartIsReportedAsFailed(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_LLM", "1")
	t.Setenv("OXSAY_FAKE_LLM_EXIT", "1")
	var model string
	d, _ := meetingFixture(t, func(c *config.Config) {
		model = filepath.Join(dir, "models", config.NotesModelFile)
		_ = os.MkdirAll(filepath.Dir(model), 0o755)
		_ = os.WriteFile(model, []byte("x"), 0o600)
		c.NotesBin, c.NotesModel = os.Args[0], model
	})
	if _, err := (llmChat{d: d}).Complete(context.Background(), meeting.Request{System: "s", User: "u"}); err == nil {
		t.Fatal("a start that fails must surface an error")
	}
	n := d.Status().Notes
	if n.ReasonCode == config.NotesReasonUnsupported || n.State == stateNotesUnavailable {
		t.Fatalf("notes = %+v, a failed start is not unsupported", n)
	}
	if n.State != engine.StateStopped && n.State != engine.StateCrashed {
		t.Fatalf("notes = %+v, want a real engine state after a failed start", n)
	}
	if n.LastErr == "" {
		t.Fatalf("notes = %+v, want the start failure in last_error", n)
	}
}

// A meeting waiting on the recognizer's model is not re-queued every
// housekeep round while the model is still missing; it goes back the round
// it lands (#244). testCfg's STTModel does not exist, so the wired
// TranscribeReady reports stt_model_missing.
// Mutation: internal/meeting/runner.go retryFailed, delete the
// `r.TranscribeReady` gate -> RED (the meeting is re-queued and unmarked
// while the model is still absent).
func TestAWaitingMeetingIsNotRequeuedWhileTheSTTModelIsMissing(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	d.Meet.Transcribe = func(context.Context, string) (*stt.Result, error) {
		return nil, &stt.ModelError{}
	}
	m, dir, err := d.Meet.Store.Create(meeting.Manifest{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	writeTone(t, filepath.Join(dir, meeting.MePCM), 5)
	if _, err := d.Meet.Finish(m.ID, time.Now()); err != nil {
		t.Fatal(err)
	}
	_ = d.Meet.Process(context.Background(), m.ID)
	for range 3 {
		d.Meet.Recover()
	}
	got, err := d.Meet.Store.Load(m.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != meeting.StatusFailed || got.WaitingFor != meeting.WaitSTTModel || got.Attempts != 0 {
		t.Fatalf("manifest = %+v, want failed+waiting with no attempts spent", got)
	}
	if err := os.WriteFile(d.Cfg.STTModel, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	d.Meet.Recover()
	if got, _ := d.Meet.Store.Load(m.ID); got.Status != meeting.StatusQueued || got.WaitingFor != "" {
		t.Fatalf("after the model arrived: %+v, want queued", got)
	}
}

// A Mac without unified memory decodes on the CPU: its pieces are short, so
// one recognizer call never holds dictation up for minutes.
// Mutation: internal/daemon/meetings.go pieceSeconds, return
// meeting.DefaultPieceSeconds unconditionally -> RED.
func TestPieceSecondsFollowTheMemoryModel(t *testing.T) {
	d, _ := meetingFixture(t, nil) // testCfg has no unified memory
	if got := d.pieceSeconds(); got != cpuPieceSeconds {
		t.Fatalf("discrete: pieceSeconds = %d, want %d", got, cpuPieceSeconds)
	}
	d.Cfg.GPUMemory = config.GPUMemoryUnified
	if got := d.pieceSeconds(); got != meeting.DefaultPieceSeconds {
		t.Fatalf("unified: pieceSeconds = %d, want %d", got, meeting.DefaultPieceSeconds)
	}
}

func TestInstallNotesModelRefusesAForeignFileName(t *testing.T) {
	d, _ := meetingFixture(t, func(c *config.Config) {
		bin := filepath.Join(filepath.Dir(c.Home), "ox-llm")
		_ = os.MkdirAll(filepath.Dir(bin), 0o755)
		_ = os.WriteFile(bin, []byte("x"), 0o755)
		c.NotesBin = bin
		c.NotesModel = filepath.Join(c.Home, "models", "my-own-model.gguf")
	})
	if err := d.InstallNotesModel(); err == nil || !strings.Contains(err.Error(), "different file") {
		t.Fatalf("err = %v, want a refusal to download over the user's own model path", err)
	}
}

// Without unified memory the notes server decodes on the CPU (`-ngl 0`) AND its Metal graph runs without concurrency
// (GGML_METAL_CONCURRENCY_DISABLE=1): llama.cpp's own ggml has none of the engine's AMD patch, and the two settings
// belong together (#238.c). With unified memory the layers go to the GPU and the variable is not set. The argv and
// the env come from the same memory-model decision, so they are pinned together.
// Mutation: internal/daemon/meetings.go notesEngineConfig, drop the `Env: notesServerEnv(cfg),` line -> RED.
func TestNotesEnginePinsCPUDecodeAndMetalConcurrencyTogether(t *testing.T) {
	for _, tc := range []struct {
		name    string
		memory  string
		wantNGL string
		wantEnv []string
	}{
		{"discrete", config.GPUMemoryDiscrete, " -ngl 0 ", []string{"GGML_METAL_CONCURRENCY_DISABLE=1"}},
		{"unified", config.GPUMemoryUnified, " -ngl 99 ", nil},
	} {
		cfg := testCfg(t, t.TempDir())
		cfg.NotesModel, cfg.GPUMemory = "/m/notes.gguf", tc.memory
		ec := notesEngineConfig(cfg, nil)
		joined := " " + strings.Join(ec.Args(8098), " ") + " "
		if !strings.Contains(joined, tc.wantNGL) {
			t.Errorf("%s: argv lacks %q: %s", tc.name, tc.wantNGL, joined)
		}
		if !slices.Equal(ec.Env, tc.wantEnv) {
			t.Errorf("%s: Env = %q, want %q", tc.name, ec.Env, tc.wantEnv)
		}
	}
}

// The variable reaches the spawned ox-llm (the supervisor passes Config.Env on), and only on a discrete card.
// Mutation: internal/engine/supervisor.go spawn, delete the `cmd.Env = ...` line -> RED.
func TestNotesChildGetsTheMetalConcurrencySettingOnlyOnADiscreteCard(t *testing.T) {
	for _, tc := range []struct{ memory, want string }{
		{config.GPUMemoryDiscrete, "1"},
		{config.GPUMemoryUnified, "unset"},
	} {
		dir := t.TempDir()
		t.Setenv("OXSAY_FAKE_LLM", "1")
		t.Setenv("OXSAY_FAKE_DIR", dir)
		t.Setenv("GGML_METAL_CONCURRENCY_DISABLE", "") // registers the restore; the next line makes it absent
		_ = os.Unsetenv("GGML_METAL_CONCURRENCY_DISABLE")
		d, _ := meetingFixture(t, func(c *config.Config) {
			c.NotesBin, c.GPUMemory = os.Args[0], tc.memory
			c.NotesModel = filepath.Join(dir, "notes.gguf")
		})
		if _, err := d.LLMSup.EnsureReady(context.Background()); err != nil {
			t.Fatal(err)
		}
		marks, err := filepath.Glob(filepath.Join(dir, "llm-metal-*"))
		if err != nil || len(marks) != 1 {
			t.Fatalf("%s: env stamps = %v, %v", tc.memory, marks, err)
		}
		if raw, _ := os.ReadFile(marks[0]); string(raw) != tc.want {
			t.Errorf("%s: GGML_METAL_CONCURRENCY_DISABLE in the child = %q, want %q", tc.memory, raw, tc.want)
		}
	}
}
