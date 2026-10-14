package daemon

import (
	"context"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// unified is a newTestDaemonSTT editCfg that puts the daemon in Apple
// Silicon mode before newDaemon wires the supervisors.
func unified(c *config.Config) { c.GPUMemory = config.GPUMemoryUnified }

// Unified memory: the resident server decodes on the GPU — no -ng — and
// takes no lease; OX_SAY_STT_GPU=off still pins it to the CPU.
// Mutation A: service.go ≈ line 97 (STTServeArgs, the -ng condition)
// replace `!cfg.UnifiedMemory()` with `true` -> RED (the unified serve
// argv carries -ng).
// Mutation B: same line, drop `|| cfg.STTGPU == "off"` -> RED (off loses -ng).
// (Dropping `!cfg.UnifiedMemory() ||` instead is the Intel-guard mutation:
// it turns the existing TestSTTServerArgs RED, not this test.)
func TestUnifiedSTTServerOnGPU(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, unified, nil, nil)
	log := sttSetupServer(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")
	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	argv := lastServeArgv(t, log)
	if argvHas(argv, "-ng") {
		t.Fatalf("unified memory: serve argv %v has -ng; the server belongs on the GPU", argv)
	}
	for _, want := range []string{"--serve", "--port", "-m"} {
		if !argvHas(argv, want) {
			t.Fatalf("serve argv %v missing %q", argv, want)
		}
	}
	if d.gpu.Held() {
		t.Fatal("unified memory: the resident STT server took the GPU lease")
	}

	dir2 := t.TempDir()
	d2 := newTestDaemonSTT(t, dir2, unified, nil, nil)
	log2 := sttSetupServer(t, d2, dir2)
	// sttSetupServer resets STTGPU to auto; the Args func reads it per spawn.
	d2.Cfg.STTGPU = "off"
	src2 := testutil.WriteTinyWAV(t, dir2, "in.wav")
	if _, err := d2.Transcribe(context.Background(), TranscribeInput{AudioPath: src2}); err != nil {
		t.Fatal(err)
	}
	if argv := lastServeArgv(t, log2); !argvHas(argv, "-ng") {
		t.Fatalf("unified memory + OX_SAY_STT_GPU=off: serve argv %v missing -ng", argv)
	}
}

// Unified memory: the TTS engine takes no lease, and a per-call CLI
// transcription runs on the GPU while the engine is Ready — even with the
// lease token held elsewhere, because unified memory never consults it.
// Mutation A: service.go ≈ line 150 (newDaemon, the `if !cfg.UnifiedMemory()`
// around ec.GPU) set ec.GPU = d.gpu unconditionally -> RED (the lease is
// held while the engine is Ready).
// Mutation B: transcribe.go ≈ line 51 (Daemon.Transcribe) set
// opts.GPULease = d.gpu unconditionally -> RED (TryAs fails on the held
// token and the CLI argv carries -ng).
func TestUnifiedTTSAndCLIShareGPU(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, unified, nil, nil)
	log := sttSetup(t, d, dir)
	src := testutil.WriteTinyWAV(t, dir, "in.wav")

	if _, err := d.Sup.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	g := d.Sup.Acquire()
	defer g.Release()
	if held, by := d.gpu.Held(), d.Sup.Status().GPUHeldBy; held || by != "" {
		t.Fatalf("unified memory: TTS engine Ready holds the GPU lease (held=%v gpu_held_by=%q)", held, by)
	}
	if !d.gpu.TryAs("probe") {
		t.Fatal("lease unexpectedly taken")
	}
	defer d.gpu.Release()
	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	if args := lastArgvArgs(t, log); argvHas(args, "-ng") {
		t.Fatalf("unified memory: CLI argv %v has -ng while TTS is Ready", args)
	}
}
