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
	"runtime"
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
	DefaultVoxCPM2Port    = 8097
	maxSTTUploadMB        = 1 << 20 // keeps MB<<20 far from int64 overflow
	// maxSTTSecs caps the STT timeout base and the audio length: the engine
	// deadline is base + k×duration, and the MCP tool timeout doubles it, so
	// an unbounded value overflows time.Duration into a negative deadline
	// that times every transcription out at once.
	maxSTTSecs = 24 * 3600
)

// TTS models a speech request can name (OX_SAY_TTS_MODEL, the request's model).
const (
	TTSModelQwen    = "qwen3-tts"
	TTSModelVoxCPM2 = "voxcpm2"
)

// DefaultProduceOutDir is where finished voiceovers land, relative to the
// user's home (plan QF5: provisional, pending the owner's confirmation).
const DefaultProduceOutDir = "Movies/ox-say"

// VoxCPM2ModelFile is the one model filename fetch-models.sh and the default
// path share (the Q8_0 variant, chosen in the engine gate).
const VoxCPM2ModelFile = "voxcpm2-q8_0.gguf"

// VoxCPM2MinMemoryGB is the smallest Mac the quality engine is offered on: a
// 16 GB Mac is unmeasured and Metal wires at most about 2/3 of RAM.
const VoxCPM2MinMemoryGB = 24

const bytesPerGB = 1 << 30

// GPU memory models (OX_SAY_GPU_MEMORY). auto is resolved at load, so a
// loaded Config holds unified or discrete.
const (
	GPUMemoryAuto     = "auto"
	GPUMemoryUnified  = "unified"
	GPUMemoryDiscrete = "discrete"
)

// hostUnifiedMemory reports whether this machine's GPU shares system memory:
// every darwin/arm64 Mac is Apple Silicon. Intel Macs — and the linux CI
// host — keep the discrete-card behaviour. A variable so tests can pin
// either answer on any host.
var hostUnifiedMemory = func() bool { return runtime.GOOS == "darwin" && runtime.GOARCH == "arm64" }

// daemonExe is os.Executable behind a variable so tests can pin the daemon's
// own path — the installer's bin/ox-say symlink or a plain file — without a
// real binary to exec. See defaultEngineDir.
var daemonExe = os.Executable

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
	Voice          string // OX_SAY_VOICE: default cloned voice; empty = engine random
	VoiceRU        string // OX_SAY_VOICE_RU: default for Russian speech; empty = Voice
	VoiceEN        string // OX_SAY_VOICE_EN: default for English speech; empty = Voice
	EngineLogDir   string // OX_SAY_ENGINE_LOG_DIR: child stdout/stderr log dir
	CacheDir       string // OX_SAY_CACHE_DIR: default output dir for speak
	// ProduceOutDir is OX_SAY_PRODUCE_OUT_DIR: where `produce` publishes a
	// finished voiceover when the request names no out_path. The default
	// (DefaultProduceOutDir under the user's home) is the owner's provisional
	// answer to plan question QF5 and a two-way door: this is its one place.
	ProduceOutDir string

	STTBin          string        // OX_SAY_STT_BIN: path to ox-stt
	STTModel        string        // OX_SAY_STT_MODEL: parakeet weights
	STTVADModel     string        // OX_SAY_STT_VAD_MODEL: silero VAD model enabling streaming sessions
	STTWhisperModel string        // OX_SAY_STT_WHISPER_MODEL: whisper weights
	STTGPU          string        // OX_SAY_STT_GPU: auto | on | off
	STTTimeout      time.Duration // OX_SAY_STT_TIMEOUT_SECS: fixed allowance; the engine's budget adds k×audio duration on top
	STTMaxUploadMB  int64         // OX_SAY_STT_MAX_UPLOAD_MB
	STTMaxAudio     time.Duration // OX_SAY_STT_MAX_AUDIO_SECS: longer audio is refused (400), not cut
	STTServer       string        // OX_SAY_STT_SERVER: on | off — resident ox-stt server
	STTPort         int           // OX_SAY_STT_PORT: loopback port the STT server binds
	STTIdleStop     time.Duration // OX_SAY_STT_IDLE_STOP_SECS

	// GPUMemory is OX_SAY_GPU_MEMORY resolved by load: GPUMemoryUnified
	// (Apple Silicon: TTS and STT share the GPU, no lease) or
	// GPUMemoryDiscrete (a 4 GB card: the lease and the CPU-only resident
	// STT server, issue #11). A Config literal leaves it "", which is
	// discrete.
	GPUMemory string

	VoxCPM2Bin   string // OX_SAY_VOXCPM2_BIN: path to audiocpp_server
	VoxCPM2Model string // OX_SAY_VOXCPM2_MODEL: VoxCPM2 GGUF
	VoxCPM2Port  int    // OX_SAY_VOXCPM2_PORT: loopback port the child binds
	TTSModel     string // OX_SAY_TTS_MODEL: default model of a speech request
	// HostMemoryBytes is the installed RAM read by load; 0 (a Config literal,
	// or an unreadable host) means unknown and never blocks VoxCPM2.
	HostMemoryBytes uint64
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
	"voice":             "OX_SAY_VOICE",
	"voice-ru":          "OX_SAY_VOICE_RU",
	"voice-en":          "OX_SAY_VOICE_EN",
	"engine-log-dir":    "OX_SAY_ENGINE_LOG_DIR",
	"cache-dir":         "OX_SAY_CACHE_DIR",
	"produce-out-dir":   "OX_SAY_PRODUCE_OUT_DIR",
	"stt-bin":           "OX_SAY_STT_BIN",
	"stt-model":         "OX_SAY_STT_MODEL",
	"stt-vad-model":     "OX_SAY_STT_VAD_MODEL",
	"stt-whisper-model": "OX_SAY_STT_WHISPER_MODEL",
	"stt-gpu":           "OX_SAY_STT_GPU",
	"stt-timeout":       "OX_SAY_STT_TIMEOUT_SECS",
	"stt-max-upload":    "OX_SAY_STT_MAX_UPLOAD_MB",
	"stt-max-audio":     "OX_SAY_STT_MAX_AUDIO_SECS",
	"stt-server":        "OX_SAY_STT_SERVER",
	"stt-port":          "OX_SAY_STT_PORT",
	"stt-idle-stop":     "OX_SAY_STT_IDLE_STOP_SECS",
	"gpu-memory":        "OX_SAY_GPU_MEMORY",
	"voxcpm2-bin":       "OX_SAY_VOXCPM2_BIN",
	"voxcpm2-model":     "OX_SAY_VOXCPM2_MODEL",
	"voxcpm2-port":      "OX_SAY_VOXCPM2_PORT",
	"tts-model":         "OX_SAY_TTS_MODEL",
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
		Home:          get("OX_SAY_HOME"),
		Addr:          orDefault(get("OX_SAY_ADDR"), DefaultAddr),
		EngineLogDir:  orDefault(get("OX_SAY_ENGINE_LOG_DIR"), filepath.Join(homeDir, "Library", "Logs", "ox-say")),
		CacheDir:      orDefault(get("OX_SAY_CACHE_DIR"), filepath.Join(homeDir, "Library", "Caches", "ox-say")),
		ProduceOutDir: orDefault(get("OX_SAY_PRODUCE_OUT_DIR"), filepath.Join(homeDir, DefaultProduceOutDir)),
		Lang:          get("OX_SAY_LANG"),
		Voice:         get("OX_SAY_VOICE"),
		VoiceRU:       get("OX_SAY_VOICE_RU"),
		VoiceEN:       get("OX_SAY_VOICE_EN"),
	}
	if c.Home == "" {
		c.Home = filepath.Join(homeDir, "Library", "Application Support", "ox-say")
	}
	engineDir := defaultEngineDir(c.Home)

	if c.EngineBin = get("OX_SAY_ENGINE_BIN"); c.EngineBin == "" {
		c.EngineBin = filepath.Join(engineDir, "tts-server")
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
		c.STTBin = filepath.Join(engineDir, "ox-stt")
	}
	if c.STTModel = get("OX_SAY_STT_MODEL"); c.STTModel == "" {
		c.STTModel = filepath.Join(c.Home, "models", "ggml-parakeet-tdt-0.6b-v3-q8_0.bin")
	}
	if c.STTVADModel = get("OX_SAY_STT_VAD_MODEL"); c.STTVADModel == "" {
		c.STTVADModel = filepath.Join(c.Home, "models", "ggml-silero-v5.1.2.bin")
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
	if c.GPUMemory, err = resolveGPUMemory(get("OX_SAY_GPU_MEMORY")); err != nil {
		return nil, err
	}
	sttSecs, err := intVar(get("OX_SAY_STT_TIMEOUT_SECS"), DefaultSTTTimeout)
	if err != nil {
		return nil, fmt.Errorf("config: OX_SAY_STT_TIMEOUT_SECS: %w", err)
	}
	if sttSecs < 1 || sttSecs > maxSTTSecs {
		return nil, fmt.Errorf("config: OX_SAY_STT_TIMEOUT_SECS %d: want 1..%d", sttSecs, maxSTTSecs)
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
	if audioSecs < 1 || audioSecs > maxSTTSecs {
		return nil, fmt.Errorf("config: OX_SAY_STT_MAX_AUDIO_SECS %d: want 1..%d", audioSecs, maxSTTSecs)
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
	if err := loadVoxCPM2(c, get, engineDir); err != nil {
		return nil, err
	}
	return c, nil
}

// loadVoxCPM2 reads the quality-engine keys and the default TTS model. It
// runs after the other ports are parsed: its port must collide with none.
func loadVoxCPM2(c *Config, get func(string) string, engineDir string) error {
	if c.VoxCPM2Bin = get("OX_SAY_VOXCPM2_BIN"); c.VoxCPM2Bin == "" {
		c.VoxCPM2Bin = filepath.Join(engineDir, "audiocpp_server")
	}
	if c.VoxCPM2Model = get("OX_SAY_VOXCPM2_MODEL"); c.VoxCPM2Model == "" {
		c.VoxCPM2Model = filepath.Join(c.Home, "models", VoxCPM2ModelFile)
	}
	var err error
	if c.VoxCPM2Port, err = intVar(get("OX_SAY_VOXCPM2_PORT"), DefaultVoxCPM2Port); err != nil {
		return fmt.Errorf("config: OX_SAY_VOXCPM2_PORT: %w", err)
	}
	if c.VoxCPM2Port < 1 || c.VoxCPM2Port > 65535 {
		return fmt.Errorf("config: OX_SAY_VOXCPM2_PORT %d: want 1..65535", c.VoxCPM2Port)
	}
	addrPort, _ := strconv.Atoi(c.Port)
	switch c.VoxCPM2Port {
	case c.EnginePort, c.STTPort, addrPort:
		return fmt.Errorf("config: OX_SAY_VOXCPM2_PORT %d collides with another ox-say listener", c.VoxCPM2Port)
	}
	c.TTSModel = orDefault(get("OX_SAY_TTS_MODEL"), TTSModelQwen)
	if c.TTSModel != TTSModelQwen && c.TTSModel != TTSModelVoxCPM2 {
		return fmt.Errorf("config: OX_SAY_TTS_MODEL %q: want %s|%s", c.TTSModel, TTSModelQwen, TTSModelVoxCPM2)
	}
	c.HostMemoryBytes = hostMemoryBytes()
	return nil
}

// Codes for why VoxCPM2 is unavailable, for a UI that must tell "an install
// would fix this" from "this Mac cannot run it".
const (
	// VoxReasonUnsupported: the hardware cannot run it (no Apple Silicon, too
	// little memory). No install helps.
	VoxReasonUnsupported = "unsupported"
	// VoxReasonModelMissing: the engine or its model is not on disk. The
	// installer with OX_SAY_WITH_VOXCPM2=1 adds both.
	VoxReasonModelMissing = "model_missing"
)

// VoxCPM2Unavailable reports, in plain words for a UI, why the VoxCPM2 engine
// cannot serve on this host, or "" when it can.
func (c *Config) VoxCPM2Unavailable() string {
	_, reason := c.VoxCPM2Block()
	return reason
}

// VoxCPM2Block is VoxCPM2Unavailable with a machine-readable code
// (VoxReasonUnsupported or VoxReasonModelMissing); both are "" when it can
// serve. The model file — not the binary alone — enables it: a release install
// on arm64 carries the binary without the 3 GB model. Files are stat'ed per
// call, so a model fetched later works without a daemon restart.
func (c *Config) VoxCPM2Block() (code, reason string) {
	if !c.UnifiedMemory() {
		return VoxReasonUnsupported, "Studio voices (VoxCPM2) need a Mac with Apple Silicon; this computer cannot run them."
	}
	if c.HostMemoryBytes != 0 && c.HostMemoryBytes < VoxCPM2MinMemoryGB*bytesPerGB {
		return VoxReasonUnsupported, fmt.Sprintf("Studio voices (VoxCPM2) need at least %d GB of memory; this Mac has %d GB.",
			VoxCPM2MinMemoryGB, c.HostMemoryBytes/bytesPerGB)
	}
	if !isRegularFile(c.VoxCPM2Bin) {
		return VoxReasonModelMissing, "The studio voice engine is not installed. Reinstall ox-say with OX_SAY_WITH_VOXCPM2=1."
	}
	if !isRegularFile(c.VoxCPM2Model) {
		return VoxReasonModelMissing, "The studio voice model is not downloaded yet. Run the installer with OX_SAY_WITH_VOXCPM2=1 to add it."
	}
	return "", ""
}

func isRegularFile(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.Mode().IsRegular()
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

// defaultEngineDir is where the engine binaries default to. When the daemon's
// own executable resolves into <X>.app/Contents/Helpers — the launchd agent
// runs bin/ox-say, a symlink into the bundle — the engines travel with the
// daemon, so the dir is the resolved executable's own (the one-version plan,
// 2026-10-15: one bundle is the versioned unit). Everywhere else it stays
// <home>/engine, the only layout in production today. A failed exe lookup or
// EvalSymlinks falls back to <home>/engine: the daemon must still start.
func defaultEngineDir(home string) string {
	fallback := filepath.Join(home, "engine")
	exe, err := daemonExe()
	if err != nil {
		return fallback
	}
	resolved, err := filepath.EvalSymlinks(exe)
	if err != nil {
		return fallback
	}
	if dir := filepath.Dir(resolved); isBundleHelpersDir(dir) {
		return dir
	}
	return fallback
}

// isBundleHelpersDir reports whether dir is <X>.app/Contents/Helpers.
func isBundleHelpersDir(dir string) bool {
	if filepath.Base(dir) != "Helpers" {
		return false
	}
	if filepath.Base(filepath.Dir(dir)) != "Contents" {
		return false
	}
	return filepath.Ext(filepath.Base(filepath.Dir(filepath.Dir(dir)))) == ".app"
}

// resolveGPUMemory validates OX_SAY_GPU_MEMORY and resolves auto (the
// default) against the host.
func resolveGPUMemory(v string) (string, error) {
	switch orDefault(v, GPUMemoryAuto) {
	case GPUMemoryAuto:
		if hostUnifiedMemory() {
			return GPUMemoryUnified, nil
		}
		return GPUMemoryDiscrete, nil
	case GPUMemoryUnified:
		return GPUMemoryUnified, nil
	case GPUMemoryDiscrete:
		return GPUMemoryDiscrete, nil
	}
	return "", fmt.Errorf("config: OX_SAY_GPU_MEMORY %q: want auto|unified|discrete", v)
}

// UnifiedMemory reports whether the GPU shares system memory with the CPU
// (Apple Silicon): the TTS engine and the resident STT server then run on
// the GPU side by side and no GPU lease is taken. Anything else — the zero
// value included — keeps the discrete-card arbitration (issue #11).
func (c *Config) UnifiedMemory() bool { return c.GPUMemory == GPUMemoryUnified }

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
