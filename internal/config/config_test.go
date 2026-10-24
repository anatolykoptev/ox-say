package config

import (
	"errors"
	"flag"
	"go/ast"
	"go/parser"
	"go/token"
	"maps"
	"os"
	"path/filepath"
	"strconv"
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
	if c.STTModel != filepath.Join("/tmp/oxsay-test-home", "models", "ggml-parakeet-tdt-0.6b-v3-q8_0.bin") {
		t.Fatalf("stt model = %q", c.STTModel)
	}
	if c.STTWhisperModel != filepath.Join("/tmp/oxsay-test-home", "models", "ggml-large-v3-turbo.bin") {
		t.Fatalf("stt whisper model = %q", c.STTWhisperModel)
	}
	if c.STTGPU != "auto" || c.STTTimeout != DefaultSTTTimeout*time.Second || c.STTMaxUploadMB != DefaultSTTMaxUploadMB {
		t.Fatalf("stt defaults: %+v", c)
	}
	if c.STTServer != "on" || c.STTPort != DefaultSTTPort || c.STTIdleStop != DefaultSTTIdleStop*time.Second {
		t.Fatalf("stt server defaults: %+v", c)
	}
}

// The resident STT server's own knobs: on|off, a port that must not collide
// with the daemon's or the engine's, and a >= 1 s idle stop.
// Mutation: drop the STTServer validation switch in load -> RED; drop the
// port collision checks -> RED ("accepted a port equal to the engine's").
func TestLoadSTTServerValidation(t *testing.T) {
	for _, v := range []string{"on", "off"} {
		t.Setenv("OX_SAY_STT_SERVER", v)
		if _, err := Load(nil); err != nil {
			t.Fatalf("OX_SAY_STT_SERVER=%q: %v", v, err)
		}
	}
	t.Setenv("OX_SAY_STT_SERVER", "yes")
	if _, err := Load(nil); err == nil {
		t.Fatal("OX_SAY_STT_SERVER=yes accepted")
	}
	t.Setenv("OX_SAY_STT_SERVER", "on")

	for _, kv := range [][2]string{
		{"OX_SAY_STT_PORT", "notaport"},
		{"OX_SAY_STT_PORT", "0"},
		{"OX_SAY_STT_PORT", "65536"},
		{"OX_SAY_STT_IDLE_STOP_SECS", "0"},
		{"OX_SAY_STT_IDLE_STOP_SECS", "-3"},
	} {
		t.Setenv(kv[0], kv[1])
		if _, err := Load(nil); err == nil {
			t.Fatalf("%s=%s accepted", kv[0], kv[1])
		}
		t.Setenv(kv[0], "")
	}

	// The STT server port must not take the engine's or the daemon's own.
	t.Setenv("OX_SAY_STT_PORT", strconv.Itoa(DefaultEnginePort))
	if _, err := Load(nil); err == nil {
		t.Fatal("accepted a port equal to the engine's")
	}
	t.Setenv("OX_SAY_STT_PORT", "8094") // default OX_SAY_ADDR port
	if _, err := Load(nil); err == nil {
		t.Fatal("accepted a port equal to the daemon's")
	}
}

// OX_SAY_STT_VAD_MODEL defaults to the silero VAD weights in the same
// models dir as the parakeet default, and the env var overrides it.
// Mutation: drop the default assignment (leave the field empty when the env
// is unset) -> RED on the default-path assertion.
func TestLoadSTTVADModel(t *testing.T) {
	t.Setenv("OX_SAY_HOME", "/tmp/oxsay-test-home")
	c, err := Load(nil)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join("/tmp/oxsay-test-home", "models", "ggml-silero-v5.1.2.bin")
	if c.STTVADModel != want {
		t.Fatalf("stt vad model = %q, want %q", c.STTVADModel, want)
	}
	t.Setenv("OX_SAY_STT_VAD_MODEL", "/tmp/custom-vad.bin")
	c, err = Load(nil)
	if err != nil {
		t.Fatal(err)
	}
	if c.STTVADModel != "/tmp/custom-vad.bin" {
		t.Fatalf("stt vad model override = %q", c.STTVADModel)
	}
	found := false
	for _, k := range EnvKeys() {
		if k == "OX_SAY_STT_VAD_MODEL" {
			found = true
		}
	}
	if !found {
		t.Fatal("OX_SAY_STT_VAD_MODEL missing from EnvKeys")
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

// STT bounds: a zero or negative timeout, audio cap or upload cap, and an
// upload cap that would overflow MB<<20, are refused at load.
func TestLoadSTTBounds(t *testing.T) {
	for _, kv := range [][2]string{
		{"OX_SAY_STT_TIMEOUT_SECS", "0"},
		{"OX_SAY_STT_TIMEOUT_SECS", "-5"},
		{"OX_SAY_STT_MAX_UPLOAD_MB", "0"},
		{"OX_SAY_STT_MAX_UPLOAD_MB", "9000000000000"},
		{"OX_SAY_STT_MAX_AUDIO_SECS", "0"},
		// past 24 h, base + k×duration heads for a time.Duration overflow
		{"OX_SAY_STT_TIMEOUT_SECS", "86401"},
		{"OX_SAY_STT_MAX_AUDIO_SECS", "86401"},
		{"OX_SAY_STT_MAX_AUDIO_SECS", "3100000000"},
	} {
		t.Run(kv[0]+"="+kv[1], func(t *testing.T) {
			t.Setenv(kv[0], kv[1])
			if _, err := Load(nil); err == nil {
				t.Fatalf("%s=%s accepted", kv[0], kv[1])
			}
		})
	}
}

// The installer trusts EnvKeys as the set the LaunchAgent may carry: every
// entry must actually land in the loaded Config (a table entry the loader
// ignores would be written into the agent's environment with no effect), and
// each case below must be in EnvKeys (a read the table misses would never
// reach the daemon under launchd). Durations render via String(), so the
// expected value is not always the raw env string.
func TestEnvKeysAllLoaded(t *testing.T) {
	cases := []struct {
		env, set, want string
		read           func(*Config) string
	}{
		{"OX_SAY_HOME", "/tmp/oxk-4917/home", "/tmp/oxk-4917/home", func(c *Config) string { return c.Home }},
		{"OX_SAY_ADDR", "127.0.0.1:18094", "127.0.0.1:18094", func(c *Config) string { return c.Addr }},
		{"OX_SAY_ENGINE_PORT", "18095", "18095", func(c *Config) string { return strconv.Itoa(c.EnginePort) }},
		{"OX_SAY_ENGINE_BIN", "/tmp/oxk-4917/tts-x", "/tmp/oxk-4917/tts-x", func(c *Config) string { return c.EngineBin }},
		{"OX_SAY_MODEL", "/tmp/oxk-4917/model-x.gguf", "/tmp/oxk-4917/model-x.gguf", func(c *Config) string { return c.Model }},
		{"OX_SAY_CODEC", "/tmp/oxk-4917/codec-x.gguf", "/tmp/oxk-4917/codec-x.gguf", func(c *Config) string { return c.Codec }},
		{"OX_SAY_MAX_BATCH", "17", "17", func(c *Config) string { return strconv.Itoa(c.MaxBatch) }},
		{"OX_SAY_IDLE_STOP_SECS", "61", "1m1s", func(c *Config) string { return c.IdleStop.String() }},
		{"OX_SAY_STARTUP_TIMEOUT_SECS", "62", "1m2s", func(c *Config) string { return c.StartupTimeout.String() }},
		{"OX_SAY_LANG", "Testlang", "Testlang", func(c *Config) string { return c.Lang }},
		{"OX_SAY_VOICE", "testvoice", "testvoice", func(c *Config) string { return c.Voice }},
		{"OX_SAY_VOICE_RU", "testvoiceru", "testvoiceru", func(c *Config) string { return c.VoiceRU }},
		{"OX_SAY_VOICE_EN", "testvoiceen", "testvoiceen", func(c *Config) string { return c.VoiceEN }},
		{"OX_SAY_ENGINE_LOG_DIR", "/tmp/oxk-4917/logs", "/tmp/oxk-4917/logs", func(c *Config) string { return c.EngineLogDir }},
		{"OX_SAY_CACHE_DIR", "/tmp/oxk-4917/cache", "/tmp/oxk-4917/cache", func(c *Config) string { return c.CacheDir }},
		{"OX_SAY_PRODUCE_OUT_DIR", "/tmp/oxk-4917/produce-out", "/tmp/oxk-4917/produce-out", func(c *Config) string { return c.ProduceOutDir }},
		{"OX_SAY_STT_BIN", "/tmp/oxk-4917/ox-stt-x", "/tmp/oxk-4917/ox-stt-x", func(c *Config) string { return c.STTBin }},
		{"OX_SAY_STT_MODEL", "/tmp/oxk-4917/stt-x.bin", "/tmp/oxk-4917/stt-x.bin", func(c *Config) string { return c.STTModel }},
		{"OX_SAY_STT_WHISPER_MODEL", "/tmp/oxk-4917/whisper-x.bin", "/tmp/oxk-4917/whisper-x.bin", func(c *Config) string { return c.STTWhisperModel }},
		{"OX_SAY_STT_VAD_MODEL", "/tmp/oxk-4917/vad-x.bin", "/tmp/oxk-4917/vad-x.bin", func(c *Config) string { return c.STTVADModel }},
		{"OX_SAY_STT_GPU", "off", "off", func(c *Config) string { return c.STTGPU }},
		{"OX_SAY_GPU_MEMORY", "discrete", "discrete", func(c *Config) string { return c.GPUMemory }},
		{"OX_SAY_STT_TIMEOUT_SECS", "63", "1m3s", func(c *Config) string { return c.STTTimeout.String() }},
		{"OX_SAY_STT_MAX_UPLOAD_MB", "64", "64", func(c *Config) string { return strconv.FormatInt(c.STTMaxUploadMB, 10) }},
		{"OX_SAY_STT_MAX_AUDIO_SECS", "65", "1m5s", func(c *Config) string { return c.STTMaxAudio.String() }},
		{"OX_SAY_STT_SERVER", "off", "off", func(c *Config) string { return c.STTServer }},
		{"OX_SAY_STT_PORT", "18096", "18096", func(c *Config) string { return strconv.Itoa(c.STTPort) }},
		{"OX_SAY_STT_IDLE_STOP_SECS", "66", "1m6s", func(c *Config) string { return c.STTIdleStop.String() }},
		{"OX_SAY_VOXCPM2_BIN", "/tmp/oxk-4917/audiocpp-x", "/tmp/oxk-4917/audiocpp-x", func(c *Config) string { return c.VoxCPM2Bin }},
		{"OX_SAY_VOXCPM2_MODEL", "/tmp/oxk-4917/vox-x.gguf", "/tmp/oxk-4917/vox-x.gguf", func(c *Config) string { return c.VoxCPM2Model }},
		{"OX_SAY_VOXCPM2_PORT", "18097", "18097", func(c *Config) string { return strconv.Itoa(c.VoxCPM2Port) }},
		{"OX_SAY_TTS_MODEL", "voxcpm2", "voxcpm2", func(c *Config) string { return c.TTSModel }},
		{"OX_SAY_NOTES_BIN", "/tmp/oxk-4917/ox-llm-x", "/tmp/oxk-4917/ox-llm-x", func(c *Config) string { return c.NotesBin }},
		{"OX_SAY_NOTES_MODEL", "/tmp/oxk-4917/notes-x.gguf", "/tmp/oxk-4917/notes-x.gguf", func(c *Config) string { return c.NotesModel }},
		{"OX_SAY_NOTES_PORT", "18098", "18098", func(c *Config) string { return strconv.Itoa(c.NotesPort) }},
		{"OX_SAY_NOTES_IDLE_STOP_SECS", "67", "1m7s", func(c *Config) string { return c.NotesIdleStop.String() }},
	}
	keys := EnvKeys()
	inTable := map[string]bool{}
	for _, k := range keys {
		inTable[k] = true
	}
	probed := map[string]bool{}
	for _, tc := range cases {
		probed[tc.env] = true
		t.Setenv(tc.env, tc.set)
		if !inTable[tc.env] {
			t.Errorf("%s is read (see probe) but missing from EnvKeys", tc.env)
		}
	}
	for _, k := range keys {
		if !probed[k] {
			t.Errorf("EnvKeys entry %s has no load probe in this test", k)
		}
		if !strings.HasPrefix(k, "OX_SAY_") {
			t.Errorf("EnvKeys entry %q lacks the OX_SAY_ prefix", k)
		}
	}
	c, err := Load(nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range cases {
		if got := tc.read(c); got != tc.want {
			t.Errorf("%s=%q did not reach the config: field reads %q, want %q", tc.env, tc.set, got, tc.want)
		}
	}
}

// OX_SAY_GPU_MEMORY: auto (and unset) resolves against the host — Apple
// Silicon is unified, anything else discrete — explicit values win on any
// host, and a typo is refused. The host probe is stubbed, so the test means
// the same on linux CI, an Intel Mac and Apple Silicon.
// Mutation: config.go ≈ line 300 (resolveGPUMemory, `case GPUMemoryAuto:`)
// return GPUMemoryDiscrete without consulting hostUnifiedMemory -> RED.
func TestLoadGPUMemory(t *testing.T) {
	orig := hostUnifiedMemory
	t.Cleanup(func() { hostUnifiedMemory = orig })
	cases := []struct {
		env  string
		host bool
		want string
	}{
		{"", true, GPUMemoryUnified},
		{"", false, GPUMemoryDiscrete},
		{"auto", true, GPUMemoryUnified},
		{"auto", false, GPUMemoryDiscrete},
		{"discrete", true, GPUMemoryDiscrete},
		{"unified", false, GPUMemoryUnified},
	}
	for _, tc := range cases {
		hostUnifiedMemory = func() bool { return tc.host }
		t.Setenv("OX_SAY_GPU_MEMORY", tc.env)
		c, err := Load(nil)
		if err != nil {
			t.Fatalf("OX_SAY_GPU_MEMORY=%q host unified=%v: %v", tc.env, tc.host, err)
		}
		if c.GPUMemory != tc.want || c.UnifiedMemory() != (tc.want == GPUMemoryUnified) {
			t.Fatalf("OX_SAY_GPU_MEMORY=%q host unified=%v: GPUMemory=%q UnifiedMemory=%v, want %q",
				tc.env, tc.host, c.GPUMemory, c.UnifiedMemory(), tc.want)
		}
	}
	t.Setenv("OX_SAY_GPU_MEMORY", "shared")
	if _, err := Load(nil); err == nil {
		t.Fatal("OX_SAY_GPU_MEMORY=shared accepted")
	}
	if (&Config{}).UnifiedMemory() {
		t.Fatal("a Config literal (GPUMemory \"\") must keep the discrete-card behaviour")
	}
}

// EnvKeys and the reads must not drift: parse the module's non-test Go
// sources and require every OX_SAY_* read — load()'s get("…") calls in this
// package and os.Getenv/LookupEnv everywhere — to be a table entry.
// Mutation: add get("OX_SAY_X") in load() or drop a flagNames value -> RED.
func TestEnvKeysMatchSource(t *testing.T) {
	inTable := map[string]bool{}
	for _, k := range EnvKeys() {
		inTable[k] = true
	}
	read := map[string]string{} // env key -> first file:line that reads it

	fset := token.NewFileSet()
	collect := func(path string, inConfig bool) {
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", path, err)
		}
		ast.Inspect(f, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok || len(call.Args) == 0 {
				return true
			}
			lit, ok := call.Args[0].(*ast.BasicLit)
			if !ok || lit.Kind != token.STRING {
				return true
			}
			key, err := strconv.Unquote(lit.Value)
			if err != nil || !strings.HasPrefix(key, "OX_SAY_") {
				return true
			}
			isRead := false
			switch fun := call.Fun.(type) {
			case *ast.Ident:
				// load()'s getenv helper — only meaningful in this package.
				isRead = inConfig && fun.Name == "get"
			case *ast.SelectorExpr:
				if pkg, ok := fun.X.(*ast.Ident); ok && pkg.Name == "os" {
					isRead = fun.Sel.Name == "Getenv" || fun.Sel.Name == "LookupEnv"
				}
			}
			if isRead {
				pos := fset.Position(call.Pos())
				if _, seen := read[key]; !seen {
					read[key] = filepath.Clean(path) + ":" + strconv.Itoa(pos.Line)
				}
			}
			return true
		})
	}
	// This package's sources (cwd during `go test`) plus every other non-test
	// .go file in the module, minus gitignored trees.
	pkgDir, err := filepath.Abs(".")
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		abs := filepath.Join(pkgDir, name)
		seen[abs] = true
		collect(name, true)
	}
	root := filepath.Join("..", "..")
	skip := map[string]bool{".git": true, "build": true, "dist": true, "vendor": true}
	err = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && skip[d.Name()] {
			return filepath.SkipDir
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		abs, err := filepath.Abs(path)
		if err != nil {
			return err
		}
		if seen[abs] {
			return nil // already collected via the package dir
		}
		collect(path, filepath.Dir(abs) == pkgDir)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for key, where := range read {
		if !inTable[key] {
			t.Errorf("%s is read at %s but missing from EnvKeys", key, where)
		}
	}
	for _, k := range EnvKeys() {
		if _, ok := read[k]; !ok {
			t.Errorf("EnvKeys entry %s is never read", k)
		}
	}
}

// voxEnv writes a binary and a model file into a temp home and returns the env
// that points a loaded Config at them, on unified memory with 32 GB.
func voxEnv(t *testing.T) (env map[string]string, bin, model string) {
	t.Helper()
	orig := hostMemoryBytes
	t.Cleanup(func() { hostMemoryBytes = orig })
	hostMemoryBytes = func() uint64 { return 32 * bytesPerGB }
	dir := t.TempDir()
	bin, model = filepath.Join(dir, "audiocpp_server"), filepath.Join(dir, VoxCPM2ModelFile)
	for _, p := range []string{bin, model} {
		if err := os.WriteFile(p, nil, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	env = map[string]string{
		"OX_SAY_HOME": dir, "OX_SAY_VOXCPM2_BIN": bin, "OX_SAY_VOXCPM2_MODEL": model,
		"OX_SAY_GPU_MEMORY": GPUMemoryUnified,
	}
	return env, bin, model
}

func loadEnv(t *testing.T, env map[string]string) *Config {
	t.Helper()
	c, err := load(func(k string) string { return env[k] }, nil)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// VoxCPM2 is enabled by the MODEL being present on a big-enough Apple Silicon
// Mac, never by the binary alone (issue #137.5); every refusal says why in plain
// words. Mutation: config.go VoxCPM2Unavailable, drop the model-file stat (the
// second isRegularFile) -> the "no model" case returns "" -> RED; drop the
// !c.UnifiedMemory() branch -> the Intel case returns "" -> RED; drop the
// HostMemoryBytes branch -> the 16 GB case returns "" -> RED.
func TestVoxCPM2Unavailable(t *testing.T) {
	env, _, _ := voxEnv(t)
	if got := loadEnv(t, env).VoxCPM2Unavailable(); got != "" {
		t.Fatalf("installed Apple Silicon 32 GB: %q, want available", got)
	}

	intel := maps.Clone(env)
	intel["OX_SAY_GPU_MEMORY"] = GPUMemoryDiscrete
	if got := loadEnv(t, intel).VoxCPM2Unavailable(); !strings.Contains(got, "Apple Silicon") {
		t.Errorf("Intel: %q, want an Apple Silicon reason", got)
	}

	noModel := maps.Clone(env)
	noModel["OX_SAY_VOXCPM2_MODEL"] = filepath.Join(t.TempDir(), "missing.gguf")
	if got := loadEnv(t, noModel).VoxCPM2Unavailable(); !strings.Contains(got, "model is not downloaded") {
		t.Errorf("binary without model: %q, want a model reason", got)
	}

	noBin := maps.Clone(env)
	noBin["OX_SAY_VOXCPM2_BIN"] = filepath.Join(t.TempDir(), "missing")
	if got := loadEnv(t, noBin).VoxCPM2Unavailable(); !strings.Contains(got, "engine is not installed") {
		t.Errorf("model without binary: %q, want an engine reason", got)
	}

	hostMemoryBytes = func() uint64 { return 16 * bytesPerGB }
	if got := loadEnv(t, env).VoxCPM2Unavailable(); !strings.Contains(got, "24 GB") || !strings.Contains(got, "16 GB") {
		t.Errorf("16 GB Mac: %q, want a memory reason naming 24 and 16", got)
	}
	hostMemoryBytes = func() uint64 { return 0 } // unreadable: never blocks
	if got := loadEnv(t, env).VoxCPM2Unavailable(); got != "" {
		t.Errorf("unknown memory: %q, want available", got)
	}
}

// The code tells a UI whether an install would help: hardware refusals are
// "unsupported", a missing engine or model is "model_missing", and an available
// engine has none.
// Mutation: config.go VoxCPM2Block, the Intel branch's VoxReasonUnsupported ->
// VoxReasonModelMissing -> the Intel case offers an install -> RED; the memory
// branch likewise; the model-file branch's VoxReasonModelMissing ->
// VoxReasonUnsupported -> RED.
func TestVoxCPM2BlockCodes(t *testing.T) {
	env, _, _ := voxEnv(t)
	if code, why := loadEnv(t, env).VoxCPM2Block(); code != "" || why != "" {
		t.Fatalf("available: code %q reason %q, want both empty", code, why)
	}

	intel := maps.Clone(env)
	intel["OX_SAY_GPU_MEMORY"] = GPUMemoryDiscrete
	if code, _ := loadEnv(t, intel).VoxCPM2Block(); code != VoxReasonUnsupported {
		t.Errorf("Intel: code %q, want %q", code, VoxReasonUnsupported)
	}

	noModel := maps.Clone(env)
	noModel["OX_SAY_VOXCPM2_MODEL"] = filepath.Join(t.TempDir(), "missing.gguf")
	if code, _ := loadEnv(t, noModel).VoxCPM2Block(); code != VoxReasonModelMissing {
		t.Errorf("no model: code %q, want %q", code, VoxReasonModelMissing)
	}

	noBin := maps.Clone(env)
	noBin["OX_SAY_VOXCPM2_BIN"] = filepath.Join(t.TempDir(), "missing")
	if code, _ := loadEnv(t, noBin).VoxCPM2Block(); code != VoxReasonModelMissing {
		t.Errorf("no engine: code %q, want %q", code, VoxReasonModelMissing)
	}

	hostMemoryBytes = func() uint64 { return 16 * bytesPerGB }
	if code, _ := loadEnv(t, env).VoxCPM2Block(); code != VoxReasonUnsupported {
		t.Errorf("16 GB Mac: code %q, want %q", code, VoxReasonUnsupported)
	}
}

func TestLoadTTSModelAndPorts(t *testing.T) {
	env := map[string]string{"OX_SAY_HOME": t.TempDir(), "OX_SAY_TTS_MODEL": "voxcpm2"}
	c := loadEnv(t, env)
	if c.TTSModel != TTSModelVoxCPM2 || c.VoxCPM2Port != DefaultVoxCPM2Port ||
		filepath.Base(c.VoxCPM2Model) != VoxCPM2ModelFile || filepath.Base(c.VoxCPM2Bin) != "audiocpp_server" {
		t.Fatalf("got %+v", c)
	}
	if c = loadEnv(t, map[string]string{"OX_SAY_HOME": env["OX_SAY_HOME"]}); c.TTSModel != TTSModelQwen {
		t.Fatalf("default TTS model = %q", c.TTSModel)
	}
	home := env["OX_SAY_HOME"]
	// Each case names the OX_SAY_* keys it sets on top of OX_SAY_HOME.
	for name, extra := range map[string]map[string]string{
		"unknown model":         {"OX_SAY_TTS_MODEL": "tts-2"},
		"port out of range":     {"OX_SAY_VOXCPM2_PORT": "70000"},
		"port equals engine":    {"OX_SAY_VOXCPM2_PORT": "8095"},
		"port equals stt":       {"OX_SAY_VOXCPM2_PORT": "8096"},
		"port equals daemon":    {"OX_SAY_VOXCPM2_PORT": "8200", "OX_SAY_ADDR": "127.0.0.1:8200"},
		"engine on vox default": {"OX_SAY_ENGINE_PORT": strconv.Itoa(DefaultVoxCPM2Port)},
	} {
		bad := map[string]string{"OX_SAY_HOME": home}
		maps.Copy(bad, extra)
		if _, err := load(func(k string) string { return bad[k] }, nil); err == nil {
			t.Errorf("%s: accepted %v", name, extra)
		}
	}
}

// T1 of the one-version plan: when the daemon's own executable resolves into
// <X>.app/Contents/Helpers — launchd starts bin/ox-say, a symlink into the
// bundle — every engine binary default lands in Helpers with it, because one
// bundle is the versioned unit. A daemon outside a bundle keeps
// <Home>/engine, an exe-lookup or EvalSymlinks failure falls back the same
// way so the daemon still starts, and an explicit OX_SAY_*_BIN wins in either
// layout.
// Mutations: config.go defaultEngineDir — drop the EvalSymlinks call so the
// symlink's own bin/ dir is used -> bundle subtest RED; drop the
// isBundleHelpersDir check so any exe dir counts -> plain subtest RED; point
// one default (STTBin) back at filepath.Join(c.Home, "engine", …) -> bundle
// subtest RED.
func TestLoadEngineDir(t *testing.T) {
	orig := daemonExe
	t.Cleanup(func() { daemonExe = orig })
	pinExe := func(t *testing.T, path string, err error) {
		t.Helper()
		daemonExe = func() (string, error) { return path, err }
	}
	check := func(t *testing.T, home, wantDir string) {
		t.Helper()
		c := loadEnv(t, map[string]string{"OX_SAY_HOME": home})
		for _, tc := range []struct{ field, got, bin string }{
			{"EngineBin", c.EngineBin, "tts-server"},
			{"STTBin", c.STTBin, "ox-stt"},
			{"VoxCPM2Bin", c.VoxCPM2Bin, "audiocpp_server"},
		} {
			if want := filepath.Join(wantDir, tc.bin); tc.got != want {
				t.Errorf("%s = %q, want %q", tc.field, tc.got, want)
			}
		}
	}
	homeEngine := func(t *testing.T) (home, dir string) {
		t.Helper()
		home = filepath.Join(t.TempDir(), "home")
		return home, filepath.Join(home, "engine")
	}

	t.Run("bundle", func(t *testing.T) {
		// The install layout: bin/ox-say -> OxSayDictation.app/Contents/Helpers/ox-say.
		root := t.TempDir()
		helpers := filepath.Join(root, "OxSayDictation.app", "Contents", "Helpers")
		writeFakeExe(t, filepath.Join(helpers, "ox-say"))
		link := filepath.Join(root, "bin", "ox-say")
		if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(filepath.Join(helpers, "ox-say"), link); err != nil {
			t.Fatal(err)
		}
		pinExe(t, link, nil)
		// EvalSymlinks resolves the whole path — /var -> /private/var on macOS.
		resolved, err := filepath.EvalSymlinks(helpers)
		if err != nil {
			t.Fatal(err)
		}
		home, _ := homeEngine(t)
		check(t, home, resolved)
	})

	t.Run("plain binary", func(t *testing.T) {
		pinExe(t, writeFakeExe(t, filepath.Join(t.TempDir(), "bin", "ox-say")), nil)
		home, dir := homeEngine(t)
		check(t, home, dir)
	})

	t.Run("inside app but not Helpers", func(t *testing.T) {
		pinExe(t, writeFakeExe(t, filepath.Join(t.TempDir(), "OxSayDictation.app", "Contents", "MacOS", "ox-say")), nil)
		home, dir := homeEngine(t)
		check(t, home, dir)
	})

	t.Run("eval symlinks fails", func(t *testing.T) {
		pinExe(t, filepath.Join(t.TempDir(), "bin", "ox-say"), nil) // no such file
		home, dir := homeEngine(t)
		check(t, home, dir)
	})

	t.Run("exe lookup error", func(t *testing.T) {
		pinExe(t, "", errors.New("no exe"))
		home, dir := homeEngine(t)
		check(t, home, dir)
	})

	t.Run("override wins", func(t *testing.T) {
		bins := map[string]string{
			"OX_SAY_ENGINE_BIN":  filepath.Join(t.TempDir(), "my-tts"),
			"OX_SAY_STT_BIN":     filepath.Join(t.TempDir(), "my-stt"),
			"OX_SAY_VOXCPM2_BIN": filepath.Join(t.TempDir(), "my-vox"),
		}
		exes := map[string]string{
			"bundle": func() string {
				root := t.TempDir()
				exe := filepath.Join(root, "OxSayDictation.app", "Contents", "Helpers", "ox-say")
				return writeFakeExe(t, exe)
			}(),
			"plain": writeFakeExe(t, filepath.Join(t.TempDir(), "bin", "ox-say")),
		}
		for layout, exe := range exes {
			pinExe(t, exe, nil)
			env := map[string]string{"OX_SAY_HOME": filepath.Join(t.TempDir(), "home")}
			maps.Copy(env, bins)
			c := loadEnv(t, env)
			if c.EngineBin != bins["OX_SAY_ENGINE_BIN"] ||
				c.STTBin != bins["OX_SAY_STT_BIN"] ||
				c.VoxCPM2Bin != bins["OX_SAY_VOXCPM2_BIN"] {
				t.Errorf("%s: overrides lost: %q %q %q", layout, c.EngineBin, c.STTBin, c.VoxCPM2Bin)
			}
		}
	})
}

// writeFakeExe creates an empty file at path (with parents) and returns it.
func writeFakeExe(t *testing.T, path string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// The notes engine says why it cannot run, in an order a UI can act on: too
// little memory (nothing helps), no engine (update), no model (download).
// Mutation: internal/config/config.go NotesBlock, swap the engine_missing and
// model_missing checks -> RED (a Mac without ox-llm is offered a 2.7 GB
// download that cannot help).
func TestNotesBlock(t *testing.T) {
	dir := t.TempDir()
	bin, model := filepath.Join(dir, "ox-llm"), filepath.Join(dir, NotesModelFile)
	c := &Config{NotesBin: bin, NotesModel: model, HostMemoryBytes: 16 * bytesPerGB}
	if code, _ := c.NotesBlock(); code != NotesReasonEngineMissing {
		t.Fatalf("no engine: code = %q", code)
	}
	if err := os.WriteFile(bin, []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if code, _ := c.NotesBlock(); code != NotesReasonModelMissing {
		t.Fatalf("no model: code = %q", code)
	}
	if err := os.WriteFile(model, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if code, reason := c.NotesBlock(); code != "" || reason != "" {
		t.Fatalf("ready: %q %q", code, reason)
	}
	c.HostMemoryBytes = 8 * bytesPerGB
	if code, _ := c.NotesBlock(); code != NotesReasonUnsupported {
		t.Fatalf("8 GB Mac: code = %q", code)
	}
	c.HostMemoryBytes = 0 // unknown memory never blocks
	if code, _ := c.NotesBlock(); code != "" {
		t.Fatalf("unknown memory: code = %q", code)
	}
}

// Mutation: internal/config/config.go loadNotes, drop one listener from
// `case c.EnginePort, c.STTPort, c.VoxCPM2Port, addrPort:` -> RED for that row.
func TestNotesPortCollisionIsRefused(t *testing.T) {
	for _, tc := range []struct{ env, val string }{
		{"OX_SAY_ENGINE_PORT", "19098"},
		{"OX_SAY_STT_PORT", "19098"},
		{"OX_SAY_VOXCPM2_PORT", "19098"},
		{"OX_SAY_ADDR", "127.0.0.1:19098"},
	} {
		t.Run(tc.env, func(t *testing.T) {
			t.Setenv("OX_SAY_HOME", t.TempDir())
			t.Setenv(tc.env, tc.val)
			t.Setenv("OX_SAY_NOTES_PORT", "19098")
			if _, err := Load(nil); err == nil || !strings.Contains(err.Error(), "OX_SAY_NOTES_PORT") {
				t.Fatalf("a notes port equal to %s: %v", tc.env, err)
			}
		})
	}
}

// The defaults the installer and the notes supervisor rely on: a wrong default
// binary name would read as "no notes engine" on every install, silently.
// Mutations: internal/config/config.go loadNotes, rename "ox-llm" in the
// default path -> RED; relax `if idle < 1` -> RED (a 0 s idle stop).
func TestNotesDefaultsAndIdleFloor(t *testing.T) {
	home := t.TempDir()
	t.Setenv("OX_SAY_HOME", home)
	c, err := Load(nil)
	if err != nil {
		t.Fatal(err)
	}
	if c.NotesBin != filepath.Join(home, "engine", "ox-llm") ||
		c.NotesModel != filepath.Join(home, "models", NotesModelFile) ||
		c.NotesPort != DefaultNotesPort || c.NotesIdleStop != DefaultNotesIdleStop*time.Second {
		t.Fatalf("notes defaults: %q %q %d %v", c.NotesBin, c.NotesModel, c.NotesPort, c.NotesIdleStop)
	}
	t.Setenv("OX_SAY_NOTES_IDLE_STOP_SECS", "0")
	if _, err := Load(nil); err == nil || !strings.Contains(err.Error(), "OX_SAY_NOTES_IDLE_STOP_SECS") {
		t.Fatalf("a 0 s notes idle stop: %v", err)
	}
}

// Only an EXPLICITLY set colliding OX_SAY_NOTES_PORT is a config error: a
// user who moved another engine to 8098 before notes existed must not lose
// the daemon to a feature behind a flag — the default collision blocks
// notes with a reason instead (#243).
// Mutations: internal/config/config.go loadNotes, drop the `rawPort != ""`
// distinction (always error) -> RED (Load fails); NotesBlock, drop the
// NotesPortBlocked check -> RED (code is engine_missing here, not
// port_blocked).
func TestDefaultNotesPortCollisionBlocksNotesOnly(t *testing.T) {
	for _, tc := range []struct{ env, val string }{
		{"OX_SAY_ENGINE_PORT", strconv.Itoa(DefaultNotesPort)},
		{"OX_SAY_STT_PORT", strconv.Itoa(DefaultNotesPort)},
		{"OX_SAY_VOXCPM2_PORT", strconv.Itoa(DefaultNotesPort)},
		{"OX_SAY_ADDR", "127.0.0.1:" + strconv.Itoa(DefaultNotesPort)},
	} {
		t.Run(tc.env, func(t *testing.T) {
			t.Setenv("OX_SAY_HOME", t.TempDir())
			t.Setenv(tc.env, tc.val)
			c, err := Load(nil)
			if err != nil {
				t.Fatalf("a default notes port colliding with %s must not fail load: %v", tc.env, err)
			}
			if !c.NotesPortBlocked {
				t.Fatal("the default collision was not recorded")
			}
			if code, _ := c.NotesBlock(); code != NotesReasonPortBlocked {
				t.Fatalf("NotesBlock = %q, want %q", code, NotesReasonPortBlocked)
			}
		})
	}
}

// The notes port's own range still holds for explicit and default values
// alike; the default-collision carve-out is no license to skip validation.
// Mutation: internal/config/config.go loadNotes, drop the
// `c.NotesPort < 1 || c.NotesPort > 65535` check -> RED.
func TestNotesPortRejectsBadValues(t *testing.T) {
	for _, v := range []string{"0", "-1", "65536", "abc"} {
		t.Setenv("OX_SAY_HOME", t.TempDir())
		t.Setenv("OX_SAY_NOTES_PORT", v)
		if _, err := Load(nil); err == nil || !strings.Contains(err.Error(), "OX_SAY_NOTES_PORT") {
			t.Fatalf("OX_SAY_NOTES_PORT=%q: %v", v, err)
		}
	}
}
