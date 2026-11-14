// Package daemon wires the engine supervisor, voice store and HTTP/MCP
// surfaces together. HTTP handlers and MCP tools call the same methods here —
// the tools are a thin layer over the shared Go functions, never a loopback
// HTTP call.
package daemon

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/glossary"
	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/anatolykoptev/ox-say/internal/transcripts"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

// Daemon is the running service: engine supervisor + voice store + config.
type Daemon struct {
	Cfg   *config.Config
	Sup   *engine.Supervisor
	Store *voices.Store

	searchGate searchGate // caps the meeting searches that scan at once (meetings_search.go)

	// STTSup supervises the resident `ox-stt --serve` child; nil when
	// OX_SAY_STT_SERVER=off. On a discrete card it decodes on the CPU
	// (-ng): a resident process holding GPU memory for its whole life
	// cannot share the card through a per-run lease. With unified memory
	// (Apple Silicon) it decodes on the GPU next to the TTS engine — see
	// STTServeArgs.
	STTSup *engine.Supervisor

	// VoxSup supervises audiocpp_server (VoxCPM2); nil on a discrete card,
	// see config.VoxCPM2Unavailable.
	VoxSup *engine.Supervisor
	// voxQoS arbitrates the VoxCPM2 child's priority between the producer's
	// background job and interactive speak; nil without a VoxSup.
	voxQoS *qosGate

	// LLMSup supervises ox-llm (llama-server), the meeting-notes model; it
	// starts on the first notes call and stops after NotesIdleStop. Nil
	// when NotesBin is empty — a Config literal without notes settings.
	LLMSup *engine.Supervisor

	// mem makes the large engines (Sup, VoxSup, LLMSup) take turns on an Apple Silicon Mac with less memory than
	// config.OneLargeEngineBelowGB; nil elsewhere, where every enter is a no-op (see residency).
	mem *residency

	// Meet takes recorded meetings through transcription and notes.
	Meet *meeting.Runner
	// Transcripts keeps file transcripts under $OX_SAY_HOME/transcripts; nil when the
	// directory could not be opened (the routes then answer 503).
	Transcripts *transcripts.Store
	// Glossary holds the user's heard → meant pairs ($OX_SAY_HOME/glossary.json).
	Glossary *glossary.Store
	// ownerToken is the bearer the owner-only glossary routes check, loaded
	// or created at start from $OX_SAY_HOME/owner.token (mode 0600). Empty
	// fails closed: nothing approves or rejects.
	ownerToken string
	// meetCancel and meetDone stop and await StartMeetings' goroutines.
	meetCancel context.CancelFunc
	meetDone   chan struct{}
	// notes is the single-flight guard and last error of the notes model
	// download (InstallNotesModel).
	notes notesInstall
	// fit records the notes engine's start-time GPU-fit decisions — the
	// degradation floor an OOM'd start forced and the label /status
	// reports (notesfit.go).
	fit notesFit

	// cleaning is the voice cleanups in flight (0 or 1, busy.cleaning): the CompareAndSwap that makes a second one 409.
	// cleanRunning is the part of that time the cleanup is past its wait for a quiet daemon and is using the GPU;
	// waitQuiet holds a voiceover render back while it is non-zero. cleanInst is the lazy model download,
	// cleanVer the cached `ox-clean --version`.
	cleaning     atomic.Int64
	cleanRunning atomic.Int64
	cleanInst    cleanInstall
	cleanVer     cleanVersionCache

	ec  *engine.Client
	log *slog.Logger

	// gpu is the single-token GPU lease shared by the TTS engine (held
	// from a start's spawn to the child's observed exit) and by a per-call
	// ox-stt run that goes without -ng (issue #11). It is wired only on a
	// discrete card; with unified memory nothing takes it.
	gpu *engine.GPULease

	// modelMu serializes model removals (DELETE /v1/models/{id}), the notes
	// model's saved-choice switch (PUT /v1/meetings/notes-model) and the
	// own-model trial load that precedes a {"path"} choice: two writers at
	// once would both stop the same engine and race on the same file.
	modelMu sync.Mutex

	// upstream is the single-flight cached answer to "is the uncensored
	// model's download URL still on its host", read by its /v1/models row
	// and the notes-model choices while that file is not installed.
	upstream notesUpstreamProbe

	// trialExclusive flips the residency condition while an own-model trial
	// of a file over config.NotesExclusiveBytes runs: on a Mac where the
	// large engines take turns only for a large notes model, a large trial
	// takes the turn like a notes job would.
	trialExclusive atomic.Bool

	// trialMu guards trialSup and trialDone: the supervisor of the one
	// own-model trial child, so the daemon's shutdown can stop it too, and
	// the reservation marking the notes engine as the trial's — a channel
	// closed when the trial ends, which notes jobs wait on before taking
	// the engine turn (notesvalidate.go).
	trialMu   sync.Mutex
	trialSup  *engine.Supervisor
	trialDone chan struct{}

	// voiceMu serializes voice mutations against engine-start replay: a
	// voice written while replayVoices runs could otherwise be missing
	// from both the store snapshot and the live child.
	voiceMu sync.Mutex
	// voxRefMax overrides the reference-clip limit in seconds; zero means
	// voxMaxRefSeconds. Set by tests only.
	voxRefMax float64

	// replayAfterSnapshot, when set (tests only), runs inside replayVoices
	// after the store snapshot, with voiceMu held.
	replayAfterSnapshot func()

	// slowPrepare, when set (tests only), runs inside AddVoice just before
	// Store.Prepare — a stand-in for a slow ffmpeg normalization, so a test
	// can hold the prepare phase open while the idle deadline passes.
	slowPrepare func()

	// slowDesign, when set (tests only), runs at the top of DesignVoice —
	// a stand-in for a design run in flight, so a test can hold the
	// busy.designing counter open without an engine.
	slowDesign func()

	// lockFile holds daemon.lock for the process lifetime.
	lockFile *os.File

	// repairCancel and repairDone stop and await a StartVoiceRepair pass.
	repairCancel context.CancelFunc
	repairDone   chan struct{}
	repairStop   sync.Once
	// sweepCancel and sweepDone stop and await a StartCleanScratchSweep pass.
	sweepCancel context.CancelFunc
	sweepDone   chan struct{}

	// prod runs long-form voiceover jobs; inflight and lastInteractiveEnd
	// feed the dictation yield (see interactive.go).
	prod               *producer
	inflight           atomic.Int64
	lastInteractiveEnd atomic.Int64

	// speaking, designing and transcribing count in-flight work /status
	// reports under busy: a restart kills any of them mid-request, and all
	// can be driven by CLI and MCP clients nothing else can see.
	speaking atomic.Int64
	// runaways and streamAborts back /status tts_faults.
	runaways     atomic.Int64
	streamAborts atomic.Int64
	designing    atomic.Int64
	transcribing atomic.Int64

	// sessSeen is the daemon's mirror of the resident STT server's open
	// sessions (they live inside the server's process): id → last traffic.
	sessMu   sync.Mutex
	sessSeen map[string]time.Time
}

// New builds the supervisor (reaping any orphaned engine) and the voice
// store, and wires voice replay into engine startup.
func New(cfg *config.Config, logger *slog.Logger) (*Daemon, error) {
	return newDaemon(cfg, logger, nil, nil, nil)
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

// STTServeArgs is the resident server's argv, evaluated at every spawn
// (exported for cmd/ox-say-bench, which spawns the same argv). On
// a discrete card it always decodes on the CPU (-ng): a child that would
// hold GPU memory for its whole lifetime cannot take part in the per-run
// GPU lease (a speak would have to wait out its idle timeout), so
// OX_SAY_STT_GPU=on scopes to the per-call CLI only. With unified memory
// there is no lease and room for both engines: the server decodes on the
// GPU unless OX_SAY_STT_GPU=off.
func STTServeArgs(cfg *config.Config, port int) []string {
	args := []string{"--serve", "--port", strconv.Itoa(port), "-m", cfg.STTModel}
	if !cfg.UnifiedMemory() || cfg.STTGPU == config.STTGPUOff {
		args = append(args, "-ng")
	}
	// Streaming sessions need the silero VAD model; without the file the
	// server spawns exactly as before and the session routes answer 501.
	// The stat runs per spawn, so dropping the model in later enables
	// sessions without a daemon restart.
	if _, err := os.Stat(cfg.STTVADModel); err == nil {
		args = append(args, "--vad", cfg.STTVADModel)
	}
	// Re-decode at release (#88): /finish on a cut session shorter than this
	// decodes the whole recording once through the /transcribe path.
	args = append(args, "--redecode-max-s", "15")
	return args
}

// newDaemon is New plus engine.Config tuning hooks for tests — tune for
// the TTS supervisor, tuneSTT for the STT server's, tuneVox for the voxcpm2
// child's.
func newDaemon(cfg *config.Config, logger *slog.Logger, tune, tuneSTT, tuneVox func(*engine.Config)) (*Daemon, error) {
	if logger == nil {
		logger = slog.Default()
	}
	store, err := voices.New(cfg.VoicesDir())
	if err != nil {
		return nil, err
	}
	d := &Daemon{
		Cfg:      cfg,
		Store:    store,
		ec:       engine.NewClient(),
		log:      logger,
		gpu:      engine.NewGPULease(),
		sessSeen: map[string]time.Time{},
	}
	store.SetTranscriber(d.voiceWords)
	// Single-instance lock: taken BEFORE the supervisor reaps orphaned
	// engines so a second daemon on the same home cannot kill the first
	// one's live engine before failing to bind.
	lockF, err := lockHome(cfg)
	if err != nil {
		return nil, err
	}
	d.lockFile = lockF
	if n := sweepLoudnormTemps(cfg.CacheDir, loudnormTempMinAge); n > 0 {
		logger.Info("loudness: removed leftover scratch files", slog.Int("files", n))
	}
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
	}
	if !cfg.UnifiedMemory() {
		// The TTS engine owns the GPU while its child lives: a start waits
		// out a GPU transcription, and the lease is released at the child's
		// observed exit — past the Stopped commit (issue #11). Unified memory
		// holds both engines, so nothing arbitrates there.
		ec.GPU = d.gpu
	}
	logger.Info("gpu memory model", slog.Bool("unified", cfg.UnifiedMemory()))
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
			// GPU or CPU per the memory model; see STTServeArgs.
			Args: func(port int) []string { return STTServeArgs(cfg, port) },
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
	if cfg.UnifiedMemory() {
		if d.VoxSup, err = newVoxSupervisor(cfg, logger, tuneVox); err != nil {
			sup.Shutdown()
			if d.STTSup != nil {
				d.STTSup.Shutdown()
			}
			_ = lockF.Close()
			return nil, err
		}
	}
	// A Config literal (tests) names no notes binary: no supervisor, and the
	// notes engine reports itself unavailable in /status.
	if cfg.NotesBin != "" {
		if d.LLMSup, err = newLLMSupervisor(d); err != nil {
			sup.Shutdown()
			if d.STTSup != nil {
				d.STTSup.Shutdown()
			}
			if d.VoxSup != nil {
				d.VoxSup.Shutdown()
			}
			_ = lockF.Close()
			return nil, err
		}
	}
	if cfg.OneLargeEngine() {
		d.mem = newResidency(logger, d.largeEngineSups()...)
	} else if d.notesCouldBeExclusive() {
		// A notes model over config.NotesExclusiveBytes makes the large
		// engines take turns even on a Mac the voices share; the condition is
		// read per call, so a model the user switches to counts at once, and
		// an own-model trial of a large file counts for its duration.
		if r := newResidency(logger, d.largeEngineSups()...); r != nil {
			r.cond = func() bool { return d.notesExclusive() || d.trialExclusive.Load() }
			d.mem = r
		}
	}
	logger.Info("large engine memory model", slog.String("mode", d.mem.mode()))
	// A daemon killed mid-trial left the child itself behind: notes-trial.pid
	// names it, and constructing the trial supervisor reaps the orphan through
	// the same exe + start-token check the next trial would run — here, at
	// startup, before any notes work, not only when another check happens to
	// build a trial supervisor. Its key — a dead bearer credential — is swept
	// with it.
	_ = os.Remove(filepath.Join(cfg.RunDir(), notesTrialKeyFile))
	if cfg.NotesBin != "" {
		// A reaper that cannot be built must not keep the daemon down: the
		// next check reaps the orphan the same way.
		if tsup, err := d.newNotesTrialSupervisor(""); err != nil {
			logger.Warn("own notes model: the orphaned trial child could not be looked for", "error", err)
		} else {
			tsup.Shutdown()
		}
	}
	d.initGlossary()
	d.initMeetings()
	d.initTranscripts()
	if d.VoxSup != nil {
		d.voxQoS = &qosGate{
			pid: func() int { return d.VoxSup.Status().PID },
			set: setBackground,
			log: logger,
		}
	}
	d.prod = newProducer(d.producePorts())
	d.prod.log = logger
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

// engineBase takes the fast voice's turn (see residency), acquires an in-flight
// guard and ensures the engine is ready. On failure everything is released
// inside the helper; on success the caller owns release and must call it when
// the request finishes (guard first, then the turn).
func (d *Daemon) engineBase(ctx context.Context) (base string, release func(), err error) {
	leave, err := d.mem.enter(ctx, d.Sup, engineTurnBudget)
	if err != nil {
		return "", nil, err
	}
	g := d.Sup.Acquire()
	base, err = d.Sup.EnsureReady(ctx)
	if err != nil {
		g.Release()
		leave()
		return "", nil, err
	}
	return base, func() { g.Release(); leave() }, nil
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
	return d.AddVoiceMeta(ctx, name, audioPath, refText, voices.Meta{})
}

// AddVoiceMeta is AddVoice with the voice's metadata (engine, style,
// designed_from). A voice that will carry voxcpm2 — by m, or inherited from the
// voice it replaces — must have a reference the encoder can take: Prepare
// already cuts every clip to voices.MaxRefSeconds, and the check below refuses
// it should that cap ever outgrow voxMaxRefSeconds.
func (d *Daemon) AddVoiceMeta(ctx context.Context, name, audioPath, refText string, m voices.Meta) (v *voices.Voice, registered bool, err error) {
	return d.addVoice(ctx, name, audioPath, refText, m, addOpts{})
}

// addOpts are the extra rules of a save that is not a plain add.
type addOpts struct {
	// createOnly refuses (409) when the name is taken, decided under voiceMu in
	// the same step as the write: an early check outside the lock cannot see a
	// save that commits during this one's Prepare.
	createOnly bool
	// fresh keeps nothing of a voice this one replaces (voices.Pending.Fresh).
	fresh bool
}

func (d *Daemon) addVoice(ctx context.Context, name, audioPath, refText string, m voices.Meta, o addOpts) (v *voices.Voice, registered bool, err error) {
	m, merr := normalizeMeta(m)
	if merr != nil {
		return nil, false, merr
	}
	if err := d.Store.ValidateInput(name, audioPath); err != nil {
		return nil, false, err
	}
	// Lock order: Sup.Acquire is not a lock a holder can wait on. It bumps a
	// counter under the supervisor's s.mu, a leaf mutex never held across a
	// wait (the start goroutine runs Replay, which takes voiceMu, with s.mu
	// released), so taking it before or after voiceMu cannot form a cycle
	// (#310.3). RemoveVoice takes them in the other order for that reason.
	// Across Prepare (a transcription, up to 60 s) the guard only keeps the idle loop off the child, so it is the
	// idle-only kind: with a hard guard a studio-voice turn, which stops this engine, would wait out the whole
	// preparation (a busy answer at 10 s, a failed take at 30 s). If the engine is stopped for another one meanwhile,
	// the voice is still stored and the next start replays it. The registration itself takes a hard guard below.
	g := d.Sup.AcquireIdleOnly()
	defer g.Release()
	if d.slowPrepare != nil {
		d.slowPrepare()
	}
	pending, err := d.Store.Prepare(ctx, name, audioPath, refText)
	if err != nil {
		return nil, false, err
	}
	defer pending.Discard()
	if d.effectiveEngine(name, m) == config.TTSModelVoxCPM2 {
		secs, serr := pending.Seconds()
		if serr == nil {
			serr = d.checkVoxReference(secs)
		}
		if serr != nil {
			return nil, false, serr
		}
	}
	pending.SetMeta(m)
	if o.fresh {
		pending.Fresh()
	}
	d.voiceMu.Lock()
	defer d.voiceMu.Unlock()
	if o.createOnly {
		if _, gerr := d.Store.Get(name); gerr == nil {
			return nil, false, errVoiceExists(name)
		} else if !errors.Is(gerr, voices.ErrNotFound) {
			return nil, false, d.voiceReadError(name, gerr, true)
		}
	}
	v, err = pending.Commit()
	if err != nil {
		return nil, false, err
	}
	// A live registration is engine work — the guard above keeps the idle
	// loop from stopping the child mid-request. LiveURL also reaches a
	// child that is past /health but still inside its start attempt
	// (mid-replay): skipping it would strand a voice that replay's
	// snapshot already missed.
	rg := d.Sup.Acquire() // the registration is a request the child is serving: Stop waits for it
	defer rg.Release()
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

// effectiveEngine is the engine a voice will carry after being added with m:
// the request's, else the one a re-added voice inherits from its stored
// metadata (see voices.Pending.Commit).
func (d *Daemon) effectiveEngine(name string, m voices.Meta) string {
	if m.Engine != "" {
		return m.Engine
	}
	if prev, err := d.Store.Get(name); err == nil {
		return prev.Engine
	}
	return ""
}

// RemoveVoice deletes a voice from disk and, when the engine is running,
// from the child too.
func (d *Daemon) RemoveVoice(ctx context.Context, name string) error {
	d.voiceMu.Lock()
	defer d.voiceMu.Unlock()
	if err := d.Store.Remove(name); err != nil {
		return err
	}
	// voiceMu then Acquire, the reverse of addVoice, is safe: Acquire only
	// takes the supervisor's leaf s.mu for a counter bump and never waits on
	// voiceMu's holder (see addVoice, #310.3).
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
// the configured voice for the request's language, then OX_SAY_VOICE.
func (d *Daemon) applyVoiceDefault(body map[string]any) {
	v, _ := body["voice"].(string)
	if v == "default" {
		delete(body, "voice")
		return
	}
	if v == "" {
		if cv := d.configuredVoice(langHint(body)); cv != "" {
			body["voice"] = cv
		}
	}
}

// applySeedDefault gives a request that names no seed the daemon's
// OX_SAY_SEED, so the voice stays the same from one request to the next. A
// request seed is left alone; a negative one is the engine's "draw a random
// seed" and counts as none. It marks body (fieldSeedDefaulted) when it filled
// the seed, so a later runaway may be retried on a fresh seed — a seed the
// caller pinned must not be swapped behind their back.
func (d *Daemon) applySeedDefault(body map[string]any) {
	if d.Cfg.Seed == nil {
		return
	}
	if _, ok := seedFixed(body); !ok {
		body[fieldSeed] = *d.Cfg.Seed
		body[fieldSeedDefaulted] = true
	}
}

// configuredVoice picks the configured voice for a language code: the
// per-language OX_SAY_VOICE_<LANG> wins, then the global OX_SAY_VOICE.
func (d *Daemon) configuredVoice(lang string) string {
	switch lang {
	case "ru":
		if d.Cfg.VoiceRU != "" {
			return d.Cfg.VoiceRU
		}
	case "en":
		if d.Cfg.VoiceEN != "" {
			return d.Cfg.VoiceEN
		}
	}
	return d.Cfg.Voice
}

// configuredLang is the default language (OX_SAY_LANG) as langHint resolves a
// request's language field: what the speak route falls back to for input that
// has no letters of its own, and what produce falls back to for a script with
// none. "" when unset or not a language the daemon knows.
func (d *Daemon) configuredLang() string {
	return langHint(map[string]any{"language": d.Cfg.Lang})
}

// langHint resolves a request's language to a short code. A recognized
// language field wins; otherwise the input's script decides — Cyrillic is
// Russian, Latin letters are English. Anything else returns "".
func langHint(body map[string]any) string {
	if l, ok := body["language"].(string); ok {
		switch strings.ToLower(strings.TrimSpace(l)) {
		case "ru", "rus", "russian", "русский":
			return "ru"
		case "en", "eng", "english":
			return "en"
		}
	}
	input, _ := body["input"].(string)
	latin := false
	for _, r := range input {
		switch {
		case unicode.Is(unicode.Cyrillic, r):
			return "ru"
		case unicode.Is(unicode.Latin, r):
			latin = true
		}
	}
	if latin {
		return "en"
	}
	return ""
}

// busySummary is the /status view of the work a daemon restart would
// interrupt, counted per lane where the daemon itself can see it —
// including load driven by CLI and MCP clients, which the app cannot.
type busySummary struct {
	// Produce is the running voiceover job, or a project delete in flight (0 or 1).
	Produce int `json:"produce"`
	// STTSessions is the count of open streaming-dictation sessions on the
	// resident ox-stt server.
	STTSessions int `json:"stt_sessions"`
	// Speaking is the speech requests in flight.
	Speaking int `json:"speaking"`
	// Designing is the voice designs in flight.
	Designing int `json:"designing"`
	// Transcribing is the transcriptions in flight, however they arrived:
	// MCP transcribe and the STT pass of voice_add reach no HTTP wrapper.
	Transcribing int `json:"transcribing"`
	// Interactive is the interactive routes in flight (interactive.go): a
	// request that counts in no other lane — a one-shot transcription
	// upload — still marks the daemon busy here.
	Interactive int `json:"interactive"`
	// Meetings is the recorded meetings queued or running, plus a notes
	// model download: a restart would lose the job's progress.
	Meetings int `json:"meetings"`
	// Cleaning is the voice cleanup in flight (0 or 1), including its wait for a quiet daemon.
	Cleaning int `json:"cleaning"`
}

// idle reports whether every lane is empty — the version handshake's
// precondition for a restart or a relaunch.
func (b busySummary) idle() bool {
	return b == busySummary{}
}

// busy counts the work a restart would interrupt, per lane.
func (d *Daemon) busy() busySummary {
	return busySummary{
		Produce:      d.prod.active(),
		STTSessions:  d.sttSessions(),
		Speaking:     int(d.speaking.Load()),
		Designing:    int(d.designing.Load()),
		Transcribing: int(d.transcribing.Load()),
		Interactive:  int(d.inflight.Load()),
		Meetings:     d.Meet.Active() + d.notesInstalling(),
		Cleaning:     d.cleanBusyCount(),
	}
}

// statusSummary is the /status response.
type statusSummary struct {
	Engine engine.Status `json:"engine"`
	// STTServer is the resident ox-stt server's engine.Status, or
	// {"state":"off"} when OX_SAY_STT_SERVER=off.
	STTServer any `json:"stt_server"`
	// VoxCPM2 is the studio-voice engine: available or not (with the reason
	// in plain words), and its stopped/starting/ready state.
	VoxCPM2 voxCPM2Status `json:"voxcpm2"`
	// Notes is the meeting-notes engine: available, or the reason in plain
	// words and as a code, the runtime state and the model download's
	// progress.
	Notes notesStatus `json:"notes"`
	// VoiceClean is the voice-cleanup engine: available, or the reason in plain words and as a code, and the lazy
	// model download.
	VoiceClean cleanStatus    `json:"voice_clean"`
	Voices     []voices.Voice `json:"voices"`
	Config     map[string]any `json:"config"`
	Version    string         `json:"version"`
	// MemoryMode is how the large GPU engines share this Mac's memory:
	// "one_large_engine" (the fast voice, the studio voice and the notes model
	// take turns; Apple Silicon below config.OneLargeEngineBelowGB) or "shared"
	// (all of them may be resident at once). The resident STT server is in
	// neither: it is never stopped for another engine.
	MemoryMode string `json:"memory_mode"`
	// Busy counts in-flight work per lane; Idle holds only when every
	// count is zero. A client about to restart the daemon — the app's
	// version handshake — checks Idle first.
	Busy busySummary `json:"busy"`
	Idle bool        `json:"idle"`
	// TTSFaults counts speech takes the engine failed to finish since the
	// daemon started (see ttsFaults).
	TTSFaults ttsFaults `json:"tts_faults"`
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
	busy := d.busy()
	return statusSummary{
		Engine:     d.Sup.Status(),
		STTServer:  sttServer,
		VoxCPM2:    d.voxStatus(),
		Notes:      d.notesStatus(),
		VoiceClean: d.cleanStatus(),
		Voices:     list,
		Config: map[string]any{
			"addr":              d.Cfg.Addr,
			"engine_port":       d.Cfg.EnginePort,
			"engine_bin":        d.Cfg.EngineBin,
			"stt_bin":           d.Cfg.STTBin,
			"voxcpm2_bin":       d.Cfg.VoxCPM2Bin,
			"notes_bin":         d.Cfg.NotesBin,
			"diar_bin":          d.Cfg.DiarBin,
			"clean_bin":         d.Cfg.CleanBin,
			"diar_engine":       d.Cfg.Engine(),
			"model":             d.Cfg.Model,
			"codec":             d.Cfg.Codec,
			"max_batch":         d.Cfg.MaxBatch,
			"idle_stop_s":       d.Cfg.IdleStop.Seconds(),
			"startup_timeout_s": d.Cfg.StartupTimeout.Seconds(),
			"lang":              d.Cfg.Lang,
			"voice":             d.Cfg.Voice,
			"voice_ru":          d.Cfg.VoiceRU,
			"voice_en":          d.Cfg.VoiceEN,
			"home":              d.Cfg.Home,
			"stt_server":        d.Cfg.STTServer,
			"stt_port":          d.Cfg.STTPort,
			"stt_idle_stop_s":   d.Cfg.STTIdleStop.Seconds(),
			"stt_vad_model":     d.Cfg.STTVADModel,
			"tts_model":         d.Cfg.TTSModel,
			// What a client uploading a file must stay inside: the per-transcription timeout and the upload cap,
			// both configurable (OX_SAY_STT_TIMEOUT_SECS, OX_SAY_STT_MAX_UPLOAD_MB). The app sizes its own timeout
			// and size check on them and falls back to the defaults when an older daemon omits them.
			"stt_timeout_s":     d.Cfg.STTTimeout.Seconds(),
			"stt_max_upload_mb": d.Cfg.STTMaxUploadMB,
		},
		Version:    version,
		MemoryMode: d.mem.mode(),
		Busy:       busy,
		Idle:       busy.idle(),
		TTSFaults:  ttsFaults{Runaways: d.runaways.Load(), StreamAborts: d.streamAborts.Load()},
	}
}

// Shutdown stops the engine child and releases the home lock. Note:
// go-mcpserver invokes OnShutdown BEFORE it drains in-flight HTTP
// requests, so the engine can stop while a speech request is still
// mid-flight — handlers keep their own guards and fail fast on the dead
// supervisor rather than blocking shutdown.
func (d *Daemon) Shutdown() {
	d.StopMeetings()
	d.StopNotesInstall()
	d.stopTrialSup()
	d.StopCleanInstall()
	d.StopProducer()
	d.StopVoiceRepair()
	d.Sup.Shutdown()
	if d.STTSup != nil {
		d.STTSup.Shutdown()
	}
	if d.VoxSup != nil {
		d.VoxSup.Shutdown()
	}
	if d.LLMSup != nil {
		d.LLMSup.Shutdown()
	}
	if d.lockFile != nil {
		_ = d.lockFile.Close()
		d.lockFile = nil
	}
}
