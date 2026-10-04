// Package daemon wires the engine supervisor, voice store and HTTP/MCP
// surfaces together. HTTP handlers and MCP tools call the same methods here —
// the tools are a thin layer over the shared Go functions, never a loopback
// HTTP call.
package daemon

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

// Daemon is the running service: engine supervisor + voice store + config.
type Daemon struct {
	Cfg   *config.Config
	Sup   *engine.Supervisor
	Store *voices.Store

	// STTSup supervises the resident `ox-stt --serve` child; nil when
	// OX_SAY_STT_SERVER=off. It always decodes on the CPU (-ng): a resident
	// process holding GPU memory for its whole life cannot share the card
	// through a per-run lease, so it never takes d.gpu and never contends
	// with the TTS engine's GPU.
	STTSup *engine.Supervisor

	ec  *engine.Client
	log *slog.Logger

	// gpu is the single-token GPU lease shared by the TTS engine (held
	// from a start's spawn to the child's observed exit) and by a per-call
	// ox-stt run that goes without -ng (issue #11).
	gpu *engine.GPULease

	// voiceMu serializes voice mutations against engine-start replay: a
	// voice written while replayVoices runs could otherwise be missing
	// from both the store snapshot and the live child.
	voiceMu sync.Mutex

	// replayAfterSnapshot, when set (tests only), runs inside replayVoices
	// after the store snapshot, with voiceMu held.
	replayAfterSnapshot func()

	// slowPrepare, when set (tests only), runs inside AddVoice just before
	// Store.Prepare — a stand-in for a slow ffmpeg normalization, so a test
	// can hold the prepare phase open while the idle deadline passes.
	slowPrepare func()

	// lockFile holds daemon.lock for the process lifetime.
	lockFile *os.File
}

// New builds the supervisor (reaping any orphaned engine) and the voice
// store, and wires voice replay into engine startup.
func New(cfg *config.Config, logger *slog.Logger) (*Daemon, error) {
	return newDaemon(cfg, logger, nil, nil)
}

// sttStartupTimeout bounds the resident STT server's start budget. Passing
// cfg.StartupTimeout outright would hand it the TTS budget (180 s), which
// exists for the tts-server's first-start Metal shader compile: a hung STT
// start would pin a transcription for all of it. An honest `ox-stt --serve`
// start is ~2–3 s, and even a cold start of a NEW ox-stt binary spends
// ~47 s compiling Metal libraries despite -ng (issue #37) — 90 s covers
// that plus model load.
func sttStartupTimeout(d time.Duration) time.Duration {
	const limit = 90 * time.Second
	if d <= 0 {
		// engine.New turns a non-positive timeout into its 180 s default,
		// which would bypass the cap.
		return limit
	}
	return min(d, limit)
}

// newDaemon is New plus engine.Config tuning hooks for tests — tune for
// the TTS supervisor, tuneSTT for the STT server's.
func newDaemon(cfg *config.Config, logger *slog.Logger, tune, tuneSTT func(*engine.Config)) (*Daemon, error) {
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
		gpu:   engine.NewGPULease(),
	}
	// Single-instance lock: taken BEFORE the supervisor reaps orphaned
	// engines so a second daemon on the same home cannot kill the first
	// one's live engine before failing to bind.
	lockF, err := lockHome(cfg)
	if err != nil {
		return nil, err
	}
	d.lockFile = lockF
	if err := store.SweepTemp(); err != nil {
		logger.Warn("voices: cannot remove normalization leftovers", slog.Any("error", err))
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
		// The TTS engine owns the GPU while its child lives: a start waits
		// out a GPU transcription, and the lease is released at the child's
		// observed exit — past the Stopped commit (issue #11).
		GPU: d.gpu,
	}
	if tune != nil {
		tune(&ec)
	}
	sup, err := engine.New(ec)
	if err != nil {
		_ = lockF.Close()
		return nil, err
	}
	d.Sup = sup
	if cfg.STTServer == "on" {
		sc := engine.Config{
			Name:           "stt",
			Bin:            cfg.STTBin,
			Port:           cfg.STTPort,
			StartupTimeout: sttStartupTimeout(cfg.StartupTimeout),
			IdleStop:       cfg.STTIdleStop,
			LogName:        "stt.log",
			LogDir:         cfg.EngineLogDir,
			PidPath:        filepath.Join(cfg.RunDir(), "stt.pid"),
			Logger:         logger,
			// The resident server loads the parakeet model once and decodes
			// on the CPU — unconditionally: a child that would hold GPU
			// memory for its whole lifetime cannot take part in the per-run
			// GPU lease (a speak would have to wait out its idle timeout),
			// so OX_SAY_STT_GPU=on scopes to the per-call CLI only.
			Args: func(port int) []string {
				args := []string{"--serve", "--port", strconv.Itoa(port), "-m", cfg.STTModel, "-ng"}
				// Streaming sessions need the silero VAD model; without the
				// file the server spawns exactly as before and the session
				// routes answer 501. The stat runs per spawn (Args is
				// evaluated at every start), so dropping the model in later
				// enables sessions without a daemon restart.
				if _, err := os.Stat(cfg.STTVADModel); err == nil {
					args = append(args, "--vad", cfg.STTVADModel)
				}
				return args
			},
		}
		if tuneSTT != nil {
			tuneSTT(&sc)
		}
		ssup, err := engine.New(sc)
		if err != nil {
			sup.Shutdown()
			_ = lockF.Close()
			return nil, err
		}
		d.STTSup = ssup
	}
	return d, nil
}

// lockHome takes the exclusive daemon.lock under the home's run dir and
// keeps the file open for the process lifetime; a second daemon on the
// same home fails fast instead of reaping the first one's engine.
func lockHome(cfg *config.Config) (*os.File, error) {
	if err := os.MkdirAll(cfg.RunDir(), 0o755); err != nil {
		return nil, fmt.Errorf("ox-say: run dir: %w", err)
	}
	lockPath := filepath.Join(cfg.RunDir(), "daemon.lock")
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fmt.Errorf("ox-say: daemon lock: %w", err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("ox-say: another daemon is already running for home %s", cfg.Home)
	}
	return f, nil
}

// replayVoices re-registers every persisted voice into a freshly started
// child. Per-voice failures are logged and skipped — one corrupt clip must
// not keep the engine down. Held under voiceMu: the store snapshot must not
// race an Add/Remove that could then also miss the live registration.
func (d *Daemon) replayVoices(ctx context.Context, baseURL string) error {
	d.voiceMu.Lock()
	defer d.voiceMu.Unlock()
	list, err := d.Store.List()
	if err != nil {
		return err
	}
	if d.replayAfterSnapshot != nil {
		d.replayAfterSnapshot()
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

// sttServer is the Options.Server closure for the resident ox-stt server —
// same acquire-then-ready shape as engineBase, but the release func travels
// with the URL so stt can drop the guard once the response body is read.
func (d *Daemon) sttServer(ctx context.Context) (base string, release func(), err error) {
	// A server cooling down after a crash or a failed start would make this
	// caller sleep out the rest of the restart backoff inside EnsureReady —
	// under stt's serialization sem, so every queued dictation would pay it
	// too. The CLI fallback is cheaper; the first request past the window
	// still launches the next start attempt, so recovery is automatic.
	if b := d.STTSup.Backoff(); b > 0 {
		return "", nil, fmt.Errorf("stt server cooling down (%s)", b)
	}
	g := d.STTSup.Acquire()
	base, err = d.STTSup.EnsureReady(ctx)
	if err != nil {
		g.Release()
		return "", nil, err
	}
	return base, g.Release, nil
}

// AddVoice persists a voice and registers it into the child when the engine
// is running. registered reports whether the live registration happened.
// Input validation runs before the guard: a request Prepare will refuse
// must not re-stamp lastActivity through Release and push a Ready engine's
// idle stop back. The engine guard is then taken before the ffmpeg
// normalization and held across the whole call: a slow Prepare (up to 60 s)
// must not let the idle loop stop the child the voice is about to be
// registered into — that window otherwise ends in registered=false for a
// voice the next start's replay would register, or in a registration into
// a child already marked Stopped.
// Prepare still runs outside voiceMu (it must not hold up an engine
// start's replay); the commit and the live registration run under voiceMu
// so a concurrent replay cannot interleave between them.
func (d *Daemon) AddVoice(ctx context.Context, name, audioPath, refText string) (v *voices.Voice, registered bool, err error) {
	if err := d.Store.ValidateInput(name, audioPath); err != nil {
		return nil, false, err
	}
	g := d.Sup.Acquire()
	defer g.Release()
	if d.slowPrepare != nil {
		d.slowPrepare()
	}
	pending, err := d.Store.Prepare(ctx, name, audioPath, refText)
	if err != nil {
		return nil, false, err
	}
	defer pending.Discard()
	d.voiceMu.Lock()
	defer d.voiceMu.Unlock()
	v, err = pending.Commit()
	if err != nil {
		return nil, false, err
	}
	// A live registration is engine work — the guard above keeps the idle
	// loop from stopping the child mid-request. LiveURL also reaches a
	// child that is past /health but still inside its start attempt
	// (mid-replay): skipping it would strand a voice that replay's
	// snapshot already missed.
	if base, ok := d.Sup.LiveURL(); ok {
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
	d.voiceMu.Lock()
	defer d.voiceMu.Unlock()
	if err := d.Store.Remove(name); err != nil {
		return err
	}
	g := d.Sup.Acquire()
	defer g.Release()
	if base, ok := d.Sup.LiveURL(); ok {
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

// applyVoiceDefault resolves the request's voice field: an explicit name
// wins; "default" selects the engine's built-in random voice and is
// stripped before the request reaches it; an unset field falls back to
// OX_SAY_VOICE when configured.
func (d *Daemon) applyVoiceDefault(body map[string]any) {
	if v, ok := body["voice"].(string); ok {
		if v == "default" {
			delete(body, "voice")
		}
		return
	}
	if d.Cfg.Voice != "" {
		body["voice"] = d.Cfg.Voice
	}
}

// statusSummary is the /status response.
type statusSummary struct {
	Engine engine.Status `json:"engine"`
	// STTServer is the resident ox-stt server's engine.Status, or
	// {"state":"off"} when OX_SAY_STT_SERVER=off.
	STTServer any            `json:"stt_server"`
	Voices    []voices.Voice `json:"voices"`
	Config    map[string]any `json:"config"`
	Version   string         `json:"version"`
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
	var sttServer any = map[string]string{"state": "off"}
	if d.STTSup != nil {
		sttServer = d.STTSup.Status()
	}
	return statusSummary{
		Engine:    d.Sup.Status(),
		STTServer: sttServer,
		Voices:    list,
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
			"voice":             d.Cfg.Voice,
			"home":              d.Cfg.Home,
			"stt_server":        d.Cfg.STTServer,
			"stt_port":          d.Cfg.STTPort,
			"stt_idle_stop_s":   d.Cfg.STTIdleStop.Seconds(),
			"stt_vad_model":     d.Cfg.STTVADModel,
		},
		Version: version,
	}
}

// Shutdown stops the engine child and releases the home lock. Note:
// go-mcpserver invokes OnShutdown BEFORE it drains in-flight HTTP
// requests, so the engine can stop while a speech request is still
// mid-flight — handlers keep their own guards and fail fast on the dead
// supervisor rather than blocking shutdown.
func (d *Daemon) Shutdown() {
	d.Sup.Shutdown()
	if d.STTSup != nil {
		d.STTSup.Shutdown()
	}
	if d.lockFile != nil {
		_ = d.lockFile.Close()
		d.lockFile = nil
	}
}
