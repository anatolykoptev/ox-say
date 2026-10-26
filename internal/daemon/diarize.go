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
	// diarMinTimeout and diarTimeoutDivisor bound one ox-diar run: an hour of audio takes about 21 seconds on the
	// Neural Engine and about eighty on the CPU of an M-series Mac, so a tenth of the audio's length (six minutes per
	// hour, four and a half times the CPU figure), never under five minutes for the model load, is a run that hung.
	diarMinTimeout     = 5 * time.Minute
	diarTimeoutDivisor = 10
	// diarBytesPerSecond is 16 kHz mono s16le.
	diarBytesPerSecond = 32000
	// diarMaxSeconds caps the recording ox-diar is given. It holds the whole channel in memory: measured at about
	// 1.06 GB resident for an hour of call (1.04 GB peak on the Radio-T hour, 1.2 GB for 113 minutes), so two hours
	// is about 2.1 GB. On an 8 GB Mac that leaves room for macOS, a resident Parakeet and the app; three hours
	// (about 3.2 GB) would not. A longer call keeps one far-side label (unavailable, too_long), because diarizing it
	// could page the Mac to a halt. The 8 GB probe (plan, 20a carried items) has not been run, so this errs low.
	diarMaxSeconds  = 2 * 3600
	diarMaxPCMBytes = diarMaxSeconds * diarBytesPerSecond
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
)

// diarReady is Deps.DiarizeReady: why this Mac cannot tell voices apart, "" when it can. An old macOS first (the
// engine would crash there; a system that will not say its version is treated as old, because a macOS 13 Mac cannot
// even launch the binary), then an Intel CPU, then a missing engine, then models that are not all there.
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

// diarTimeout is how long one ox-diar run on a channel of pcmBytes may take.
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
	if st.Size() > diarMaxPCMBytes {
		return nil, &meeting.DiarUnavailableError{Reason: meeting.DiarTooLong}
	}
	work := filepath.Join(filepath.Dir(pcmPath), meeting.WorkDir)
	if err := os.MkdirAll(work, 0o700); err != nil {
		return nil, err
	}
	out := filepath.Join(work, meeting.DiarizationJSON)
	defer func() { _ = os.Remove(out) }()
	ctx, cancel := context.WithTimeout(ctx, diarTimeout(st.Size()))
	defer cancel()
	_, err = oneshot.Run(ctx, cfg.DiarBin, []string{pcmPath, out, "--models", cfg.DiarModelsDir()},
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
		if errors.As(err, &exit) && exit.Code() == 99 {
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
