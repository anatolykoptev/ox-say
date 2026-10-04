package config

import (
	"flag"
	"go/ast"
	"go/parser"
	"go/token"
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
		{"OX_SAY_STT_BIN", "/tmp/oxk-4917/ox-stt-x", "/tmp/oxk-4917/ox-stt-x", func(c *Config) string { return c.STTBin }},
		{"OX_SAY_STT_MODEL", "/tmp/oxk-4917/stt-x.bin", "/tmp/oxk-4917/stt-x.bin", func(c *Config) string { return c.STTModel }},
		{"OX_SAY_STT_WHISPER_MODEL", "/tmp/oxk-4917/whisper-x.bin", "/tmp/oxk-4917/whisper-x.bin", func(c *Config) string { return c.STTWhisperModel }},
		{"OX_SAY_STT_VAD_MODEL", "/tmp/oxk-4917/vad-x.bin", "/tmp/oxk-4917/vad-x.bin", func(c *Config) string { return c.STTVADModel }},
		{"OX_SAY_STT_GPU", "off", "off", func(c *Config) string { return c.STTGPU }},
		{"OX_SAY_STT_TIMEOUT_SECS", "63", "1m3s", func(c *Config) string { return c.STTTimeout.String() }},
		{"OX_SAY_STT_MAX_UPLOAD_MB", "64", "64", func(c *Config) string { return strconv.FormatInt(c.STTMaxUploadMB, 10) }},
		{"OX_SAY_STT_MAX_AUDIO_SECS", "65", "1m5s", func(c *Config) string { return c.STTMaxAudio.String() }},
		{"OX_SAY_STT_SERVER", "off", "off", func(c *Config) string { return c.STTServer }},
		{"OX_SAY_STT_PORT", "18096", "18096", func(c *Config) string { return strconv.Itoa(c.STTPort) }},
		{"OX_SAY_STT_IDLE_STOP_SECS", "66", "1m6s", func(c *Config) string { return c.STTIdleStop.String() }},
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
