// Package engine supervises the tts-server child process: single-flight
// startup, health gating, idle shutdown, crash restart with backoff, an
// in-flight request guard, and pidfile orphan reaping.
package engine

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// State is the supervisor's lifecycle state.
type State string

const (
	StateStopped  State = "stopped"
	StateStarting State = "starting"
	StateReady    State = "ready"
	StateCrashed  State = "crashed"
)

// ErrShutdown is returned by EnsureReady after Shutdown was called.
var ErrShutdown = errors.New("engine: supervisor shut down")

// Config controls the supervisor.
type Config struct {
	Bin      string // child binary; reapOrphan matches an orphan's exe to it
	Model    string // talker GGUF
	Codec    string // tokenizer GGUF
	Port     int    // loopback port the child binds
	MaxBatch int

	// Name, when non-empty, tags the supervisor's log lines with a
	// child=<Name> attribute — two supervised engines would otherwise
	// interleave indistinguishably. Empty: log lines are unchanged.
	Name string
	// LogName is the child's log file name inside LogDir; "" → engine.log.
	LogName string
	// Args, when non-nil, produces the spawned argv for the configured
	// port; nil keeps the tts-server argv
	// (--model/--codec/--host/--port/--max-batch).
	Args func(port int) []string

	StartupTimeout time.Duration // covers first-start Metal shader compile (~60s)
	IdleStop       time.Duration // 0 = never stop for idleness
	LogDir         string        // child stdout/stderr destination
	PidPath        string        // child pidfile

	// GPU, when non-nil, arbitrates the card between this engine and
	// whoever else holds the lease (a GPU ox-stt run). A start attempt
	// waits for it on the caller's context, then holds it from spawn to
	// the observed child exit — past the Stopped transition.
	GPU *GPULease

	// Replay is invoked after /health first reports OK and before the engine
	// is marked Ready. The daemon uses it to re-register persisted voices,
	// which the child holds only in memory.
	Replay func(ctx context.Context, baseURL string) error

	Logger *slog.Logger // nil → slog.Default()

	// Tunables — zero values get sane defaults; tests override.
	IdleTick    time.Duration // idle check interval (default min(IdleStop/2, 1s))
	HealthPoll  time.Duration // /health poll interval while starting (default 250ms)
	KillGrace   time.Duration // SIGTERM → SIGKILL escalation delay (default 5s)
	LogMaxBytes int64         // engine.log truncation threshold (default 10MB)
}

const (
	defaultHealthPoll  = 250 * time.Millisecond
	defaultKillGrace   = 5 * time.Second
	defaultLogMaxBytes = 10 << 20
	readyResetAfter    = 60 * time.Second // Ready this long → crash backoff resets
)

// Status is a point-in-time snapshot for /status and the engine_status tool.
type Status struct {
	State    State   `json:"state"`
	PID      int     `json:"pid,omitempty"`
	BaseURL  string  `json:"base_url,omitempty"`
	UptimeS  float64 `json:"uptime_s,omitempty"`
	LastErr  string  `json:"last_error,omitempty"`
	Starts   int     `json:"starts"`   // total spawn count
	Restarts int     `json:"restarts"` // starts triggered by a crash
	// GPUHeldBy names the lease's current holder — "tts" while the child
	// lives, "transcription" for a GPU ox-stt run; empty when the card is
	// free or no lease is wired.
	GPUHeldBy string `json:"gpu_held_by,omitempty"`
}

// Supervisor owns one child process generation at a time.
type Supervisor struct {
	cfg Config
	hc  *http.Client
	log *slog.Logger

	mu         sync.Mutex
	change     chan struct{} // closed on every state transition (broadcast)
	state      State
	dead       bool // Shutdown called
	child      *child
	lastErr    error
	startGen   int   // incremented for every start attempt launched
	attemptErr error // concluded start-attempt error…
	attemptGen int   // …belonging to this start generation; delivered to every waiter of it, never to a later request
	// attemptDoneAt is when the attempt owning attemptErr concluded. An
	// EnsureReady caller that entered before it overlapped the attempt and
	// is owed the error — even when it never took s.mu while the attempt
	// was in flight.
	attemptDoneAt time.Time
	starts        int
	restarts      int
	failCount     int // consecutive crash/start failures (drives backoff)
	nextAttempt   time.Time
	lastActivity  time.Time // last Ready commit or Guard release
	guards        int
	gpuHeld       bool // the current generation owns cfg.GPU

	stopIdle  chan struct{}
	idleDone  chan struct{}
	closeOnce sync.Once

	// ensureEntryHook, when set (tests only), runs inside EnsureReady
	// after the caller's entry timestamp, before the first s.mu
	// acquisition — it parks a caller in the window where an in-flight
	// start attempt can conclude unseen.
	ensureEntryHook func()
}

// child is one spawned engine process generation.
type child struct {
	cmd      *exec.Cmd
	logf     *os.File
	done     chan struct{} // closed by the waiter goroutine on exit
	waitErr  error         // valid once done is closed
	baseURL  string
	readyAt  time.Time
	userStop bool // daemon-requested stop (idle, shutdown, failed-start cleanup)
}

// New creates a supervisor, reaps an orphaned engine left by a previous daemon
// (SIGKILLed daemon → child keeps the GPU and the port), and starts the idle
// loop. It does not spawn the engine — first EnsureReady does.
func New(cfg Config) (*Supervisor, error) {
	if cfg.Bin == "" {
		return nil, errors.New("engine: Bin is required")
	}
	if cfg.Port <= 0 || cfg.Port > 65535 {
		return nil, fmt.Errorf("engine: invalid Port %d", cfg.Port)
	}
	if cfg.StartupTimeout <= 0 {
		cfg.StartupTimeout = 180 * time.Second
	}
	if cfg.HealthPoll <= 0 {
		cfg.HealthPoll = defaultHealthPoll
	}
	if cfg.KillGrace <= 0 {
		cfg.KillGrace = defaultKillGrace
	}
	if cfg.LogMaxBytes <= 0 {
		cfg.LogMaxBytes = defaultLogMaxBytes
	}
	if cfg.IdleStop > 0 && cfg.IdleTick <= 0 {
		cfg.IdleTick = min(cfg.IdleStop/2, time.Second)
	}
	logger := orLogger(cfg.Logger)
	if cfg.Name != "" {
		logger = logger.With("child", cfg.Name)
	}
	s := &Supervisor{
		cfg:      cfg,
		hc:       &http.Client{Timeout: 10 * time.Second},
		log:      logger,
		change:   make(chan struct{}),
		state:    StateStopped,
		stopIdle: make(chan struct{}),
		idleDone: make(chan struct{}),
	}
	s.reapOrphan()
	if cfg.IdleStop > 0 {
		go s.idleLoop()
	} else {
		close(s.idleDone)
	}
	return s, nil
}

func orLogger(l *slog.Logger) *slog.Logger {
	if l == nil {
		return slog.Default()
	}
	return l
}

func (s *Supervisor) baseURL() string {
	return fmt.Sprintf("http://127.0.0.1:%d", s.cfg.Port)
}

func (s *Supervisor) broadcastLocked() {
	close(s.change)
	s.change = make(chan struct{})
}

// EnsureReady returns the child's base URL, starting it if needed. Concurrent
// callers share a single start; callers arriving while a start is in flight
// wait for its outcome. After an unexpected exit the next EnsureReady waits
// out a backoff (1s doubling to 30s) before respawning.
func (s *Supervisor) EnsureReady(ctx context.Context) (string, error) {
	// enteredAt separates callers that overlapped a start attempt from
	// callers that arrived only after it concluded — see the default branch.
	enteredAt := time.Now()
	if s.ensureEntryHook != nil {
		s.ensureEntryHook()
	}
	var waitGen int // the last in-flight start generation this caller joined
	loggedInvariant := false
	// gpuOwned tracks this caller's lease token until the start commit hands
	// it to the generation (s.gpuHeld); every early return must give it
	// back, hence the defer. The token is only ever acquired with no locks
	// held and released without blocking, so the lease cannot cycle with
	// s.mu, the guard counter, voiceMu or stt's sem.
	gpuOwned := false
	defer func() {
		if gpuOwned {
			s.cfg.GPU.Release()
		}
	}()
	for {
		s.mu.Lock()
		switch {
		case s.dead:
			s.mu.Unlock()
			return "", ErrShutdown
		case s.state == StateReady:
			if s.child == nil {
				// Unreachable since finishStart commits Ready only for a live
				// owned child; log it so a regression is visible, and wait
				// for the next transition rather than dereference nil.
				if !loggedInvariant {
					s.log.Error("engine invariant violated: ready without a child")
					loggedInvariant = true
				}
				ch := s.change
				s.mu.Unlock()
				select {
				case <-ch:
				case <-ctx.Done():
					return "", ctx.Err()
				}
				continue
			}
			url := s.child.baseURL
			s.mu.Unlock()
			return url, nil
		case s.state == StateStarting || s.child != nil:
			// Start in flight, or a previous child is still tearing down —
			// wait for the next transition.
			waitGen = s.startGen
			ch := s.change
			s.mu.Unlock()
			select {
			case <-ch:
			case <-ctx.Done():
				return "", ctx.Err()
			}
		default: // stopped or crashed, no live child — eligible to start
			// A concluded failed attempt is reported to every caller that
			// overlapped it — including one that entered while it was in
			// flight but first took s.mu after the conclusion — HTTP maps
			// it to 503. The time test carries that decision: it subsumes
			// the generation test because waitGen is only set under s.mu
			// while its generation is still unconcluded and attemptDoneAt
			// is stamped later under the same mutex, so
			// attemptGen == waitGen already implies
			// !enteredAt.After(attemptDoneAt). The generation half stays
			// anyway — cheap, and defensive if the entry-stamp ordering
			// ever changes. waitGen is not necessarily unset for a caller
			// that never joined the failed generation: one parked through
			// an idle-stop teardown still holds the stale successful
			// generation it last waited on. A caller that arrived only
			// after the conclusion retries after the recorded backoff
			// instead of consuming the error.
			if s.attemptErr != nil && (s.attemptGen == waitGen || !enteredAt.After(s.attemptDoneAt)) {
				err := s.attemptErr
				s.mu.Unlock()
				return "", fmt.Errorf("engine: start failed: %w", err)
			}
			if d := time.Until(s.nextAttempt); d > 0 {
				ch := s.change
				s.mu.Unlock()
				t := time.NewTimer(d)
				select {
				case <-ch:
					t.Stop()
				case <-t.C:
				case <-ctx.Done():
					t.Stop()
					return "", ctx.Err()
				}
				continue
			}
			if s.cfg.GPU != nil && !gpuOwned {
				// A GPU transcription may own the card: the spawn needs the
				// lease, so the caller waits for it on its own context —
				// s.mu is released for the wait (the lease is never
				// acquired under a lock) and the change broadcast aborts it
				// so Shutdown or a racing transition re-evaluates instead of
				// leaving the caller parked until its ctx ends. The token,
				// once taken, is re-validated under s.mu: with it held no
				// other start can be committed, so only s.dead can have
				// changed.
				ch := s.change
				held := s.cfg.GPU.Held()
				heldBy := s.cfg.GPU.Owner()
				s.mu.Unlock()
				if held {
					// One line per park: the start is blocked behind
					// whoever holds the card and would otherwise be
					// invisible until its own timeout fires.
					s.log.Info("engine start waiting for the GPU lease", slog.String("held_by", heldBy))
				}
				ok, err := s.cfg.GPU.WaitOrAs(ctx, ch, s.leaseOwner())
				if err != nil {
					return "", err
				}
				if !ok {
					continue
				}
				gpuOwned = true
				continue
			}
			if s.state == StateCrashed || s.attemptErr != nil {
				// A respawn after a crash OR after a failed start counts
				// as a restart.
				s.restarts++
			}
			s.startGen++
			waitGen = s.startGen
			s.attemptErr = nil
			s.state = StateStarting
			s.gpuHeld = gpuOwned
			gpuOwned = false // transferred: the generation now owns the token
			s.lastErr = nil
			s.broadcastLocked()
			go s.run()
			ch := s.change
			s.mu.Unlock()
			select {
			case <-ch:
			case <-ctx.Done():
				return "", ctx.Err()
			}
		}
	}
}

// State reports the lifecycle state.
func (s *Supervisor) State() State {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.state
}

// leaseOwner tags this supervisor's lease holdings: the engine's Name
// when it has one, else "tts" — the only lease-wired engine today.
func (s *Supervisor) leaseOwner() string {
	if s.cfg.Name != "" {
		return s.cfg.Name
	}
	return "tts"
}

// Status returns a snapshot for /status and engine_status.
func (s *Supervisor) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	st := Status{
		State:    s.state,
		Starts:   s.starts,
		Restarts: s.restarts,
	}
	if s.cfg.GPU != nil {
		st.GPUHeldBy = s.cfg.GPU.Owner()
	}
	if s.lastErr != nil {
		st.LastErr = s.lastErr.Error()
	}
	if s.child != nil {
		st.PID = s.child.cmd.Process.Pid
		st.BaseURL = s.child.baseURL
		if !s.child.readyAt.IsZero() {
			st.UptimeS = time.Since(s.child.readyAt).Seconds()
		}
	}
	return st
}

// ReadyURL returns the base URL if the engine is ready, without starting it.
func (s *Supervisor) ReadyURL() (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state == StateReady && s.child != nil {
		return s.child.baseURL, true
	}
	return "", false
}

// LiveURL returns the base URL of the spawned child while it is alive —
// starting (possibly still before /health) or ready — and false when no
// child exists OR the child is already being stopped: the idle loop and
// Shutdown stamp userStop before killChild's SIGTERM→SIGKILL completes,
// and a caller handed that child would register work into a process that
// is exiting. Daemon code may register work into a still-starting engine;
// a request that lands before the model is loaded fails and replay covers it.
func (s *Supervisor) LiveURL() (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.child != nil && !s.child.userStop {
		return s.child.baseURL, true
	}
	return "", false
}

// Backoff reports how long a NEW EnsureReady caller would have to sleep out
// before the next start attempt may launch — the cool-down charged by a
// crash or a failed start. It is 0 whenever an attempt could start at once:
// never started, Ready, a start in flight or a child still tearing down,
// and after Shutdown. Callers with a cheaper path (the daemon's STT route
// falls back to the per-call CLI) use it to skip the wait instead of paying
// it per request.
func (s *Supervisor) Backoff() time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.dead || s.state == StateReady || s.state == StateStarting || s.child != nil {
		return 0
	}
	return max(time.Until(s.nextAttempt), 0)
}

// Guard marks an in-flight engine user; the idle loop never stops the child
// while a guard is alive. Release is idempotent.
type Guard struct {
	s    *Supervisor
	once sync.Once
}

// Acquire takes an in-flight guard.
func (s *Supervisor) Acquire() *Guard {
	s.mu.Lock()
	s.guards++
	s.mu.Unlock()
	return &Guard{s: s}
}

// Release returns the guard; idle accounting restarts now.
func (g *Guard) Release() {
	g.once.Do(func() {
		g.s.mu.Lock()
		g.s.guards--
		g.s.lastActivity = time.Now()
		g.s.mu.Unlock()
	})
}

// Shutdown stops the idle loop and the child (SIGTERM, SIGKILL after the
// grace period). Subsequent EnsureReady calls fail with ErrShutdown.
func (s *Supervisor) Shutdown() {
	s.mu.Lock()
	s.dead = true
	s.closeOnce.Do(func() { close(s.stopIdle) })
	c := s.child
	if c != nil {
		c.userStop = true
	}
	s.broadcastLocked()
	s.mu.Unlock()

	<-s.idleDone
	if c != nil {
		s.killChild(c)
	}
	// Wait briefly for the waiter goroutine to publish the exit so State()
	// settles — bounded: an uninterruptible child (killChild already logged
	// it and gave up) must not hang shutdown forever.
	if c != nil {
		select {
		case <-c.done:
		case <-time.After(s.cfg.KillGrace):
			s.log.Error("engine exit not observed during shutdown",
				slog.Int("pid", c.cmd.Process.Pid))
		}
	}
}

// run performs one start attempt in its own goroutine: spawn → health gate →
// voice replay → commit Ready (or record the failure with backoff).
func (s *Supervisor) run() {
	ctx, cancel := context.WithTimeout(context.Background(), s.cfg.StartupTimeout)
	defer cancel()

	c, err := s.spawn()
	if err == nil {
		err = s.waitHealthy(ctx, c)
	}
	if err == nil && s.cfg.Replay != nil {
		// Best-effort per spec ordering: a single corrupt voice file must not
		// keep the engine down; the daemon logs per-voice failures inside
		// Replay. A transport-level failure is surfaced the same way.
		if rerr := s.cfg.Replay(ctx, c.baseURL); rerr != nil {
			s.log.Warn("voice replay failed", slog.Any("error", rerr))
		}
	}
	if err != nil && c != nil {
		s.killChild(c)
	}
	// finishStart re-validates ownership under s.mu: a child that died or a
	// Shutdown that landed mid-start turns the attempt into a failed start.
	s.finishStart(c, err)
}

// spawn starts the child and installs the waiter goroutine.
func (s *Supervisor) spawn() (*child, error) {
	logf, err := s.openEngineLog()
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(s.cfg.Bin, s.childArgs()...)
	cmd.Stdout = logf
	cmd.Stderr = logf
	if err := cmd.Start(); err != nil {
		_ = logf.Close()
		return nil, fmt.Errorf("engine: spawn %s: %w", s.cfg.Bin, err)
	}
	c := &child{
		cmd:     cmd,
		logf:    logf,
		done:    make(chan struct{}),
		baseURL: s.baseURL(),
	}
	// The pidfile is written before the waiter starts: a child that dies at
	// once is then removed by the waiter's onExit, instead of the write
	// recreating a stale file after that removal (with a bare pid, since the
	// start time of a reaped pid cannot be read).
	s.writePidFile(c.cmd.Process.Pid)
	// The waiter runs before registration so c.done is always closed, even
	// when the shutdown check below refuses to adopt this child.
	go s.waiter(c)
	s.mu.Lock()
	if s.dead {
		s.mu.Unlock()
		_ = c.cmd.Process.Kill()
		<-c.done
		return nil, ErrShutdown
	}
	s.child = c
	s.starts++
	s.mu.Unlock()
	s.log.Info("engine spawned", slog.Int("pid", c.cmd.Process.Pid))
	return c, nil
}

// childArgs is the spawned argv: Config.Args when set, else the tts-server
// flags.
func (s *Supervisor) childArgs() []string {
	if s.cfg.Args != nil {
		return s.cfg.Args(s.cfg.Port)
	}
	return []string{
		"--model", s.cfg.Model,
		"--codec", s.cfg.Codec,
		"--host", "127.0.0.1",
		"--port", strconv.Itoa(s.cfg.Port),
		"--max-batch", strconv.Itoa(s.cfg.MaxBatch),
	}
}

// waiter owns cmd.Wait and reports the exit exactly once.
func (s *Supervisor) waiter(c *child) {
	c.waitErr = c.cmd.Wait()
	_ = c.logf.Close()
	close(c.done)
	s.onExit(c)
}

// onExit reaps the child pointer and transitions on child exit: while a
// start attempt is in flight (state == StateStarting) run() owns the
// classification — onExit only clears s.child so finishStart can see the
// death — otherwise daemon-requested → stopped, unexpected → crashed with
// restart backoff.
func (s *Supervisor) onExit(c *child) {
	var crashErr error
	var retryIn time.Duration
	s.mu.Lock()
	if s.child == c {
		s.child = nil
		// The lease, not the state, is "the engine holds the GPU": the
		// supervisor commits Stopped (idle loop, Shutdown) before the child
		// has exited, so releasing here — the observed exit — is what keeps
		// an ox-stt run off the card inside that window (issue #11).
		s.releaseGPULocked()
		switch {
		case s.state == StateStarting:
			// finishStart re-checks s.child == c / c.done under this same
			// lock and fails the attempt; classifying here too would let
			// one death be counted twice (and race a Ready commit onto a
			// dead child).
		case c.userStop:
			s.state = StateStopped
		default:
			if !c.readyAt.IsZero() && time.Since(c.readyAt) > readyResetAfter {
				s.failCount = 0
			}
			s.failCount++
			s.nextAttempt = time.Now().Add(s.backoffLocked())
			retryIn = time.Until(s.nextAttempt)
			s.state = StateCrashed
			s.lastErr = fmt.Errorf("engine exited unexpectedly: %w", c.waitErr)
			crashErr = c.waitErr
		}
		s.broadcastLocked()
	}
	// else: superseded — another path already cleaned up, but the pidfile
	// cleanup below still applies (it only removes a file naming this pid).
	s.mu.Unlock()
	s.removePidFile(c.cmd.Process.Pid)
	if crashErr != nil {
		s.log.Warn("engine crashed", slog.Any("error", crashErr),
			slog.Duration("retry_in", retryIn))
	}
}

// releaseGPULocked returns the current generation's lease token, if it
// owns one. It runs wherever a generation is dismantled under s.mu:
// onExit (the observed child exit) and finishStart's failure path (a start
// that leaves no live child to outlive it). Channel recv on a held token
// never blocks, so it is safe under s.mu and cannot cycle with the waiters
// that acquire the lease lock-free.
func (s *Supervisor) releaseGPULocked() {
	if s.gpuHeld && s.cfg.GPU != nil {
		s.gpuHeld = false
		s.cfg.GPU.Release()
	}
}

func (s *Supervisor) backoffLocked() time.Duration {
	d := time.Second << min(s.failCount-1, 5)
	return min(d, 30*time.Second)
}

// finishStart commits the outcome of run(). Ready is committed only while
// this attempt still owns s.child and the child is alive: onExit may have
// reaped a child that exited during startup, and Shutdown may have raced
// the whole attempt.
func (s *Supervisor) finishStart(c *child, err error) {
	var retryIn time.Duration
	s.mu.Lock()
	if err == nil && c != nil {
		switch {
		case s.dead:
			err = ErrShutdown
		case s.child != c:
			// onExit already reaped this child — it exited during startup.
			err = fmt.Errorf("engine exited during startup: %w", c.waitErr)
		default:
			select {
			case <-c.done:
				// The waiter has not run onExit yet; drop the child here
				// so onExit stays a no-op when it arrives.
				s.child = nil
				err = fmt.Errorf("engine exited during startup: %w", c.waitErr)
			default:
			}
		}
	}
	if err != nil {
		// The generation's lease goes back only once its child is provably
		// gone — that is the lifetime rule the idle-stop window needs
		// (issue #11). Paths reaching here with a dead-or-absent child
		// (spawn failure, post-killChild, a reap onExit already ran) release
		// it now; a child still dying under Shutdown's in-flight killChild
		// keeps s.child so its onExit releases at the real exit.
		if c != nil && s.child == c {
			select {
			case <-c.done:
				s.child = nil
				s.releaseGPULocked()
			default:
			}
		} else {
			s.releaseGPULocked()
		}
		s.lastErr = err
		s.attemptErr = err
		s.attemptGen = s.startGen // still this run's gen: no new attempt can launch while state is Starting
		s.attemptDoneAt = time.Now()
		if s.state != StateCrashed {
			// onExit may already have classified this child as crashed and
			// charged the backoff — never count one death twice.
			s.state = StateStopped
			s.failCount++
			s.nextAttempt = time.Now().Add(s.backoffLocked())
		}
		retryIn = time.Until(s.nextAttempt)
	} else {
		c.readyAt = time.Now()
		s.lastActivity = c.readyAt
		s.attemptErr = nil
		// failCount is NOT cleared here: an engine that reaches Ready and then
		// crashes on every request must keep escalating its backoff. It clears
		// after readyResetAfter of Ready (onExit) or on a clean idle stop.
		s.state = StateReady
	}
	s.broadcastLocked()
	s.mu.Unlock()
	if err != nil {
		s.log.Error("engine start failed", slog.Any("error", err),
			slog.Duration("retry_in", retryIn))
	} else {
		s.log.Info("engine ready", slog.String("base_url", c.baseURL))
	}
}

// waitHealthy polls /health until 200, the child exits, or ctx ends.
func (s *Supervisor) waitHealthy(ctx context.Context, c *child) error {
	url := c.baseURL + "/health"
	for {
		select {
		case <-c.done:
			return fmt.Errorf("engine exited during startup: %w", c.waitErr)
		case <-ctx.Done():
			return fmt.Errorf("engine did not become healthy within %s", s.cfg.StartupTimeout)
		case <-time.After(s.cfg.HealthPoll):
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return err
		}
		resp, err := s.hc.Do(req)
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}
	}
}

// idleLoop stops the engine after IdleStop with no live guard.
func (s *Supervisor) idleLoop() {
	defer close(s.idleDone)
	t := time.NewTicker(s.cfg.IdleTick)
	defer t.Stop()
	for {
		select {
		case <-s.stopIdle:
			return
		case <-t.C:
		}
		s.mu.Lock()
		idle := s.state == StateReady &&
			s.child != nil && !s.child.userStop &&
			s.guards == 0 &&
			time.Since(s.lastActivity) >= s.cfg.IdleStop
		if !idle {
			s.mu.Unlock()
			continue
		}
		c := s.child
		c.userStop = true
		s.state = StateStopped
		s.failCount = 0 // a clean idle stop clears crash/start backoff
		s.broadcastLocked()
		s.mu.Unlock()
		s.log.Info("engine idle, stopping", slog.Duration("idle_stop", s.cfg.IdleStop))
		s.killChild(c)
	}
}

// killChild terminates c: SIGTERM, then SIGKILL after KillGrace. Returns when
// the process has exited.
func (s *Supervisor) killChild(c *child) {
	s.mu.Lock()
	c.userStop = true
	s.mu.Unlock()
	if c.cmd.Process != nil {
		_ = c.cmd.Process.Signal(syscall.SIGTERM)
	}
	select {
	case <-c.done:
		return
	case <-time.After(s.cfg.KillGrace):
	}
	s.log.Warn("engine did not exit on SIGTERM; killing", slog.Int("pid", c.cmd.Process.Pid))
	_ = c.cmd.Process.Kill()
	select {
	case <-c.done:
	case <-time.After(s.cfg.KillGrace):
		s.log.Error("engine uninterruptible after SIGKILL", slog.Int("pid", c.cmd.Process.Pid))
	}
}

// openEngineLog opens the child log, truncating it first when it exceeds the
// configured cap.
func (s *Supervisor) openEngineLog() (*os.File, error) {
	if err := os.MkdirAll(s.cfg.LogDir, 0o755); err != nil {
		return nil, fmt.Errorf("engine: log dir: %w", err)
	}
	name := s.cfg.LogName
	if name == "" {
		name = "engine.log"
	}
	p := filepath.Join(s.cfg.LogDir, name)
	if st, err := os.Stat(p); err == nil && st.Size() > s.cfg.LogMaxBytes {
		if err := os.Truncate(p, 0); err != nil {
			return nil, fmt.Errorf("engine: truncate log: %w", err)
		}
	}
	return os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
}

// Pidfile format since v0.1.7: "<pid> <start-token>", where the token is the
// child's opaque processStartTime stamp — it distinguishes the spawned
// engine from a process that later recycled the pid. v0.1.6 and earlier
// wrote a bare "<pid>", which a v0.1.6 reader must not misparse: its
// strconv.Atoi on the whole content fails on the two-field line, so an old
// binary ignores a new-format file instead of reading a wrong pid.
func (s *Supervisor) writePidFile(pid int) {
	if s.cfg.PidPath == "" {
		return
	}
	if err := os.MkdirAll(filepath.Dir(s.cfg.PidPath), 0o755); err != nil {
		s.log.Warn("engine: pidfile dir", slog.Any("error", err))
		return
	}
	// A token read failure degrades to the bare-pid format rather than
	// leaving the spawned engine without a reapable pidfile — the reaper
	// then falls back to the exe-only rule, as for an old-format file.
	content := strconv.Itoa(pid)
	if token, err := processStartTime(pid); err == nil {
		content += " " + token
	} else {
		s.log.Warn("engine: cannot read child start time; pidfile carries a bare pid",
			slog.Int("pid", pid), slog.Any("error", err))
	}
	if err := os.WriteFile(s.cfg.PidPath, []byte(content+"\n"), 0o644); err != nil {
		s.log.Warn("engine: write pidfile", slog.Any("error", err))
	}
}

// parsePidFile decodes the pidfile content: "<pid> <start-token>" in the
// current format, or a bare "<pid>" — a v0.1.6-and-earlier file, reported
// with an empty token.
func parsePidFile(data []byte) (pid int, token string, ok bool) {
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return 0, "", false
	}
	pid, err := strconv.Atoi(fields[0])
	if err != nil || pid <= 0 {
		return 0, "", false
	}
	if len(fields) > 1 {
		token = fields[1]
	}
	return pid, token, true
}

// removePidFile removes the pidfile only if it still names pid, matching on
// the pid field alone whether or not a start token follows it.
func (s *Supervisor) removePidFile(pid int) {
	if s.cfg.PidPath == "" {
		return
	}
	data, err := os.ReadFile(s.cfg.PidPath)
	if err != nil {
		return
	}
	if filePid, _, ok := parsePidFile(data); ok && filePid == pid {
		_ = os.Remove(s.cfg.PidPath)
	}
}

// reapOrphan kills a leftover engine from a previous daemon run: the pidfile
// names a live process whose executable is still the configured binary and,
// for pidfiles carrying a start token, whose start time still matches it.
func (s *Supervisor) reapOrphan() {
	if s.cfg.PidPath == "" {
		return
	}
	data, err := os.ReadFile(s.cfg.PidPath)
	if err != nil {
		return
	}
	pid, token, ok := parsePidFile(data)
	if !ok {
		return
	}
	if !processAlive(pid) {
		_ = os.Remove(s.cfg.PidPath)
		return
	}
	exe, err := processExe(pid)
	if err != nil {
		s.log.Warn("engine: cannot verify orphan exe; leaving pid running",
			slog.Int("pid", pid), slog.Any("error", err))
		return
	}
	// /proc reports a replaced binary as "<path> (deleted)".
	exe = strings.TrimSuffix(exe, " (deleted)")
	want, _ := filepath.Abs(s.cfg.Bin)
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	if resolved, err := filepath.EvalSymlinks(want); err == nil {
		want = resolved
	}
	// Only an exact exec-path match counts: a reused pid that merely shares
	// the binary's name must never be killed.
	if exe != want {
		return
	}
	// A new-format pidfile also records the spawned child's start-time
	// token: the pid must still belong to that same process instance, or it
	// is a recycled pid on a same-binary process (a hand-started engine, a
	// second home sharing the binary) and must be left running. A bare pid
	// — a v0.1.6-and-earlier pidfile — has no token and keeps the exe-only
	// rule, so an upgrade still reaps the previous version's orphan.
	if token != "" {
		start, err := processStartTime(pid)
		if err != nil {
			s.log.Warn("engine: cannot verify orphan start time; leaving pid running",
				slog.Int("pid", pid), slog.Any("error", err))
			return
		}
		if start != token {
			return
		}
	}
	s.log.Info("killing orphaned engine", slog.Int("pid", pid))
	_ = syscall.Kill(pid, syscall.SIGTERM)
	deadline := time.Now().Add(s.cfg.KillGrace)
	for time.Now().Before(deadline) && processAlive(pid) {
		time.Sleep(50 * time.Millisecond)
	}
	if processAlive(pid) {
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
	_ = os.Remove(s.cfg.PidPath)
}

func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
