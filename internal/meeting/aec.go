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
	"strconv"
	"sync/atomic"
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

// aecRunPrefix names a per-run scratch directory inside work/: work/aec-<id>/.
// ox-aec writes its output, its report and the <name>.tmp files it renames
// them from only there, so an interrupted run leaves nothing beside the
// recording, and the run dir is backup-excluded and swept with work/.
const aecRunPrefix = "aec-"

// aecRunIDRadix encodes the run id in the directory name: base36 keeps
// work/aec-<id>/ short.
const aecRunIDRadix = 36

// aecRunSeq hands out the run ids: strictly increasing within the process and,
// because an id never goes below the wall clock, larger than any id a previous
// daemon run used. A stale run dir therefore always carries a smaller id.
var aecRunSeq atomic.Int64

// aecFileLocks serializes the clear and the publish of the two artifacts per
// meeting directory: two runs that overlap (a re-queued run behind an orphaned
// engine) each install a matched me.aec.pcm/aec.json pair, never one file from
// each run.
var aecFileLocks keyedLocks

// nextAECRunID returns a run id larger than every id handed out before and
// larger than the wall-clock moment a run dir existing now was named at.
func nextAECRunID() int64 {
	for {
		last := aecRunSeq.Load()
		id := time.Now().UnixNano()
		if id <= last {
			id = last + 1
		}
		if aecRunSeq.CompareAndSwap(last, id) {
			return id
		}
	}
}

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
// them.pcm. The engine writes me.aec.pcm and aec.json — and the <name>.tmp
// files it renames them from — inside a fresh per-run directory under work/,
// which is backup-excluded and swept with the audio, so an interrupted run
// leaves nothing beside the recording. Only when the report reads clean does
// the run publish the pair into the meeting directory: an atomic rename under
// the directory's lock, and the published audio is marked excluded from backup
// like the raw channels are. It never writes me.pcm. ErrAECMissing when the
// binary is not there or not executable; the child's own error otherwise; a
// report the run did not leave readable is an error of its own. The daemon
// wires it as Deps.AEC with Cfg.AECBin; tests wire it with a stub script.
func RunAECBin(ctx context.Context, bin, dir string) (*AECReport, error) {
	if !AECBinReady(bin) {
		return nil, ErrAECMissing
	}
	work, err := MakeWorkDir(dir)
	if err != nil {
		return nil, err
	}
	rundir, err := aecRunDir(work)
	if err != nil {
		return nil, err
	}
	// Ours alone; what stays in it is unreachable, and the stage sweep takes
	// whatever a failure leaves.
	defer func() {
		if err := os.RemoveAll(rundir); err != nil {
			slog.Warn("meeting: cannot remove the aec run directory", slog.String("dir", rundir), slog.Any("error", err))
		}
	}()
	if err := clearAECPublished(dir); err != nil {
		return nil, err
	}
	args := []string{
		"--capture", filepath.Join(dir, MePCM),
		"--render", filepath.Join(dir, ThemPCM),
		"--out", filepath.Join(rundir, MeAECPCM),
		"--report", filepath.Join(rundir, AECJSON),
	}
	if _, err := os.Stat(niceBin); err == nil {
		bin, args = niceBin, append([]string{"-n", niceLevel, bin}, args...)
	}
	if _, err := oneshot.Run(ctx, bin, args, oneshot.Options{WaitDelay: aecWaitDelay}); err != nil {
		return nil, err
	}
	rep, err := readAECReport(filepath.Join(rundir, AECJSON))
	if err != nil {
		return nil, err
	}
	if aecPublishable(rep, rundir, dir) {
		if err := publishAEC(dir, rundir); err != nil {
			return nil, err
		}
	}
	return rep, nil
}

// aecRunDir makes the run's scratch directory inside work/. The id is unique
// to this run, so a directory that still holds the name can only be a dead
// process's leftover — its writer has no publisher left to reach the meeting
// — and it goes and the mkdir is retried once.
func aecRunDir(work string) (string, error) {
	rundir := filepath.Join(work, aecRunPrefix+strconv.FormatInt(nextAECRunID(), aecRunIDRadix))
	if err := os.Mkdir(rundir, 0o700); err == nil {
		return rundir, nil
	} else if !errors.Is(err, os.ErrExist) {
		return "", err
	}
	if err := os.RemoveAll(rundir); err != nil {
		return "", err
	}
	if err := os.Mkdir(rundir, 0o700); err != nil {
		return "", err
	}
	return rundir, nil
}

// clearAECPublished removes the published pair before a run: an earlier run's
// output must never pass for this run's. Under the publish lock so a
// concurrent publisher's pair is not taken apart mid-swap.
func clearAECPublished(dir string) error {
	unlock := aecFileLocks.lock(dir)
	defer unlock()
	for _, name := range []string{MeAECPCM, AECJSON} {
		if err := os.Remove(filepath.Join(dir, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

// readAECReport reads the report a finished run left inside its run directory.
func readAECReport(path string) (*AECReport, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var rep AECReport
	if err := json.Unmarshal(raw, &rep); err != nil {
		return nil, fmt.Errorf("meeting: %s: %w", AECJSON, err)
	}
	return &rep, nil
}

// aecPublishable is the publish gate: the report parsed, the engine neither
// skipped nor diverged, and the output is whole. Anything less stays inside
// the run dir — the meeting dir only ever holds a blessed pair.
func aecPublishable(rep *AECReport, rundir, dir string) bool {
	return rep.Skipped == "" && !rep.Diverged &&
		aecOutputWhole(filepath.Join(rundir, MeAECPCM), filepath.Join(dir, MePCM))
}

// publishAEC moves the blessed pair into the meeting directory as one step
// under the directory's lock: the output first, then the report; a report
// that will not move takes the output back out, so the pair a reader sees
// always comes from one run. The published audio is then marked excluded
// from backup, like the raw channels and work/ are: retention deletes it on
// a schedule and a backup must not keep a copy. A failed mark is logged,
// never an error — the same rule MakeWorkDir follows.
func publishAEC(dir, rundir string) error {
	unlock := aecFileLocks.lock(dir)
	defer unlock()
	out := filepath.Join(dir, MeAECPCM)
	if err := os.Rename(filepath.Join(rundir, MeAECPCM), out); err != nil {
		return err
	}
	if err := os.Rename(filepath.Join(rundir, AECJSON), filepath.Join(dir, AECJSON)); err != nil {
		if rerr := os.Remove(out); rerr != nil {
			slog.Warn("meeting: aec output left published without its report", slog.String("file", out), slog.Any("error", rerr))
		}
		return err
	}
	if err := excludeBackup(out); err != nil {
		slog.Warn("meeting: could not exclude the aec output from backup", slog.String("file", out), slog.Any("error", err))
	}
	return nil
}

// sweepAECRunDirs removes every per-run directory the engine left inside
// work/. The runner takes one meeting at a time and the stage runs once in
// it, so when the aec stage starts on a meeting no run of its own can still
// be live in this process: every aec-<id> here belongs to a run whose daemon
// died, and an orphaned engine still writing into one can only lose its
// files — its output has no publisher left to reach the meeting.
func sweepAECRunDirs(dir string, log *slog.Logger) {
	stale, err := filepath.Glob(filepath.Join(dir, WorkDir, aecRunPrefix+"*"))
	if err != nil {
		return // the pattern is fixed; a glob error cannot happen
	}
	for _, d := range stale {
		if err := os.RemoveAll(d); err != nil {
			log.Warn("meeting: cannot remove a stale aec run directory", slog.String("dir", d), slog.Any("error", err))
		}
	}
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
	sweepAECRunDirs(dir, r.Log)
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

// channelsPresent is whether both channel files are on disk and hold bytes:
// the canceller needs the mic and the far side, retention removes them
// together, and an empty channel is no audio, the same as a missing one.
func channelsPresent(dir string) bool {
	for _, name := range []string{MePCM, ThemPCM} {
		if st, err := os.Stat(filepath.Join(dir, name)); err != nil || !st.Mode().IsRegular() || st.Size() == 0 {
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

// aecOutputOK trusts the published me.aec.pcm only when it is all there.
func aecOutputOK(dir string) bool {
	return aecOutputWhole(filepath.Join(dir, MeAECPCM), filepath.Join(dir, MePCM))
}

// aecOutputWhole trusts the canceller's output only when it is all there: a
// regular file as long as the capture it was made from. A short or missing
// output means the timeline the transcript assumes is broken, so the stage
// calls it failed — and the run does not publish it.
func aecOutputWhole(out, capture string) bool {
	st, err := os.Stat(out)
	if err != nil || !st.Mode().IsRegular() || st.Size() == 0 {
		return false
	}
	in, err := os.Stat(capture)
	return err != nil || in.Size() == st.Size()
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
