// Package daemon wires the engine supervisor, voice store and HTTP/MCP
// surfaces together. HTTP handlers and MCP tools call the same methods here —
// the tools are a thin layer over the shared Go functions, never a loopback
// HTTP call.
package daemon

import (
	"context"
	"log/slog"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

// Daemon is the running service: engine supervisor + voice store + config.
type Daemon struct {
	Cfg   *config.Config
	Sup   *engine.Supervisor
	Store *voices.Store

	ec  *engine.Client
	log *slog.Logger
}

// New builds the supervisor (reaping any orphaned engine) and the voice
// store, and wires voice replay into engine startup.
func New(cfg *config.Config, logger *slog.Logger) (*Daemon, error) {
	return newDaemon(cfg, logger, nil)
}

// newDaemon is New plus an engine.Config tuning hook for tests.
func newDaemon(cfg *config.Config, logger *slog.Logger, tune func(*engine.Config)) (*Daemon, error) {
	if logger == nil {
		logger = slog.Default()
	}
	store, err := voices.New(cfg.VoicesDir())
	if err != nil {
		return nil, err
	}
	d := &Daemon{
		Cfg:   cfg,
		Store: store,
		ec:    engine.NewClient(),
		log:   logger,
	}
	ec := engine.Config{
		Bin:            cfg.EngineBin,
		Model:          cfg.Model,
		Codec:          cfg.Codec,
		Port:           cfg.EnginePort,
		MaxBatch:       cfg.MaxBatch,
		StartupTimeout: cfg.StartupTimeout,
		IdleStop:       cfg.IdleStop,
		LogDir:         cfg.EngineLogDir,
		PidPath:        cfg.PidPath(),
		Replay:         d.replayVoices,
		Logger:         logger,
	}
	if tune != nil {
		tune(&ec)
	}
	sup, err := engine.New(ec)
	if err != nil {
		return nil, err
	}
	d.Sup = sup
	return d, nil
}

// replayVoices re-registers every persisted voice into a freshly started
// child. Per-voice failures are logged and skipped — one corrupt clip must
// not keep the engine down.
func (d *Daemon) replayVoices(ctx context.Context, baseURL string) error {
	list, err := d.Store.List()
	if err != nil {
		return err
	}
	var firstErr error
	for _, v := range list {
		if err := d.ec.RegisterVoice(ctx, baseURL, v.Name, d.Store.WAVPath(v.Name), v.RefText); err != nil {
			d.log.Warn("voice replay failed",
				slog.String("voice", v.Name), slog.Any("error", err))
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	return firstErr
}

// engineBase acquires an in-flight guard and ensures the engine is ready.
// On failure the guard is released inside the helper; on success the caller
// owns g and must Release it when the request finishes.
func (d *Daemon) engineBase(ctx context.Context) (base string, g *engine.Guard, err error) {
	g = d.Sup.Acquire()
	base, err = d.Sup.EnsureReady(ctx)
	if err != nil {
		g.Release()
		return "", nil, err
	}
	return base, g, nil
}

// AddVoice persists a voice and registers it into the child when the engine
// is running. registered reports whether the live registration happened.
func (d *Daemon) AddVoice(ctx context.Context, name, audioPath, refText string) (v *voices.Voice, registered bool, err error) {
	v, err = d.Store.Add(name, audioPath, refText)
	if err != nil {
		return nil, false, err
	}
	// A live registration is engine work — hold a guard so the idle loop
	// cannot stop the child mid-request.
	g := d.Sup.Acquire()
	defer g.Release()
	if base, ok := d.Sup.ReadyURL(); ok {
		if rerr := d.ec.RegisterVoice(ctx, base, v.Name, d.Store.WAVPath(v.Name), v.RefText); rerr != nil {
			d.log.Warn("voice stored but engine registration failed; it will be replayed on next start",
				slog.String("voice", v.Name), slog.Any("error", rerr))
		} else {
			registered = true
		}
	}
	return v, registered, nil
}

// RemoveVoice deletes a voice from disk and, when the engine is running,
// from the child too.
func (d *Daemon) RemoveVoice(ctx context.Context, name string) error {
	if err := d.Store.Remove(name); err != nil {
		return err
	}
	g := d.Sup.Acquire()
	defer g.Release()
	if base, ok := d.Sup.ReadyURL(); ok {
		if err := d.ec.DeleteVoice(ctx, base, name); err != nil {
			d.log.Warn("engine voice delete failed", slog.String("voice", name), slog.Any("error", err))
		}
	}
	return nil
}

// applyLanguageDefault injects the configured default language when the
// request leaves it unset.
func (d *Daemon) applyLanguageDefault(body map[string]any) {
	if d.Cfg.Lang == "" {
		return
	}
	if l, ok := body["language"].(string); !ok || l == "" {
		body["language"] = d.Cfg.Lang
	}
}

// statusSummary is the /status response.
type statusSummary struct {
	Engine  engine.Status  `json:"engine"`
	Voices  []voices.Voice `json:"voices"`
	Config  map[string]any `json:"config"`
	Version string         `json:"version"`
}

var version = "dev"

// SetVersion stamps the daemon build version into /status.
func SetVersion(v string) { version = v }

// Status builds the /status payload.
func (d *Daemon) Status() statusSummary {
	list, err := d.Store.List()
	if err != nil {
		d.log.Warn("status: voice list failed", slog.Any("error", err))
	}
	return statusSummary{
		Engine: d.Sup.Status(),
		Voices: list,
		Config: map[string]any{
			"addr":              d.Cfg.Addr,
			"engine_port":       d.Cfg.EnginePort,
			"engine_bin":        d.Cfg.EngineBin,
			"model":             d.Cfg.Model,
			"codec":             d.Cfg.Codec,
			"max_batch":         d.Cfg.MaxBatch,
			"idle_stop_s":       d.Cfg.IdleStop.Seconds(),
			"startup_timeout_s": d.Cfg.StartupTimeout.Seconds(),
			"lang":              d.Cfg.Lang,
			"home":              d.Cfg.Home,
		},
		Version: version,
	}
}

// Shutdown stops the engine child.
func (d *Daemon) Shutdown() { d.Sup.Shutdown() }
