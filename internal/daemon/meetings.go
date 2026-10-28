package daemon

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/anatolykoptev/ox-say/internal/stt"
)

const (
	// notesCtx is the context the notes spike measured (-c 16384): a 16k-character
	// chunk plus a 3k-token answer fits with room to spare.
	notesCtx = 16384
	// notesStartupTimeout: loading a 2.7 GB model is seconds when cached, tens
	// of seconds cold.
	notesStartupTimeout = 120 * time.Second
	// notesCallTimeout bounds one model call: 5k prompt tokens plus 3k tokens
	// of answer took 11 s on an M-series Mac; CPU-only Intel is far slower.
	notesCallTimeout = 20 * time.Minute
	// notesDiskMargin is the free space kept beyond the model download.
	notesDiskMargin = 512 << 20
	// meetingHousekeepEvery: orphaned recordings and retention are checked this
	// often. It must stay under half of staleRecording (3 min) minus a flush.
	meetingHousekeepEvery = time.Minute
	// notesKeyFile is the per-spawn bearer key of the local model server.
	notesKeyFile = "notes.key"
	// fetchModelsScript is where install-release.sh copies scripts/fetch-models.sh.
	fetchModelsScript = "fetch-models.sh"
)

const stateNotesUnavailable engine.State = "unavailable"

// notesReasonEngineFailed is the reason_code of /status notes while the last
// start was refused by the server check.
const notesReasonEngineFailed = "notes_engine_failed"

// notesStatus is the /status "notes" value: whether meeting notes can run,
// and the model download's progress.
type notesStatus struct {
	Available   bool         `json:"available"`
	Reason      string       `json:"reason,omitempty"`
	ReasonCode  string       `json:"reason_code,omitempty"`
	State       engine.State `json:"state"`
	LastErr     string       `json:"last_error,omitempty"`
	Installing  bool         `json:"installing,omitempty"`
	ProgressPct int          `json:"progress_pct,omitempty"`
	InstallErr  string       `json:"install_error,omitempty"`
}

// notesBinPath is the path ox-llm is spawned by: always absolute, because the
// binary finds its Metal library next to argv[0] and a relative path would
// resolve against the daemon's working directory, not the install (#238).
// The default NotesBin already is (filepath.Join(engineDir, "ox-llm")); an
// explicit OX_SAY_NOTES_BIN may not be.
func notesBinPath(cfg *config.Config) string {
	if abs, err := filepath.Abs(cfg.NotesBin); err == nil {
		return abs
	}
	return cfg.NotesBin
}

// notesServerArgs is ox-llm's argv: llama-server as the notes spike ran it.
// The bearer key is a 0600 file written per spawn by notesPrepare — an argv is
// readable by every process of the machine. CORS is limited to localhost
// origins (v0.7.0's special value): the default is "*", which would let any web
// page the user opens talk to the server. Layers go to the GPU only with
// unified memory; a discrete card stays with the speech engines.
func notesServerArgs(cfg *config.Config, port int) []string {
	args := []string{
		"-m", cfg.NotesModel, "-c", strconv.Itoa(notesCtx),
		"--host", voxLoopbackHost, "--port", strconv.Itoa(port),
		"-fa", "on", "--jinja", "--no-ui", "-np", "1", "--cache-ram", "0",
		"--cors-origins", "localhost",
	}
	ngl := "0"
	if cfg.UnifiedMemory() {
		ngl = "99"
	}
	args = append(args, "-ngl", ngl)
	return append(args, "--api-key-file", filepath.Join(cfg.RunDir(), notesKeyFile))
}

// notesKeyWrite puts the key bytes into the open temp file; a test replaces it
// to fail or corrupt the write.
var notesKeyWrite = func(f *os.File, key []byte) error {
	_, err := f.Write(key)
	return err
}

// notesPortTaken marks the start failure for a notes port another process
// holds; /status turns it into the port_blocked reason.
const notesPortTaken = "is in use by another process"

// notesPrepare runs before every ox-llm spawn. llama-server reads the key file
// at start: a missing file stops it, but an EMPTY one yields zero keys and the
// server then runs with no auth at all — so the file must be written whole or
// not exist, and is checked before the child is spawned. The port is checked
// too: whatever else answered on it would receive the private meeting text.
func notesPrepare(cfg *config.Config) error {
	ln, err := net.Listen("tcp", net.JoinHostPort(voxLoopbackHost, strconv.Itoa(cfg.NotesPort)))
	if err != nil {
		return fmt.Errorf("notes: port %d %s; set OX_SAY_NOTES_PORT to a free port", cfg.NotesPort, notesPortTaken)
	}
	_ = ln.Close()
	keyPath := filepath.Join(cfg.RunDir(), notesKeyFile)
	if err := writeNotesKey(keyPath); err != nil {
		return fmt.Errorf("notes: cannot write the server key: %w", err)
	}
	if err := checkNotesKey(keyPath); err != nil {
		_ = os.Remove(keyPath)
		return fmt.Errorf("notes: %w; not starting the server", err)
	}
	return nil
}

// writeNotesKey writes a fresh random bearer key, 0600, into a run dir that
// only this user can enter. The key goes to a temp file (created exclusively,
// never through a symlink) that replaces notes.key by rename, so a failed or
// interrupted write never leaves a truncated key; on any error notes.key is
// removed, so the start fails instead of running on a stale or empty key.
func writeNotesKey(path string) (err error) {
	defer func() {
		if err != nil {
			_ = os.Remove(path)
		}
	}()
	var b [32]byte
	if _, err = rand.Read(b[:]); err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err = os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err = os.Chmod(dir, 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	_ = os.Remove(tmp) // a leftover from a killed run, or a planted link
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	err = notesKeyWrite(f, []byte(hex.EncodeToString(b[:])+"\n"))
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		_ = os.Remove(tmp)
	}
	return err
}

// checkNotesKey refuses a key file the server must not be started with: not a
// plain file, not 0600, or holding no key.
func checkNotesKey(path string) error {
	st, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("the server key is unreadable: %w", err)
	}
	if !st.Mode().IsRegular() {
		return errors.New("the server key is not a regular file")
	}
	if st.Mode().Perm() != 0o600 {
		return fmt.Errorf("the server key has mode %o, want 600", st.Mode().Perm())
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("the server key is unreadable: %w", err)
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return errors.New("the server key is empty")
	}
	return nil
}

// notesVerifyAuth runs once the server reports healthy. /v1/models needs the
// key (only /health and the UI are public), so a keyless request must be
// answered 401; anything else means the server runs open — to every local
// process and, through CORS, to web pages — and the start fails.
func notesVerifyAuth(ctx context.Context, baseURL string) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/v1/models", nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("notes: cannot check the server requires its key: %w", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		return fmt.Errorf("notes: the server answered %d to a request without its key; it is running open", resp.StatusCode)
	}
	return nil
}

// newLLMSupervisor builds the notes server's supervisor. The child holds
// 4-7 GB while loaded, so a short idle stop returns it to zero between meetings.
func newLLMSupervisor(cfg *config.Config, logger *slog.Logger) (*engine.Supervisor, error) {
	return engine.New(notesEngineConfig(cfg, logger))
}

// notesEngineConfig is the notes supervisor's configuration; tests tune it.
func notesEngineConfig(cfg *config.Config, logger *slog.Logger) engine.Config {
	return engine.Config{
		Name:           "notes",
		Bin:            notesBinPath(cfg),
		Port:           cfg.NotesPort,
		StartupTimeout: notesStartupTimeout,
		IdleStop:       cfg.NotesIdleStop,
		LogName:        "notes.log",
		LogDir:         cfg.EngineLogDir,
		PidPath:        filepath.Join(cfg.RunDir(), "notes.pid"),
		Logger:         logger,
		Args:           func(port int) []string { return notesServerArgs(cfg, port) },
		Prepare:        func() error { return notesPrepare(cfg) },
		Verify:         notesVerifyAuth,
	}
}

// llmChat is the meeting.Chat over the supervised local server: it takes the
// engine guard, starts the server on demand, waits its /health so a model
// still loading does not spend the composer's chunk retries on 503s (#235),
// and sends the call.
type llmChat struct{ d *Daemon }

func (c llmChat) Complete(ctx context.Context, r meeting.Request) (string, error) {
	if c.d.LLMSup == nil {
		return "", errors.New("the notes engine is not configured")
	}
	g := c.d.LLMSup.Acquire()
	defer g.Release()
	base, err := c.d.LLMSup.EnsureReady(ctx)
	if err != nil {
		err = fmt.Errorf("the notes model failed to start: %w", err)
		if ctx.Err() != nil {
			return "", err
		}
		// Not the transcript's fault, so Compose must not go on chunk after
		// chunk (each try loads the model) and the meeting records this text.
		// A verify refusal or a shutdown will repeat: stop at once. A health
		// timeout or a crashed child often succeeds on a second start (the
		// model is then in the page cache): Compose may start once more.
		return "", &meeting.EngineDownError{Err: err, Retryable: !engine.IsVerifyRefusal(err) && !errors.Is(err, engine.ErrShutdown)}
	}
	ctx, cancel := context.WithTimeout(ctx, notesCallTimeout)
	defer cancel()
	return meeting.HTTPChat{BaseURL: base, Key: c.d.notesKey}.Complete(ctx, r)
}

// notesKey reads the bearer the current spawn's --api-key-file names. The
// file is rewritten per spawn; reading it per call always matches the live
// child.
func (d *Daemon) notesKey() (string, error) {
	raw, err := os.ReadFile(filepath.Join(d.Cfg.RunDir(), notesKeyFile))
	key := strings.TrimSpace(string(raw))
	if err == nil && key == "" {
		err = errors.New("the notes server key is empty")
	}
	return key, err
}

// initMeetings builds the meeting store and runner. The runner uses the same
// recognizer as dictation (Transcribe), yields to dictation between calls
// (waitQuiet), asks the notes engine's config whether it can run, and leaves
// meetings waiting on a missing STT model alone until the model lands.
func (d *Daemon) initMeetings() {
	d.Meet = meeting.NewRunner(meeting.Deps{
		Store: &meeting.Store{Root: filepath.Join(d.Cfg.Home, "meetings"), Log: d.log},
		Transcribe: func(ctx context.Context, wav string) (*stt.Result, error) {
			return d.Transcribe(ctx, TranscribeInput{AudioPath: wav})
		},
		Chat:       llmChat{d: d},
		NotesReady: func() string { code, _ := d.Cfg.NotesBlock(); return code },
		TranscribeReady: func() string {
			if _, err := os.Stat(d.Cfg.STTModel); err != nil {
				return meeting.WaitSTTModel
			}
			return ""
		},
		Before: func(ctx context.Context) error { return d.waitQuiet(ctx, func() {}) },
		Log:    d.log,
		// The far side's voices (Task 20): ox-diar when this Mac can run it, one label and a reason when not.
		Diarize:      d.diarizer,
		DiarizeReady: d.diarReady,
		// Without unified memory the recognizer runs on the CPU, far slower than
		// real time, and one call holds it for dictation too: short pieces.
		PieceSeconds: d.pieceSeconds(),
	})
}

// cpuPieceSeconds is the recognizer piece length on a Mac without unified memory.
const cpuPieceSeconds = 45

func (d *Daemon) pieceSeconds() int {
	if d.Cfg.UnifiedMemory() {
		return meeting.DefaultPieceSeconds
	}
	return cpuPieceSeconds
}

// StartMeetings starts the meeting runner and its housekeeping. Call it once
// the daemon is built; StopMeetings ends both.
func (d *Daemon) StartMeetings() {
	if d.meetCancel != nil {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	d.meetCancel = cancel
	d.meetDone = make(chan struct{}, 2)
	go func() { d.Meet.Run(ctx); d.meetDone <- struct{}{} }()
	go func() { d.Meet.Housekeep(ctx, meetingHousekeepEvery); d.meetDone <- struct{}{} }()
}

// StopMeetings stops the runner. A job in flight is cancelled and stays
// resumable: its meeting keeps its status and the next start picks it up.
func (d *Daemon) StopMeetings() {
	if d.meetCancel == nil {
		return
	}
	d.meetCancel()
	<-d.meetDone
	<-d.meetDone
	d.meetCancel = nil
}

// notesInstall is the one running model download.
type notesInstall struct {
	mu      sync.Mutex
	running bool
	err     string
	// ctx ends the download with the daemon: Shutdown cancels it and waits on wg.
	ctx     context.Context
	cancel  context.CancelFunc
	stopped bool
	wg      sync.WaitGroup
}

func (n *notesInstall) state() (running bool, err string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.running, n.err
}

// ErrNotesInstall is a refusal to start the notes model download.
var ErrNotesInstall = errors.New("notes model download")

// freeBytes is the free space under dir; a test replaces it.
var freeBytes = func(dir string) (int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, err
	}
	return int64(st.Bavail) * int64(st.Bsize), nil
}

// lockPart takes the exclusive lock that marks a download in progress for a
// model file. The download process inherits the descriptor, so the lock lives
// as long as the fetch does — also when the daemon that started it is gone.
func lockPart(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		return nil, err
	}
	return f, nil
}

// InstallNotesModel downloads the notes model by running the installed
// fetch-models.sh --notes-only: the one place that knows the model's URL and
// SHA-256. It returns at once; /status reports the progress. The download
// belongs to the daemon: Shutdown kills it, and a lock next to the .part file
// keeps a second daemon from starting a second writer on it.
func (d *Daemon) InstallNotesModel() error {
	if code, reason := d.Cfg.NotesBlock(); code == config.NotesReasonUnsupported || code == config.NotesReasonEngineMissing {
		return fmt.Errorf("%w: %s", ErrNotesInstall, reason)
	}
	if st, err := os.Stat(d.Cfg.NotesModel); err == nil && st.Mode().IsRegular() {
		return fmt.Errorf("%w: the notes model is already installed", ErrNotesInstall)
	}
	if filepath.Base(d.Cfg.NotesModel) != config.NotesModelFile {
		// The script writes the pinned file name; a model at another path is the
		// user's own and is never downloaded over.
		return fmt.Errorf("%w: OX_SAY_NOTES_MODEL names a different file; place the model there yourself", ErrNotesInstall)
	}
	script := filepath.Join(d.Cfg.Home, fetchModelsScript)
	if _, err := os.Stat(script); err != nil {
		return fmt.Errorf("%w: %s is missing; reinstall ox-say", ErrNotesInstall, fetchModelsScript)
	}
	dest := filepath.Dir(d.Cfg.NotesModel)
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return fmt.Errorf("%w: %v", ErrNotesInstall, err)
	}
	if err := d.checkNotesDisk(dest); err != nil {
		return err
	}
	// Single-flight under the lock (#225): two concurrent requests must not
	// run two fetch processes appending to the same .part file.
	d.notes.mu.Lock()
	defer d.notes.mu.Unlock()
	if d.notes.stopped {
		return fmt.Errorf("%w: the daemon is shutting down", ErrNotesInstall)
	}
	if d.notes.running {
		return fmt.Errorf("%w: a download is already running", ErrNotesInstall)
	}
	lock, err := lockPart(d.Cfg.NotesModel + ".part.lock")
	if err != nil {
		return fmt.Errorf("%w: a download is already running (another ox-say owns the .part file)", ErrNotesInstall)
	}
	if d.notes.ctx == nil {
		d.notes.ctx, d.notes.cancel = context.WithCancel(context.Background())
	}
	cmd := exec.CommandContext(d.notes.ctx, script, "--notes-only", dest)
	var tail bytes.Buffer
	cmd.Stderr = &tail
	// The fetch gets the lock as fd 3 and its own process group, so killing it
	// takes curl with it.
	cmd.ExtraFiles = []*os.File{lock}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	if err := cmd.Start(); err != nil {
		_ = lock.Close()
		return fmt.Errorf("%w: %v", ErrNotesInstall, err)
	}
	_ = lock.Close() // the child's copy keeps the lock
	d.notes.running, d.notes.err = true, ""
	d.notes.wg.Add(1)
	go d.runNotesInstall(d.notes.ctx, cmd, &tail)
	return nil
}

// checkNotesDisk refuses a download the disk cannot hold. A .part file from an
// earlier try already counts; a disk whose free space cannot be read does not
// block the download (the fetch itself fails loudly on a full disk), but the
// log says the check was skipped.
func (d *Daemon) checkNotesDisk(dest string) error {
	need := int64(config.NotesModelBytes + notesDiskMargin)
	if st, err := os.Stat(d.Cfg.NotesModel + ".part"); err == nil {
		need -= min(st.Size(), int64(config.NotesModelBytes))
	}
	free, err := freeBytes(dest)
	if err != nil {
		d.log.Warn("notes model download: cannot read the free disk space, downloading without the check", slog.Any("error", err))
		return nil
	}
	if free < need {
		return fmt.Errorf("%w: not enough free disk space: %d GB needed, %d GB free",
			ErrNotesInstall, need>>30+1, free>>30)
	}
	return nil
}

func (d *Daemon) runNotesInstall(ctx context.Context, cmd *exec.Cmd, tail *bytes.Buffer) {
	defer d.notes.wg.Done()
	err := cmd.Wait()
	d.notes.mu.Lock()
	defer d.notes.mu.Unlock()
	d.notes.running = false
	if err != nil && ctx.Err() == nil {
		msg := installTail(tail.String())
		d.notes.err = "The download failed: " + msg
		d.log.Warn("notes model download failed", slog.Any("error", err), slog.String("stderr", msg))
	}
}

// installTail is the last words of a fetch's stderr for a person: a progress
// meter redraws one line with carriage returns, so each line keeps only its
// final redraw, and empty lines go.
func installTail(raw string) string {
	var lines []string
	for _, line := range strings.Split(raw, "\n") {
		if i := strings.LastIndex(strings.TrimRight(line, "\r"), "\r"); i >= 0 {
			line = line[i+1:]
		}
		if line = strings.TrimSpace(line); line != "" {
			lines = append(lines, line)
		}
	}
	msg := strings.Join(lines, "; ")
	if len(msg) > 300 {
		msg = msg[len(msg)-300:]
	}
	return msg
}

// StopNotesInstall ends a running model download with the daemon and waits for
// it; the .part file stays and the next download resumes it. Shutdown calls it.
func (d *Daemon) StopNotesInstall() {
	d.notes.mu.Lock()
	d.notes.stopped = true
	if d.notes.cancel != nil {
		d.notes.cancel()
	}
	d.notes.mu.Unlock()
	d.notes.wg.Wait()
}

// notesStatus reports the notes engine for /status. A runtime start failure
// surfaces as the supervisor's state plus last_error — never as
// "unsupported", which is a config-level judgement (#243).
func (d *Daemon) notesStatus() notesStatus {
	running, ierr := d.notes.state()
	out := notesStatus{Installing: running, InstallErr: ierr}
	if running {
		if st, err := os.Stat(d.Cfg.NotesModel + ".part"); err == nil {
			out.ProgressPct = int(min(99, st.Size()*100/config.NotesModelBytes))
		}
	}
	if code, reason := d.Cfg.NotesBlock(); reason != "" {
		out.State, out.Reason, out.ReasonCode = stateNotesUnavailable, reason, code
		return out
	}
	out.Available, out.State = true, engine.StateStopped
	if d.LLMSup != nil {
		st := d.LLMSup.Status()
		out.State, out.LastErr = st.State, st.LastErr
		if st.State == engine.StateFailed {
			// The last start was refused by the server check; say so instead of
			// showing a plain "stopped". Informational: a notes retry starts the
			// engine again (after the short backoff) and a success clears it.
			out.ReasonCode = notesReasonEngineFailed
			out.Reason = "The notes model did not start: its server check failed. Retry the notes to try again."
		}
		if strings.Contains(st.LastErr, notesPortTaken) {
			// A foreign listener holds the port: the app shows the same reason
			// as for a configured collision, and the meetings wait.
			out.Available, out.ReasonCode = false, config.NotesReasonPortBlocked
			out.Reason = fmt.Sprintf("The notes port %d is taken by another program; set OX_SAY_NOTES_PORT to a free port.", d.Cfg.NotesPort)
		}
	}
	return out
}

// notesInstalling is 1 while the notes model downloads.
func (d *Daemon) notesInstalling() int {
	if running, _ := d.notes.state(); running {
		return 1
	}
	return 0
}
