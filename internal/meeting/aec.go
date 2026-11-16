package meeting

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/anatolykoptev/ox-say/internal/oneshot"
)

// The aec stage runs ox-aec on a finished meeting's two channels before
// transcription: the far side's signal (them.pcm) is the echo reference it
// subtracts from the mic (me.pcm), so the recognizer never hears the far
// side's words twice — once on their channel and once on the speakers'
// leakage into the mic. Its answer decides which file the "me" channel is
// transcribed from; every failure falls back to the raw me.pcm, so a broken
// or missing canceller never costs a meeting its transcript.

// ErrAECMissing is what a Deps.AEC implementation returns when the ox-aec
// binary is not on this Mac: the stage skips without running anything.
var ErrAECMissing = errors.New("meeting: ox-aec is not installed")

// The aec stage end's reasons beside errClass of a plain error.
const (
	aecReasonOff      = "off"       // meeting_aec is off
	aecReasonMissing  = "missing"   // no binary / no implementation
	aecReasonNoAudio  = "no_audio"  // a channel file is gone (retention) or never recorded: nothing to cancel
	aecReasonDiverged = "diverged"  // the adaptive filter's output grew louder than its input
	aecReasonNoOutput = "no_output" // the run ended but me.aec.pcm did not arrive whole
	aecReasonNoRender = "no_render" // the report's skipped value: nothing on the far side to cancel
)

// niceBin lowers the canceller under dictation, the same niceness voice
// cleanup uses; a Mac without it still runs the stage.
const (
	niceBin   = "/usr/bin/nice"
	niceLevel = "15"
)

const aecWaitDelay = 3 * time.Second // how long a killed ox-aec has to exit before SIGKILL

// AECReport is ox-aec's report file (AECJSON), the fields the stage reads:
// whether the engine trusted its own output, how well it aligned the two
// channels, why it skipped, and the numbers the stage log carries. Optional
// numbers the engine leaves null stay nil.
type AECReport struct {
	LagMS       []float64 `json:"lag_ms"`
	LagMeasured []int     `json:"lag_measured"` // 1 where the window's lag is a measurement, not a carry
	Stats       []struct {
		ERLEdB *float64 `json:"erle_db"`
	} `json:"stats"`
	Diverged   bool   `json:"diverged"`
	Alignment  string `json:"alignment"` // measured | partial | unmeasured
	APMLatency *int64 `json:"apm_latency_samples"`
	Skipped    string `json:"skipped"`
}

// AECBinReady reports whether bin is a runnable ox-aec: a regular file the
// daemon may execute (the same readiness ox-diar gets).
func AECBinReady(bin string) bool {
	st, err := os.Stat(bin)
	return err == nil && st.Mode().IsRegular() && st.Mode().Perm()&0o111 != 0
}

// RunAECBin runs ox-aec on one meeting directory: capture me.pcm, render
// them.pcm, output me.aec.pcm, report aec.json — the file names it is bound
// to produce. It never writes me.pcm. ErrAECMissing when the binary is not
// there or not executable; the child's own error otherwise; a report the run
// did not leave readable is an error of its own. The daemon wires it as
// Deps.AEC with Cfg.AECBin; tests wire it with a stub script.
func RunAECBin(ctx context.Context, bin, dir string) (*AECReport, error) {
	if !AECBinReady(bin) {
		return nil, ErrAECMissing
	}
	// An earlier run's output must never pass for this run's: clear both before the child starts.
	for _, name := range []string{MeAECPCM, AECJSON} {
		if err := os.Remove(filepath.Join(dir, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
	}
	args := []string{
		"--capture", filepath.Join(dir, MePCM),
		"--render", filepath.Join(dir, ThemPCM),
		"--out", filepath.Join(dir, MeAECPCM),
		"--report", filepath.Join(dir, AECJSON),
	}
	if _, err := os.Stat(niceBin); err == nil {
		bin, args = niceBin, append([]string{"-n", niceLevel, bin}, args...)
	}
	if _, err := oneshot.Run(ctx, bin, args, oneshot.Options{WaitDelay: aecWaitDelay}); err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(filepath.Join(dir, AECJSON))
	if err != nil {
		return nil, err
	}
	var rep AECReport
	if err := json.Unmarshal(raw, &rep); err != nil {
		return nil, fmt.Errorf("meeting: %s: %w", AECJSON, err)
	}
	return &rep, nil
}

// AECRun is the /status "last aec" value: how the last stage ended and the
// numbers it logged, for the meeting it ran on.
type AECRun struct {
	At         time.Time `json:"at"`
	Meeting    string    `json:"meeting"`
	Result     string    `json:"result"` // ok | skipped | failed
	Reason     string    `json:"reason,omitempty"`
	Alignment  string    `json:"alignment,omitempty"`
	LagMS      *float64  `json:"lag_ms,omitempty"`
	ERLEdB     *float64  `json:"erle_db,omitempty"`
	APMSamples *int64    `json:"apm_latency_samples,omitempty"`
}

// LastAEC is the most recent stage outcome the runner saw, nil before the
// first one; /status shows it beside the other engines.
func (r *Runner) LastAEC() *AECRun {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.lastAEC
}

// aecVerdict is how one stage run ended: the stage end's result and reason,
// the warning it earned, whether the "me" side reads me.aec.pcm, and the
// numbers of the report it came from (zero when it never got one).
type aecVerdict struct {
	result, reason, warn string
	useAEC               bool
	attrs                []slog.Attr
	run                  AECRun
}

// aecStage runs the canceller and returns the channel file the "me" side is
// transcribed from and the warnings the run earned. A cancellation is an error
// of the run; every engine failure degrades to the raw channel.
func (r *Runner) aecStage(ctx context.Context, id, dir string, sl *stageLog) (file string, warns []string, err error) {
	done := sl.begin(stageAEC)
	at := r.Now()
	v, err := r.aecVerdict(ctx, dir, sl)
	if err != nil {
		v = aecVerdict{result: stageFailed, reason: errClass(err)}
	}
	done(v.result, v.reason, v.attrs...)
	v.run.At, v.run.Meeting, v.run.Result, v.run.Reason = at, id, v.result, v.reason
	r.noteAEC(v.run)
	switch {
	case err != nil:
		return "", nil, err
	case v.warn != "":
		warns = []string{v.warn}
	}
	if v.useAEC {
		return MeAECPCM, warns, nil
	}
	return MePCM, warns, nil
}

// aecVerdict decides what the run was: off, nothing to cancel, missing, failed
// or ok. The error is only a cancellation of ctx.
func (r *Runner) aecVerdict(ctx context.Context, dir string, sl *stageLog) (aecVerdict, error) {
	switch {
	case !r.Store.Settings().AECEnabled():
		return aecVerdict{result: stageSkipped, reason: aecReasonOff}, nil
	case !channelsPresent(dir):
		return aecVerdict{result: stageSkipped, reason: aecReasonNoAudio}, nil
	case r.AEC == nil:
		return aecVerdict{result: stageSkipped, reason: aecReasonMissing, warn: WarnAECMissing}, nil
	}
	if err := r.waitBefore(ctx, sl); err != nil {
		return aecVerdict{}, err
	}
	rep, err := r.AEC(ctx, dir)
	switch {
	case errors.Is(err, ErrAECMissing):
		return aecVerdict{result: stageSkipped, reason: aecReasonMissing, warn: WarnAECMissing}, nil
	case ctx.Err() != nil:
		return aecVerdict{}, ctx.Err()
	case err != nil:
		return aecVerdict{result: stageFailed, reason: errClass(err), warn: WarnAECFailed}, nil
	}
	return reportVerdict(rep, dir), nil
}

// reportVerdict reads a finished run's report: skipped, diverged, a broken
// output or ok. An unmeasured alignment with an active render is still ok: the
// engine estimates its own delay, and the stage log carries the alignment.
func reportVerdict(rep *AECReport, dir string) aecVerdict {
	attrs, run := aecAttrs(rep)
	v := aecVerdict{attrs: attrs, run: run}
	switch {
	case rep.Skipped == aecReasonNoRender:
		v.result, v.reason = stageSkipped, aecReasonNoRender
	case rep.Diverged:
		v.result, v.reason, v.warn = stageFailed, aecReasonDiverged, WarnAECFailed
	case !aecOutputOK(dir):
		v.result, v.reason, v.warn = stageFailed, aecReasonNoOutput, WarnAECFailed
	default:
		v.result, v.useAEC = stageOK, true
	}
	return v
}

// channelsPresent is whether both channel files are on disk: the canceller
// needs the mic and the far side, and retention removes them together.
func channelsPresent(dir string) bool {
	for _, name := range []string{MePCM, ThemPCM} {
		if st, err := os.Stat(filepath.Join(dir, name)); err != nil || !st.Mode().IsRegular() {
			return false
		}
	}
	return true
}

// noteAEC records the stage's outcome for /status.
func (r *Runner) noteAEC(run AECRun) {
	r.mu.Lock()
	r.lastAEC = &run
	r.mu.Unlock()
}

// aecAttrs turns a report into the stage end's numbers — alignment, the
// median lag of the windows the engine really measured, median ERLE and the
// pipeline latency — and the matching AECRun fields. Numbers only; nothing
// it logs carries text.
func aecAttrs(rep *AECReport) (attrs []slog.Attr, run AECRun) {
	run.Alignment = rep.Alignment
	attrs = append(attrs, slog.String("alignment", rep.Alignment))
	var lags, erles []float64
	for i, lag := range rep.LagMS {
		if i < len(rep.LagMeasured) && rep.LagMeasured[i] == 1 {
			lags = append(lags, lag)
		}
	}
	for _, st := range rep.Stats {
		if st.ERLEdB != nil {
			erles = append(erles, *st.ERLEdB)
		}
	}
	if v, ok := median(lags); ok {
		run.LagMS = &v
		attrs = append(attrs, slog.Float64("lag_ms", v))
	}
	if v, ok := median(erles); ok {
		run.ERLEdB = &v
		attrs = append(attrs, slog.Float64("erle_db", v))
	}
	if rep.APMLatency != nil {
		run.APMSamples = rep.APMLatency
		attrs = append(attrs, slog.Int64("apm_latency_samples", *rep.APMLatency))
	}
	return attrs, run
}

// aecOutputOK trusts me.aec.pcm only when it is all there: a regular file as
// long as the capture it was made from. A short or missing output means the
// timeline the transcript assumes is broken, so the stage calls it failed.
func aecOutputOK(dir string) bool {
	out, err := os.Stat(filepath.Join(dir, MeAECPCM))
	if err != nil || !out.Mode().IsRegular() || out.Size() == 0 {
		return false
	}
	in, err := os.Stat(filepath.Join(dir, MePCM))
	return err != nil || in.Size() == out.Size()
}

// heardAnything is whether a recorded channel file holds sound anywhere: the "no audio" warning's own test, run on
// the recording when the transcript was made from a cleaned copy of it. An unreadable file reads as silence.
func (r *Runner) heardAnything(dir, file string) bool {
	f, err := os.Open(filepath.Join(dir, file))
	if err != nil {
		return false
	}
	defer func() { _ = f.Close() }()
	st, err := f.Stat()
	if err != nil {
		return false
	}
	spans, err := Spans(f, st.Size(), r.PieceSeconds)
	if err != nil {
		return false
	}
	for _, sp := range spans {
		if clip, err := ReadClip(f, sp); err == nil && !Silent(clip) {
			return true
		}
	}
	return false
}

// median of a sample, for the stage log's one number per report list.
func median(vs []float64) (float64, bool) {
	if len(vs) == 0 {
		return 0, false
	}
	sorted := slices.Clone(vs)
	slices.Sort(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return sorted[mid], true
	}
	return (sorted[mid-1] + sorted[mid]) / 2, true
}
