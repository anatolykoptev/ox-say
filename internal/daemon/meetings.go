package daemon

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
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
// The bearer key is written to a 0600 file per spawn — an argv is readable by
// every process of the machine, and the server's CORS is open to any web page.
// Layers go to the GPU only with unified memory; a discrete card stays with
// the speech engines.
func notesServerArgs(cfg *config.Config, port int, log *slog.Logger) []string {
	args := []string{
		"-m", cfg.NotesModel, "-c", strconv.Itoa(notesCtx),
		"--host", voxLoopbackHost, "--port", strconv.Itoa(port),
		"-fa", "on", "--jinja", "--no-ui", "-np", "1", "--cache-ram", "0",
	}
	ngl := "0"
	if cfg.UnifiedMemory() {
		ngl = "99"
	}
	args = append(args, "-ngl", ngl)
	keyPath := filepath.Join(cfg.RunDir(), notesKeyFile)
	if err := writeNotesKey(keyPath); err != nil {
		// The flag still names the file: the server refuses to start on a
		// missing key file, so a failed write fails the start instead of
		// running the server open.
		log.Error("notes: cannot write the server key", slog.Any("error", err))
	}
	return append(args, "--api-key-file", keyPath)
}

// writeNotesKey writes a fresh random bearer key, 0600.
func writeNotesKey(path string) error {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(hex.EncodeToString(b[:])+"\n"), 0o600)
}

// newLLMSupervisor builds the notes server's supervisor. The child holds
// 4-7 GB while loaded, so a short idle stop returns it to zero between meetings.
func newLLMSupervisor(cfg *config.Config, logger *slog.Logger) (*engine.Supervisor, error) {
	return engine.New(engine.Config{
		Name:           "notes",
		Bin:            notesBinPath(cfg),
		Port:           cfg.NotesPort,
		StartupTimeout: notesStartupTimeout,
		IdleStop:       cfg.NotesIdleStop,
		LogName:        "notes.log",
		LogDir:         cfg.EngineLogDir,
		PidPath:        filepath.Join(cfg.RunDir(), "notes.pid"),
		Logger:         logger,
		Args:           func(port int) []string { return notesServerArgs(cfg, port, logger) },
	})
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
		return "", fmt.Errorf("the notes model failed to start: %w", err)
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
	return strings.TrimSpace(string(raw)), err
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
}

func (n *notesInstall) state() (running bool, err string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.running, n.err
}

// ErrNotesInstall is a refusal to start the notes model download.
var ErrNotesInstall = errors.New("notes model download")

// InstallNotesModel downloads the notes model by running the installed
// fetch-models.sh --notes-only: the one place that knows the model's URL and
// SHA-256. It returns at once; /status reports the progress.
func (d *Daemon) InstallNotesModel() error {
	if code, reason := d.Cfg.NotesBlock(); code == "" {
		return fmt.Errorf("%w: the notes model is already installed", ErrNotesInstall)
	} else if code == config.NotesReasonUnsupported || code == config.NotesReasonEngineMissing {
		return fmt.Errorf("%w: %s", ErrNotesInstall, reason)
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
	if free, err := freeBytes(dest); err == nil && free < config.NotesModelBytes+notesDiskMargin {
		return fmt.Errorf("%w: not enough free disk space: %d GB needed, %d GB free",
			ErrNotesInstall, (config.NotesModelBytes+notesDiskMargin)>>30+1, free>>30)
	}
	// Single-flight under the lock (#225): two concurrent requests must not
	// run two fetch processes appending to the same .part file.
	d.notes.mu.Lock()
	if d.notes.running {
		d.notes.mu.Unlock()
		return fmt.Errorf("%w: a download is already running", ErrNotesInstall)
	}
	d.notes.running, d.notes.err = true, ""
	d.notes.mu.Unlock()
	go d.runNotesInstall(script, dest)
	return nil
}

func (d *Daemon) runNotesInstall(script, dest string) {
	cmd := exec.Command(script, "--notes-only", dest)
	var tail bytes.Buffer
	cmd.Stderr = &tail
	err := cmd.Run()
	d.notes.mu.Lock()
	defer d.notes.mu.Unlock()
	d.notes.running = false
	if err != nil {
		msg := strings.TrimSpace(tail.String())
		if len(msg) > 300 {
			msg = msg[len(msg)-300:]
		}
		d.notes.err = "The download failed: " + msg
		d.log.Warn("notes model download failed", slog.Any("error", err), slog.String("stderr", msg))
	}
}

func freeBytes(dir string) (int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, err
	}
	return int64(st.Bavail) * int64(st.Bsize), nil
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
