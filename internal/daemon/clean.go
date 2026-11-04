package daemon

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/oneshot"
	"github.com/anatolykoptev/ox-say/internal/voiceclean"
)

// Voice cleanup is an offline, user-chosen file-in/file-out tool. It is never applied to meetings or dictation:
// Forbidden below is the whole guarantee on the route side (internal/voiceclean compares resolved paths and file
// identity, so a symlink or a hard link into the meetings directory is refused too), and dictation and live meetings
// never wait for it (see waitCleanQuiet and waitQuiet).
const (
	// cleanMinMacOS equals engine/clean Platform.minimumMajor; TestCleanMinMacOSMatchesTheHelper reads Platform.swift.
	cleanMinMacOS = 15
	// cleanMinTimeout bounds one ox-clean run from below: the first run compiles the model's GPU kernels.
	cleanMinTimeout = 5 * time.Minute
	// cleanWet is the default share of the cleaned voice (15 % of the original stays in).
	cleanWet = 0.85
	// The per-plan speed floors of engine/clean SpeedFloor, in times real time; TestCleanSpeedFloorsMatchTheHelper
	// reads ComputePlan.swift. The timeout allows half the floor.
	cleanFloorAppleGPU     = 50.0
	cleanFloorIntelDGPU    = 5.0
	cleanFloorIntelCPUOnly = 2.0
	// cleanOuterCap bounds everything that is not the model (ffprobe, ffmpeg): a hung tool must not hold the lane.
	cleanOuterCap = 3 * time.Hour
	// cleanBytesPerSecond is the model's float32 mono 48 kHz WAV.
	cleanBytesPerSecond = 48000 * 4
	// cleanStderrKeep is how much of ox-clean's stderr an error carries (its last line holds [reason=<token>]).
	cleanStderrKeep = 2048
	cleanWaitDelay  = 5 * time.Second
	// cleanVersionTimeout bounds `ox-clean --version`.
	cleanVersionTimeout = 10 * time.Second
)

// Codes of the readiness check and of the lazy model download.
const (
	CleanOSTooOld          = "os_too_old"
	CleanEngineMissing     = "engine_missing"
	CleanModelsMissing     = "models_missing"
	CleanModelsDownloading = "models_downloading"
	CleanBusy              = "busy"
)

// Seams for tests: the wait for a quiet daemon.
var (
	// cleanQuietCap is how long a cleanup waits for dictation and other jobs to end before it answers 503 busy.
	cleanQuietCap  = 120 * time.Second
	cleanQuietPoll = 250 * time.Millisecond
)

// cleanReady is why this Mac cannot clean a file now, "" when it can: an old macOS first (a system that will not say
// its version is treated as old, like diarReady), then a missing engine, then a missing model. Intel is enabled
// (plan, decision 8): there is no CPU check.
func (d *Daemon) cleanReady() (code, reason string) {
	if major, ok := osMajor(); !ok || major < cleanMinMacOS {
		return CleanOSTooOld, "Voice cleanup needs macOS 15 or later."
	}
	if st, err := os.Stat(d.Cfg.CleanBin); err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0o111 == 0 {
		return CleanEngineMissing, "The voice cleanup engine is not installed. Reinstall OxSay."
	}
	if !d.Cfg.CleanModelsReady() {
		return CleanModelsMissing, "The voice cleanup model has not been downloaded yet (about 131 MB)."
	}
	return "", ""
}

// cleanFloor is the speed floor (times real time) the timeout is sized on. The daemon cannot tell an Intel Mac with a
// discrete GPU from one with only an integrated GPU, so every Intel Mac gets the cpuOnly floor, the slowest.
func cleanFloor() float64 {
	if goArch == "amd64" {
		return cleanFloorIntelCPUOnly
	}
	return cleanFloorAppleGPU
}

// cleanTimeout is how long ox-clean may take on audioSeconds of audio: twice the time the floor speed needs, never
// under cleanMinTimeout.
func cleanTimeout(audioSeconds float64) time.Duration {
	return max(cleanMinTimeout, time.Duration(audioSeconds/(cleanFloor()/2)*float64(time.Second)))
}

// CleanInput is one cleanup request.
type CleanInput struct {
	InPath, OutPath string
	Wet             *float64 // nil = cleanWet; a present 0 is honoured
	Stereo          string
	Overwrite       bool
}

// CleanDropped is an input stream the output leaves out.
type CleanDropped struct {
	Index int    `json:"index"`
	Type  string `json:"type"`
	Codec string `json:"codec"`
}

// CleanResult is the 200 body of POST /v1/audio/clean.
type CleanResult struct {
	OutPath        string         `json:"out_path"`
	Video          bool           `json:"video"`
	InputSeconds   float64        `json:"input_seconds"`
	ElapsedSeconds float64        `json:"elapsed_s"`
	Wet            float64        `json:"wet"`
	Stereo         string         `json:"stereo,omitempty"`
	SampleRate     int            `json:"sample_rate"`
	Channels       int            `json:"channels"`
	LagMs          float64        `json:"lag_ms"`
	Dropped        []CleanDropped `json:"dropped"`
}

// CleanError is a refused or failed cleanup: a stable Code, one plain English sentence, the HTTP status, and for a
// failed engine its reason token. The app localises the sentence later; it matches on Code.
type CleanError struct {
	Status int
	Code   string
	Msg    string
	Reason string // ox-clean's [reason=<token>], when it said one
}

func (e *CleanError) Error() string { return e.Code + ": " + e.Msg }

func busyErr() *CleanError {
	return &CleanError{Status: http.StatusConflict, Code: CleanBusy, Msg: "Another file is being cleaned. Wait for it to finish."}
}

// quietBusy counts the work that must not share the GPU with a cleanup: a voiceover job rendering, an open dictation
// session, speech and voice design in flight, transcription, interactive requests, and a recorded meeting that is
// queued or running (its transcription, diarisation and notes). It is d.busy() minus what is not GPU work: the
// notes-model download (disk and network), and the cleanup itself.
func (d *Daemon) quietBusy() int {
	b := d.busy()
	n := b.Produce + b.STTSessions + b.Speaking + b.Designing + b.Transcribing + b.Interactive
	if d.Meet != nil {
		n += d.Meet.Active()
	}
	return n
}

// waitCleanQuiet blocks until quietBusy is 0, polling like waitQuiet, for at most cleanQuietCap; then it answers 503
// busy. Racy by design: a job that starts right after the check shares the GPU for a few seconds, and nothing
// interactive ever waits for a cleanup.
func (d *Daemon) waitCleanQuiet(ctx context.Context) error {
	deadline := time.Now().Add(cleanQuietCap)
	for d.quietBusy() > 0 {
		if !time.Now().Before(deadline) {
			return &CleanError{Status: http.StatusServiceUnavailable, Code: CleanBusy,
				Msg: "OxSay is busy with dictation or another job; try again in a moment."}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(cleanQuietPoll):
		}
	}
	return nil
}

// cleanGate runs once per cleanup, at the first step that uses the GPU (so a request that is refused for its paths or
// its media never waits): it waits for a quiet daemon, takes the GPU lease on a Mac that arbitrates one, and tells
// waitQuiet that a cleanup is running so a voiceover job does not start a render beside it.
type cleanGate struct {
	d       *Daemon
	once    sync.Once
	err     error
	release func()
}

func (g *cleanGate) enter(ctx context.Context) error {
	g.once.Do(func() {
		if g.err = g.d.waitCleanQuiet(ctx); g.err != nil {
			return
		}
		// A Mac without unified memory (Intel) arbitrates its GPU with a lease: the TTS child holds it for its whole
		// life, and a GPU transcription takes it per run (try-only, so it falls back to the CPU). The daemon cannot tell
		// a discrete GPU from an integrated one, so the lease is taken whenever the existing arbitration is in force;
		// it is the same condition under which the TTS engine and STT use it.
		if !g.d.Cfg.UnifiedMemory() {
			lctx, cancel := context.WithTimeout(ctx, cleanQuietCap)
			ok, err := g.d.gpu.WaitOrAs(lctx, nil, "clean")
			cancel()
			if err != nil || !ok {
				if ctx.Err() != nil {
					g.err = ctx.Err()
				} else {
					g.err = &CleanError{Status: http.StatusServiceUnavailable, Code: CleanBusy,
						Msg: "OxSay is busy with dictation or another job; try again in a moment."}
				}
				return
			}
			g.release = g.d.gpu.Release
		}
		g.d.cleanRunning.Add(1)
		prev := g.release
		g.release = func() {
			g.d.cleanRunning.Add(-1)
			if prev != nil {
				prev()
			}
		}
	})
	return g.err
}

func (g *cleanGate) leave() {
	if g.release != nil {
		g.release()
	}
}

// engineOutcome is what a failed ox-clean run left, captured by the runner (stderr only: on Intel Core ML prints noise
// to stdout).
type engineOutcome struct {
	mu       sync.Mutex
	exit     int // -1 when ended by a signal
	tail     string
	failed   bool
	timedOut bool
}

// Clean cleans one file. One at a time: a second call while one runs is 409 busy.
func (d *Daemon) Clean(ctx context.Context, in CleanInput) (*CleanResult, error) {
	if !d.cleaning.CompareAndSwap(0, 1) {
		return nil, busyErr()
	}
	defer d.cleaning.Store(0)

	if code, reason := d.cleanReady(); code != "" {
		if code == CleanModelsMissing {
			return nil, d.startCleanInstall()
		}
		return nil, &CleanError{Status: http.StatusServiceUnavailable, Code: code, Msg: reason}
	}
	wet := cleanWet
	if in.Wet != nil {
		wet = *in.Wet
	}
	gate := &cleanGate{d: d}
	defer gate.leave()
	out := &engineOutcome{}
	ctx, cancel := context.WithTimeout(ctx, cleanOuterCap)
	defer cancel()

	t0 := time.Now()
	res, err := voiceclean.Run(ctx, voiceclean.Options{
		In: in.InPath, Out: in.OutPath, Wet: wet, Stereo: in.Stereo, Overwrite: in.Overwrite,
		Engine: d.Cfg.CleanBin, ModelsDir: d.Cfg.CleanModelsDir(),
		Forbidden: []string{filepath.Join(d.Cfg.Home, "meetings")},
		Run:       d.cleanRunner(gate, out),
	})
	if err != nil {
		if gate.err != nil {
			return nil, gate.err
		}
		return nil, d.mapCleanError(ctx, err, out)
	}
	cr := &CleanResult{OutPath: res.Out, Video: res.Video, InputSeconds: res.Seconds,
		ElapsedSeconds: time.Since(t0).Seconds(), Wet: res.Wet, Stereo: res.Stereo,
		SampleRate: res.SampleRate, Channels: res.Channels, LagMs: res.LagMs + 0, Dropped: []CleanDropped{}}
	for _, s := range res.Dropped {
		cr.Dropped = append(cr.Dropped, CleanDropped{Index: s.Index, Type: s.Type, Codec: s.Codec})
	}
	return cr, nil
}

// cleanRunner is voiceclean's Runner: it enters the gate before the first tool that is not ffprobe, gives the model
// run its own timeout (sized from the WAV it is handed), and keeps ox-clean's exit code and stderr for mapping.
func (d *Daemon) cleanRunner(gate *cleanGate, out *engineOutcome) voiceclean.Runner {
	engine := d.Cfg.CleanBin
	return func(ctx context.Context, bin string, args []string) ([]byte, error) {
		if filepath.Base(bin) != "ffprobe" {
			if err := gate.enter(ctx); err != nil {
				return nil, err
			}
		}
		idx := -1
		for i, a := range append([]string{bin}, args...) {
			if a == engine {
				idx = i
				break
			}
		}
		if idx < 0 {
			return oneshot.Run(ctx, bin, args, oneshot.Options{StderrTail: 512, WaitDelay: cleanWaitDelay})
		}
		// ox-clean <in.wav> <out.wav> --models DIR, perhaps behind /usr/bin/nice -n 15: the input follows the engine.
		full := append([]string{bin}, args...)
		seconds := 0.0
		if idx+1 < len(full) {
			if st, err := os.Stat(full[idx+1]); err == nil {
				seconds = float64(st.Size()) / cleanBytesPerSecond
			}
		}
		rctx, cancel := context.WithTimeout(ctx, cleanTimeout(seconds))
		defer cancel()
		raw, err := oneshot.Run(rctx, bin, args, oneshot.Options{StderrTail: cleanStderrKeep, WaitDelay: cleanWaitDelay})
		if err != nil {
			out.mu.Lock()
			out.failed = true
			var ee *oneshot.ExitError
			switch {
			case errors.As(err, &ee):
				out.exit, out.tail = ee.Code(), ee.Tail
			case ctx.Err() == nil && rctx.Err() != nil:
				out.timedOut = true
			}
			out.mu.Unlock()
		}
		return raw, err
	}
}

var reasonToken = regexp.MustCompile(`\[reason=([a-z_]+)\]\s*$`)

// engineReason is the [reason=<token>] ending ox-clean's last stderr line, "" when there is none.
func engineReason(tail string) string {
	tail = strings.TrimSpace(tail)
	if i := strings.LastIndex(tail, "\n"); i >= 0 {
		tail = tail[i+1:]
	}
	if m := reasonToken.FindStringSubmatch(strings.TrimSpace(tail)); m != nil {
		return m[1]
	}
	return ""
}

// ox-clean's exit codes (engine/clean OxCleanCore.ExitCode).
const (
	cleanExitProcessing = 1
	cleanExitUsage      = 2
	cleanExitModels     = 3
	cleanExitInput      = 4
	cleanExitOS         = 5
	cleanExitOutput     = 6
)

// engineFailure maps a failed ox-clean run to a stable code, a status and a plain sentence. Nothing was changed in
// any of these cases: the output is published only by a complete run.
func engineFailure(exit int, tail string) *CleanError {
	reason := engineReason(tail)
	e := &CleanError{Status: http.StatusBadGateway, Code: "engine_failed", Reason: reason,
		Msg: "The cleanup engine failed while processing the audio. Your file was not changed."}
	switch {
	case exit == cleanExitModels && reason == "known_answer":
		e.Code = "model_wrong_answer"
		e.Msg = "The voice model gave a wrong answer on this Mac, so nothing was cleaned. Your file was not changed."
	case exit == cleanExitModels:
		e.Status, e.Code = http.StatusServiceUnavailable, "models_unusable"
		e.Msg = "The voice cleanup model files are missing or cannot be loaded. Reinstall the model and try again."
	case exit == cleanExitInput:
		e.Code = "engine_input"
		e.Msg = "The cleanup engine could not read the audio it was given. Your file was not changed."
	case exit == cleanExitOS:
		e.Status, e.Code = http.StatusServiceUnavailable, CleanOSTooOld
		e.Msg = "Voice cleanup needs macOS 15 or later."
	case exit == cleanExitOutput:
		e.Code = "engine_output"
		e.Msg = "The cleanup engine could not write its result. Check the free disk space. Your file was not changed."
	case exit == cleanExitUsage:
		e.Code = "engine_usage"
		e.Msg = "The cleanup engine refused its arguments; this is a bug in OxSay. Your file was not changed."
	case exit < 0 || exit > 128:
		e.Status, e.Code = http.StatusServiceUnavailable, "engine_interrupted"
		e.Msg = "The cleanup engine was stopped before it finished. Your file was not changed."
	}
	return e
}

// codeSentence is the fixed English sentence of the voiceclean codes whose own message carries a tool's output; the
// others keep voiceclean's message, which is one plain sentence by contract.
var codeSentence = map[string]string{
	voiceclean.CodeEngineFailed:  "The audio tools failed while cleaning the file. Your file was not changed.",
	voiceclean.CodeLagUnverified: "The cleaned file's sound could not be verified to line up with the picture, so it was not written. Your file was not changed.",
}

// mapCleanError turns whatever voiceclean returned into a *CleanError (or the context's own error when the caller left).
func (d *Daemon) mapCleanError(ctx context.Context, err error, out *engineOutcome) error {
	var ce *CleanError
	if errors.As(err, &ce) {
		return ce
	}
	var ve *voiceclean.Error
	if !errors.As(err, &ve) {
		return err // the caller's cancel or deadline: nobody is waiting for an answer
	}
	out.mu.Lock()
	failed, exit, tail, timedOut := out.failed, out.exit, out.tail, out.timedOut
	out.mu.Unlock()
	if ve.Code == voiceclean.CodeEngineFailed && failed {
		if timedOut {
			return &CleanError{Status: http.StatusGatewayTimeout, Code: "engine_timeout",
				Msg: "The cleanup took much longer than expected and was stopped. Your file was not changed."}
		}
		return engineFailure(exit, tail)
	}
	msg := ve.Msg
	if s, ok := codeSentence[ve.Code]; ok {
		msg = s
		d.log.Warn("voice cleanup failed", "code", ve.Code, "detail", ve.Msg)
	}
	return &CleanError{Status: ve.Status, Code: ve.Code, Msg: msg}
}

// ---- engine version ---------------------------------------------------------------------------------------------

// cleanVersion runs `ox-clean --version` once per daemon start and caches a success.
func (d *Daemon) cleanVersion() string {
	d.cleanVer.mu.Lock()
	defer d.cleanVer.mu.Unlock()
	if d.cleanVer.v != "" {
		return d.cleanVer.v
	}
	ctx, cancel := context.WithTimeout(context.Background(), cleanVersionTimeout)
	defer cancel()
	raw, err := oneshot.Run(ctx, d.Cfg.CleanBin, []string{"--version"}, oneshot.Options{StderrTail: 256, WaitDelay: time.Second})
	if err == nil {
		d.cleanVer.v = strings.TrimSpace(strings.SplitN(string(raw), "\n", 2)[0])
	}
	return d.cleanVer.v
}

type cleanVersionCache struct {
	mu sync.Mutex
	v  string
}

// cleanStatus is /status voice_clean.
type cleanStatus struct {
	Available     bool   `json:"available"`
	ReasonCode    string `json:"reason_code"`
	Reason        string `json:"reason"`
	EngineVersion string `json:"engine_version"`
	ModelRevision string `json:"model_revision"`
	// Installing is the model download started by the first cleanup; InstallErr is the last one's failure.
	Installing  bool   `json:"installing"`
	InstallErr  string `json:"install_error,omitempty"`
	InstallCode string `json:"install_code,omitempty"`
}

func (d *Daemon) cleanStatus() cleanStatus {
	code, reason := d.cleanReady()
	running, ierr, icode := d.cleanInst.state()
	s := cleanStatus{Available: code == "", ReasonCode: code, Reason: reason,
		ModelRevision: config.CleanModelsRevision, Installing: running, InstallErr: ierr, InstallCode: icode}
	if code != CleanOSTooOld && code != CleanEngineMissing {
		s.EngineVersion = d.cleanVersion()
	}
	return s
}

// cleanBusyCount is busy.cleaning.
func (d *Daemon) cleanBusyCount() int { return int(d.cleaning.Load()) }
