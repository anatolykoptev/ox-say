// Package config loads ox-say daemon configuration from OX_SAY_* environment
// variables with optional flag overrides.
package config

import (
	"flag"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"time"
)

// Defaults.
const (
	DefaultAddr           = "127.0.0.1:8094"
	DefaultEnginePort     = 8095
	DefaultMaxBatch       = 2
	DefaultIdleStopSecs   = 300
	DefaultStartupTimeout = 180
	DefaultSTTTimeout     = 600
	DefaultSTTMaxUploadMB = 200
	DefaultSTTMaxAudio    = 4 * 3600
	DefaultSTTPort        = 8096
	DefaultSTTIdleStop    = 600
	maxSTTUploadMB        = 1 << 20 // keeps MB<<20 far from int64 overflow
)

// Config is the resolved daemon configuration.
type Config struct {
	Home           string // OX_SAY_HOME: engine, models, voices, run dir
	Addr           string // OX_SAY_ADDR: daemon listen address (host:port, loopback only)
	Host           string // host part of Addr
	Port           string // port part of Addr
	EnginePort     int    // OX_SAY_ENGINE_PORT: loopback port the child binds
	EngineBin      string // OX_SAY_ENGINE_BIN: path to tts-server
	Model          string // OX_SAY_MODEL: talker GGUF
	Codec          string // OX_SAY_CODEC: tokenizer/codec GGUF
	MaxBatch       int    // OX_SAY_MAX_BATCH
	IdleStop       time.Duration
	StartupTimeout time.Duration
	Lang           string // OX_SAY_LANG: default language; empty = engine auto
	EngineLogDir   string // OX_SAY_ENGINE_LOG_DIR: child stdout/stderr log dir
	CacheDir       string // OX_SAY_CACHE_DIR: default output dir for speak

	STTBin          string        // OX_SAY_STT_BIN: path to ox-stt
	STTModel        string        // OX_SAY_STT_MODEL: parakeet weights
	STTWhisperModel string        // OX_SAY_STT_WHISPER_MODEL: whisper weights
	STTGPU          string        // OX_SAY_STT_GPU: auto | on | off
	STTTimeout      time.Duration // OX_SAY_STT_TIMEOUT_SECS
	STTMaxUploadMB  int64         // OX_SAY_STT_MAX_UPLOAD_MB
	STTMaxAudio     time.Duration // OX_SAY_STT_MAX_AUDIO_SECS: longer audio is cut
	STTServer       string        // OX_SAY_STT_SERVER: on | off — resident ox-stt server
	STTPort         int           // OX_SAY_STT_PORT: loopback port the STT server binds
	STTIdleStop     time.Duration // OX_SAY_STT_IDLE_STOP_SECS
}

// flagNames maps flag names to env var names for ApplyFlags.
var flagNames = map[string]string{
	"home":              "OX_SAY_HOME",
	"addr":              "OX_SAY_ADDR",
	"engine-port":       "OX_SAY_ENGINE_PORT",
	"engine-bin":        "OX_SAY_ENGINE_BIN",
	"model":             "OX_SAY_MODEL",
	"codec":             "OX_SAY_CODEC",
	"max-batch":         "OX_SAY_MAX_BATCH",
	"idle-stop":         "OX_SAY_IDLE_STOP_SECS",
	"startup-timeout":   "OX_SAY_STARTUP_TIMEOUT_SECS",
	"lang":              "OX_SAY_LANG",
	"engine-log-dir":    "OX_SAY_ENGINE_LOG_DIR",
	"cache-dir":         "OX_SAY_CACHE_DIR",
	"stt-bin":           "OX_SAY_STT_BIN",
	"stt-model":         "OX_SAY_STT_MODEL",
	"stt-whisper-model": "OX_SAY_STT_WHISPER_MODEL",
	"stt-gpu":           "OX_SAY_STT_GPU",
	"stt-timeout":       "OX_SAY_STT_TIMEOUT_SECS",
	"stt-max-upload":    "OX_SAY_STT_MAX_UPLOAD_MB",
	"stt-max-audio":     "OX_SAY_STT_MAX_AUDIO_SECS",
	"stt-server":        "OX_SAY_STT_SERVER",
	"stt-port":          "OX_SAY_STT_PORT",
	"stt-idle-stop":     "OX_SAY_STT_IDLE_STOP_SECS",
}

// RegisterFlags registers one flag per supported env var on fs. Values set on
// the command line override the environment in Load.
func RegisterFlags(fs *flag.FlagSet) {
	for name, env := range flagNames {
		fs.String(name, "", "override "+env)
	}
}

// EnvKeys returns the sorted set of OX_SAY_* variables the daemon reads — the
// one table the loader draws on. `ox-say env-keys` prints them for
// the installers, which write exactly these into the LaunchAgent (and carry
// over exactly these on re-install), so a variable the daemon does not read —
// an installer knob like OX_SAY_BINDIR — cannot leak into the agent's
// environment.
func EnvKeys() []string {
	keys := make([]string, 0, len(flagNames))
	for _, env := range flagNames {
		keys = append(keys, env)
	}
	sort.Strings(keys)
	return keys
}

// Load reads configuration from the environment, then applies any flags that
// were explicitly set on fs (see RegisterFlags). It refuses a non-loopback
// listen address: the API has no auth and must never bind a LAN interface.
func Load(fs *flag.FlagSet) (*Config, error) {
	overrides := map[string]string{}
	if fs != nil {
		fs.Visit(func(f *flag.Flag) {
			overrides[flagNames[f.Name]] = f.Value.String()
		})
	}
	return load(os.Getenv, overrides)
}

func load(getenv func(string) string, overrides map[string]string) (*Config, error) {
	get := func(key string) string {
		if v, ok := overrides[key]; ok {
			return v
		}
		return getenv(key)
	}

	homeDir, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("config: user home dir: %w", err)
	}

	c := &Config{
		Home:         get("OX_SAY_HOME"),
		Addr:         orDefault(get("OX_SAY_ADDR"), DefaultAddr),
		EngineLogDir: orDefault(get("OX_SAY_ENGINE_LOG_DIR"), filepath.Join(homeDir, "Library", "Logs", "ox-say")),
		CacheDir:     orDefault(get("OX_SAY_CACHE_DIR"), filepath.Join(homeDir, "Library", "Caches", "ox-say")),
		Lang:         get("OX_SAY_LANG"),
	}
	if c.Home == "" {
		c.Home = filepath.Join(homeDir, "Library", "Application Support", "ox-say")
	}

	if c.EngineBin = get("OX_SAY_ENGINE_BIN"); c.EngineBin == "" {
		c.EngineBin = filepath.Join(c.Home, "engine", "tts-server")
	}
	if c.Model = get("OX_SAY_MODEL"); c.Model == "" {
		c.Model = filepath.Join(c.Home, "models", "qwen-talker-0.6b-base-Q8_0.gguf")
	}
	if c.Codec = get("OX_SAY_CODEC"); c.Codec == "" {
		c.Codec = filepath.Join(c.Home, "models", "qwen-tokenizer-12hz-F32.gguf")
	}

	if c.EnginePort, err = intVar(get("OX_SAY_ENGINE_PORT"), DefaultEnginePort); err != nil {
		return nil, fmt.Errorf("config: OX_SAY_ENGINE_PORT: %w", err)
	}
	if c.MaxBatch, err = intVar(get("OX_SAY_MAX_BATCH"), DefaultMaxBatch); err != nil {
		return nil, fmt.Errorf("config: OX_SAY_MAX_BATCH: %w", err)
	}
	idleSecs, err := intVar(get("OX_SAY_IDLE_STOP_SECS"), DefaultIdleStopSecs)
	if err != nil {
		return nil, fmt.Errorf("config: OX_SAY_IDLE_STOP_SECS: %w", err)
	}
	c.IdleStop = time.Duration(idleSecs) * time.Second
	startSecs, err := intVar(get("OX_SAY_STARTUP_TIMEOUT_SECS"), DefaultStartupTimeout)
	if err != nil {
		return nil, fmt.Errorf("config: OX_SAY_STARTUP_TIMEOUT_SECS: %w", err)
	}
	c.StartupTimeout = time.Duration(startSecs) * time.Second

	if c.STTBin = get("OX_SAY_STT_BIN"); c.STTBin == "" {
		c.STTBin = filepath.Join(c.Home, "engine", "ox-stt")
	}
	if c.STTModel = get("OX_SAY_STT_MODEL"); c.STTModel == "" {
		c.STTModel = filepath.Join(c.Home, "models", "ggml-parakeet-tdt-0.6b-v3-f16.bin")
	}
	if c.STTWhisperModel = get("OX_SAY_STT_WHISPER_MODEL"); c.STTWhisperModel == "" {
		c.STTWhisperModel = filepath.Join(c.Home, "models", "ggml-large-v3-turbo.bin")
	}
	c.STTGPU = orDefault(get("OX_SAY_STT_GPU"), "auto")
	switch c.STTGPU {
	case "auto", "on", "off":
	default:
		return nil, fmt.Errorf("config: OX_SAY_STT_GPU %q: want auto|on|off", c.STTGPU)
	}
	sttSecs, err := intVar(get("OX_SAY_STT_TIMEOUT_SECS"), DefaultSTTTimeout)
	if err != nil {
		return nil, fmt.Errorf("config: OX_SAY_STT_TIMEOUT_SECS: %w", err)
	}
	if sttSecs < 1 {
		return nil, fmt.Errorf("config: OX_SAY_STT_TIMEOUT_SECS %d: want >= 1", sttSecs)
	}
	c.STTTimeout = time.Duration(sttSecs) * time.Second
	if c.STTMaxUploadMB, err = int64Var(get("OX_SAY_STT_MAX_UPLOAD_MB"), DefaultSTTMaxUploadMB); err != nil {
		return nil, fmt.Errorf("config: OX_SAY_STT_MAX_UPLOAD_MB: %w", err)
	}
	if c.STTMaxUploadMB < 1 || c.STTMaxUploadMB > maxSTTUploadMB {
		return nil, fmt.Errorf("config: OX_SAY_STT_MAX_UPLOAD_MB %d: want 1..%d", c.STTMaxUploadMB, maxSTTUploadMB)
	}
	audioSecs, err := intVar(get("OX_SAY_STT_MAX_AUDIO_SECS"), DefaultSTTMaxAudio)
	if err != nil {
		return nil, fmt.Errorf("config: OX_SAY_STT_MAX_AUDIO_SECS: %w", err)
	}
	if audioSecs < 1 {
		return nil, fmt.Errorf("config: OX_SAY_STT_MAX_AUDIO_SECS %d: want >= 1", audioSecs)
	}
	c.STTMaxAudio = time.Duration(audioSecs) * time.Second

	c.STTServer = orDefault(get("OX_SAY_STT_SERVER"), "on")
	switch c.STTServer {
	case "on", "off":
	default:
		return nil, fmt.Errorf("config: OX_SAY_STT_SERVER %q: want on|off", c.STTServer)
	}
	if c.STTPort, err = intVar(get("OX_SAY_STT_PORT"), DefaultSTTPort); err != nil {
		return nil, fmt.Errorf("config: OX_SAY_STT_PORT: %w", err)
	}
	if c.STTPort < 1 || c.STTPort > 65535 {
		return nil, fmt.Errorf("config: OX_SAY_STT_PORT %d: want 1..65535", c.STTPort)
	}
	sttIdleSecs, err := intVar(get("OX_SAY_STT_IDLE_STOP_SECS"), DefaultSTTIdleStop)
	if err != nil {
		return nil, fmt.Errorf("config: OX_SAY_STT_IDLE_STOP_SECS: %w", err)
	}
	if sttIdleSecs < 1 {
		return nil, fmt.Errorf("config: OX_SAY_STT_IDLE_STOP_SECS %d: want >= 1", sttIdleSecs)
	}
	c.STTIdleStop = time.Duration(sttIdleSecs) * time.Second

	c.Host, c.Port, err = splitLoopbackAddr(c.Addr)
	if err != nil {
		return nil, err
	}
	// The STT server binds its own loopback port; a collision with either
	// of the other two listeners is a config error, not a bind-time one.
	if c.STTPort == c.EnginePort {
		return nil, fmt.Errorf("config: OX_SAY_STT_PORT %d collides with OX_SAY_ENGINE_PORT", c.STTPort)
	}
	if p, perr := strconv.Atoi(c.Port); perr == nil && c.STTPort == p {
		return nil, fmt.Errorf("config: OX_SAY_STT_PORT %d collides with OX_SAY_ADDR", c.STTPort)
	}
	return c, nil
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

func intVar(v string, def int) (int, error) {
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("invalid integer %q", v)
	}
	return n, nil
}

func int64Var(v string, def int64) (int64, error) {
	if v == "" {
		return def, nil
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid integer %q", v)
	}
	return n, nil
}

// splitLoopbackAddr splits host:port and refuses anything that is not a
// loopback address. The daemon has no authentication; binding a public
// interface would expose TTS and voice registration to the network.
func splitLoopbackAddr(addr string) (host, port string, err error) {
	host, port, err = net.SplitHostPort(addr)
	if err != nil {
		return "", "", fmt.Errorf("config: OX_SAY_ADDR %q: %w", addr, err)
	}
	if host == "" {
		return "", "", fmt.Errorf("config: OX_SAY_ADDR %q: empty host binds all interfaces; use a loopback address", addr)
	}
	if ip, perr := netip.ParseAddr(host); perr == nil {
		if !ip.IsLoopback() {
			return "", "", fmt.Errorf("config: OX_SAY_ADDR %q: %s is not a loopback address", addr, host)
		}
		return host, port, nil
	}
	// Hostname form (e.g. "localhost"): every resolved address must be loopback.
	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		return "", "", fmt.Errorf("config: OX_SAY_ADDR %q: cannot resolve host %q", addr, host)
	}
	for _, ip := range ips {
		if !ip.IsLoopback() {
			return "", "", fmt.Errorf("config: OX_SAY_ADDR %q: %s resolves to non-loopback %s", addr, host, ip)
		}
	}
	return host, port, nil
}

// VoicesDir is where voice clips and metadata are persisted.
func (c *Config) VoicesDir() string { return filepath.Join(c.Home, "voices") }

// RunDir holds runtime state (the engine pidfile).
func (c *Config) RunDir() string { return filepath.Join(c.Home, "run") }

// PidPath is the child pidfile.
func (c *Config) PidPath() string { return filepath.Join(c.RunDir(), "engine.pid") }
