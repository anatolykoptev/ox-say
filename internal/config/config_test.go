package config

import (
	"flag"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// T8: a non-loopback OX_SAY_ADDR must be refused at config load.
// Mutation: remove the loopback check in splitLoopbackAddr -> RED.
func TestLoadRefusesNonLoopbackAddr(t *testing.T) {
	for _, addr := range []string{"0.0.0.0:8094", ":8094", "192.168.1.5:8094", "[::]:8094"} {
		t.Setenv("OX_SAY_ADDR", addr)
		if _, err := Load(nil); err == nil {
			t.Fatalf("OX_SAY_ADDR=%q: expected refusal, got no error", addr)
		} else if !strings.Contains(err.Error(), "loopback") && !strings.Contains(err.Error(), "empty host") {
			t.Fatalf("OX_SAY_ADDR=%q: unexpected error: %v", addr, err)
		}
	}
}

func TestLoadLoopbackOK(t *testing.T) {
	for _, addr := range []string{"127.0.0.1:8094", "[::1]:8094", "localhost:8094"} {
		t.Setenv("OX_SAY_ADDR", addr)
		c, err := Load(nil)
		if err != nil {
			t.Fatalf("OX_SAY_ADDR=%q: %v", addr, err)
		}
		if c.Addr != addr {
			t.Fatalf("addr = %q, want %q", c.Addr, addr)
		}
	}
}

func TestLoadDefaults(t *testing.T) {
	// Point every path var at a temp HOME-independent base so the test does
	// not depend on the real home layout beyond joining.
	t.Setenv("OX_SAY_HOME", "/tmp/oxsay-test-home")
	c, err := Load(nil)
	if err != nil {
		t.Fatal(err)
	}
	if c.Addr != DefaultAddr || c.Host != "127.0.0.1" || c.Port != "8094" {
		t.Fatalf("addr fields: %+v", c)
	}
	if c.EnginePort != DefaultEnginePort || c.MaxBatch != DefaultMaxBatch {
		t.Fatalf("engine fields: %+v", c)
	}
	if c.IdleStop != DefaultIdleStopSecs*time.Second {
		t.Fatalf("idle stop = %v", c.IdleStop)
	}
	if c.StartupTimeout != DefaultStartupTimeout*time.Second {
		t.Fatalf("startup timeout = %v", c.StartupTimeout)
	}
	wantBin := filepath.Join("/tmp/oxsay-test-home", "engine", "tts-server")
	if c.EngineBin != wantBin {
		t.Fatalf("engine bin = %q, want %q", c.EngineBin, wantBin)
	}
	if c.VoicesDir() != filepath.Join("/tmp/oxsay-test-home", "voices") {
		t.Fatalf("voices dir = %q", c.VoicesDir())
	}
	if c.STTBin != filepath.Join("/tmp/oxsay-test-home", "engine", "ox-stt") {
		t.Fatalf("stt bin = %q", c.STTBin)
	}
	if c.STTModel != filepath.Join("/tmp/oxsay-test-home", "models", "ggml-parakeet-tdt-0.6b-v3-f16.bin") {
		t.Fatalf("stt model = %q", c.STTModel)
	}
	if c.STTWhisperModel != filepath.Join("/tmp/oxsay-test-home", "models", "ggml-large-v3-turbo.bin") {
		t.Fatalf("stt whisper model = %q", c.STTWhisperModel)
	}
	if c.STTGPU != "auto" || c.STTTimeout != DefaultSTTTimeout*time.Second || c.STTMaxUploadMB != DefaultSTTMaxUploadMB {
		t.Fatalf("stt defaults: %+v", c)
	}
}

// An invalid OX_SAY_STT_GPU must be refused at load: a typo silently picking
// a device is worse than a loud failure.
func TestLoadSTTGPUValidation(t *testing.T) {
	for _, v := range []string{"auto", "on", "off"} {
		t.Setenv("OX_SAY_STT_GPU", v)
		if _, err := Load(nil); err != nil {
			t.Fatalf("OX_SAY_STT_GPU=%q: %v", v, err)
		}
	}
	t.Setenv("OX_SAY_STT_GPU", "gpu")
	if _, err := Load(nil); err == nil {
		t.Fatal("OX_SAY_STT_GPU=gpu accepted")
	}
}

func TestFlagOverridesEnv(t *testing.T) {
	t.Setenv("OX_SAY_ADDR", "127.0.0.1:8094")
	t.Setenv("OX_SAY_IDLE_STOP_SECS", "10")
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	RegisterFlags(fs)
	if err := fs.Parse([]string{"-addr", "127.0.0.1:9999", "-idle-stop", "3"}); err != nil {
		t.Fatal(err)
	}
	c, err := Load(fs)
	if err != nil {
		t.Fatal(err)
	}
	if c.Addr != "127.0.0.1:9999" {
		t.Fatalf("flag override lost: addr = %q", c.Addr)
	}
	if c.IdleStop != 3*time.Second {
		t.Fatalf("flag override lost: idle = %v", c.IdleStop)
	}
}
