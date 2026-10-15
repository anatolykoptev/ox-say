package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/testutil"
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
