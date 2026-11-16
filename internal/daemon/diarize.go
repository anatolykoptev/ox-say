package daemon

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/anatolykoptev/ox-say/internal/oneshot"
)

const (
	// diarMinMacOS: ox-diar refuses to run on an older macOS (Apple's BNNS bug, FluidAudio issue 878). The daemon
	// asks first, so a meeting on macOS 14 says so instead of starting a process that exits 5. A test compares this
	// number with engine/diar's Platform.minimumMajor.
	diarMinMacOS = 15
	// diarMinTimeout and diarTimeoutDivisor bound one ox-diar run: it takes about 2.2 seconds per 1000 s of audio on
	// the Neural Engine (8 s an hour), so a tenth of the audio's length (six minutes per hour), never under five
	// minutes, is a run that hung. The five minute floor also covers a cold Core ML compile of the model, the first
	// run after an install or a macOS update: 26 s of model load with an empty Core ML cache, measured on an M-series
	// Mac.
	diarMinTimeout     = 5 * time.Minute
	diarTimeoutDivisor = 10
	// diarBytesPerSecond is 16 kHz mono s16le.
	diarBytesPerSecond = 32000
	// diarMaxSecondsNemotron: ox-diar streams the mapped channel in 30 s chunks, so memory does not grow with the
	// call: 65 MB at 2.2 h, 80-87 MB at 4.4 h and 103 MB at 6.6 h, 17 s of wall time for 2.2 h on the Neural Engine
	// (plan, Task 0 probe A). Six hours is the cap the probe covers. A longer call keeps one far-side label
	// (unavailable, too_long). The app's recording cap is pinned to this constant (MeetingLimitsTests reads it by
	// regex, so the name stays).
	diarMaxSecondsNemotron = 6 * 3600
	// diarStderrKeep is how much of ox-diar's stderr an error carries; it holds no transcript text (ox-diar never
	// sees words).
	diarStderrKeep = 512
	// diarWaitDelay: after a cancel, how long ox-diar gets to exit before it is killed outright.
	diarWaitDelay = 5 * time.Second
	// ox-diar's exit codes (engine/diar OxDiarCore.ExitCode).
	diarExitModels        = 3
	diarExitInput         = 4
	diarExitUnsupportedOS = 5
)

// osMajor and goArch are the running macOS's major version and the CPU this daemon was built for; variables so
// tests can stand in for another Mac.
var (
	osMajor = macOSMajor
	goArch  = runtime.GOARCH
	// diarRun starts ox-diar; a variable so a test can see the context it is given.
	diarRun = oneshot.Run
)

// diarReady is Deps.DiarizeReady: why this Mac cannot tell voices apart, "" when it can. An old macOS first (the
// engine would crash there; a system that will not say its version is treated as old, so the check fails closed), then an Intel CPU, then a missing engine, then models that are not all there
// (Config.DiarModelsReady). A Mac without the Nemotron set says models_missing, a code a voices retry can fix: the
// runner accepts the retry as soon as the fetch has written the marker.
func (d *Daemon) diarReady() string {
	if major, ok := osMajor(); !ok || major < diarMinMacOS {
		return meeting.DiarOSTooOld
	}
	if goArch == "amd64" { // the Intel smoke of plan Task 20a failed: the Intel package carries no ox-diar
		return meeting.DiarCPUUnsupported
	}
	if st, err := os.Stat(d.Cfg.DiarBin); err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0o111 == 0 {
		return meeting.DiarEngineMissing
	}
	if !d.Cfg.DiarModelsReady() {
		return meeting.DiarModelsMissing
	}
	return ""
}

// diarMaxPCMBytes is the largest far-side channel file the engine is given: 6 h.
func diarMaxPCMBytes() int64 { return diarMaxSecondsNemotron * diarBytesPerSecond }

// diarTimeout is how long one ox-diar run on a channel of pcmBytes may take. The Neural Engine runs an hour in about
// 8 s, so at the 6 h cap (36 minutes) the tenth of the audio is generous, and it only has to catch a hung process.
func diarTimeout(pcmBytes int64) time.Duration {
	audio := time.Duration(pcmBytes/diarBytesPerSecond) * time.Second
	return max(diarMinTimeout, audio/diarTimeoutDivisor)
}

// diarizer is Deps.Diarize.
func (d *Daemon) diarizer(ctx context.Context, pcmPath string) ([]byte, error) {
	return runDiarizer(ctx, d.Cfg, pcmPath)
}

// runDiarizer runs ox-diar on one channel file and returns the JSON it wrote. ox-diar reads the raw channel itself
// (into memory: it writes no copy of the audio anywhere), and its answer, which holds the voiceprints of the far
// side, goes into the meeting's work/ directory; it is removed after the call and, if the daemon dies first, with
// work/ itself. Nothing of a call is ever written outside the meeting directory.
func runDiarizer(ctx context.Context, cfg *config.Config, pcmPath string) ([]byte, error) {
	st, err := os.Stat(pcmPath)
	if err != nil {
		return nil, err
	}
	if st.Size() > diarMaxPCMBytes() {
		return nil, &meeting.DiarUnavailableError{Reason: meeting.DiarTooLong}
	}
	work, err := meeting.MakeWorkDir(filepath.Dir(pcmPath))
	if err != nil {
		return nil, err
	}
	out := filepath.Join(work, meeting.DiarizationJSON)
	defer func() { _ = os.Remove(out) }()
	ctx, cancel := context.WithTimeout(ctx, diarTimeout(st.Size()))
	defer cancel()
	_, err = diarRun(ctx, cfg.DiarBin, []string{pcmPath, out, "--models", cfg.DiarModelsDir()},
		oneshot.Options{StderrTail: diarStderrKeep, WaitDelay: diarWaitDelay})
	if err != nil {
		var exit *oneshot.ExitError
		if errors.As(err, &exit) && exit.Code() == diarExitUnsupportedOS {
			return nil, &meeting.DiarUnavailableError{Reason: meeting.DiarOSTooOld}
		}
		if errors.As(err, &exit) && exit.Code() == diarExitModels {
			// the marker says the models are complete and they will not load: no retry changes that
			return nil, &meeting.DiarUnavailableError{Reason: meeting.DiarModelsUnusable, Detail: strings.TrimSpace(exit.Tail)}
		}
		if errors.As(err, &exit) && exit.Code() == diarExitInput {
			// the daemon just stat-ed the file: unreadable now means a retry meets the same file
			return nil, &meeting.DiarUnavailableError{Reason: meeting.DiarInputUnreadable, Detail: strings.TrimSpace(exit.Tail)}
		}
		return nil, fmt.Errorf("ox-diar: %w", err)
	}
	raw, err := os.ReadFile(out)
	if errors.Is(err, os.ErrNotExist) {
		return nil, errors.New("ox-diar exited 0 without writing its result")
	}
	return raw, err
}
