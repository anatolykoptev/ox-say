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
}

// flagNames maps flag names to env var names for ApplyFlags.
var flagNames = map[string]string{
	"home":            "OX_SAY_HOME",
	"addr":            "OX_SAY_ADDR",
	"engine-port":     "OX_SAY_ENGINE_PORT",
	"engine-bin":      "OX_SAY_ENGINE_BIN",
	"model":           "OX_SAY_MODEL",
	"codec":           "OX_SAY_CODEC",
	"max-batch":       "OX_SAY_MAX_BATCH",
	"idle-stop":       "OX_SAY_IDLE_STOP_SECS",
	"startup-timeout": "OX_SAY_STARTUP_TIMEOUT_SECS",
	"lang":            "OX_SAY_LANG",
	"engine-log-dir":  "OX_SAY_ENGINE_LOG_DIR",
	"cache-dir":       "OX_SAY_CACHE_DIR",
}

// RegisterFlags registers one flag per supported env var on fs. Values set on
// the command line override the environment in Load.
func RegisterFlags(fs *flag.FlagSet) {
	for name, env := range flagNames {
		fs.String(name, "", "override "+env)
	}
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

	c.Host, c.Port, err = splitLoopbackAddr(c.Addr)
	if err != nil {
		return nil, err
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
