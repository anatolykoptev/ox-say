package daemon

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/vproject"
	"github.com/anatolykoptev/ox-say/internal/vscript"
)

// Layout and bounds of the producer.
const (
	produceDir       = "produce"
	maxProduceChars  = 40000 // ~48 min at estCharsPerSec: within ~60 min of estimated audio
	estCharsPerSec   = 13.9
	bytesPerAudioSec = 96000 // 48 kHz s16 mono
	diskFactor       = 2.0
	maxTakesPerChunk = 3
	// maxListedProjects caps GET /v1/produce and produce_status without an id.
	maxListedProjects = 20
	stopBound         = 10 * time.Second // launchd ExitTimeOut is 20 s
	defaultPreset     = "youtube"
	// renderRTF is the measured warm real-time factor (parent Task 1 result).
	renderRTF = 0.58
	// tempSweepMinAge is how long a crash leftover must have been untouched
	// before a project start removes it: an ffmpeg orphaned by a SIGKILLed
	// daemon keeps modifying its output, so a file that is not fresh has no
	// live writer left to race (#154 amendment 4).
	tempSweepMinAge = 2 * time.Minute
)

// powerPoll is how often a paused job re-checks the power source (tests lower it).
var powerPoll = 30 * time.Second

var (
	errCancelled       = errors.New("produce: cancelled")
	errProducerStopped = errors.New("the voiceover producer is not running")
	errNoProject       = errors.New("no such voiceover project")
	errNotRunning      = errors.New("this voiceover is not running, so there is nothing to cancel")
)

// cancellingError: the job was told to stop and has not yet (HTTP 409).
type cancellingError struct{ id string }

func (e *cancellingError) Error() string {
	return "this voiceover is still cancelling, try again in a moment"
}

// busyError: one job at a time (HTTP 409, with the running id).
type busyError struct{ id string }

func (e *busyError) Error() string {
	return fmt.Sprintf("another voiceover is being produced (%s): wait for it or cancel it", e.id)
}

// preset is a named set of defaults (D17; chunk sizes from F1-0).
type preset struct {
	opts  vscript.Options
	lufs  float64
	takes int
}

func presetOpts(chunkPause, paraPause float64) vscript.Options {
	return vscript.Options{TargetChars: 250, MaxChars: 400, MinChars: 80, MaxScriptChars: maxProduceChars, MaxSpokenChars: maxVoxChars,
		ChunkPause: chunkPause, ParagraphPause: paraPause}
}

// presets: owner defaults, two-way door (QF1, QF2, QF6).
var presets = map[string]preset{
	"youtube":           {presetOpts(0.30, 0.70), -16, 1},
	"reels":             {presetOpts(0.20, 0.45), -14, 2},
	"voice-under-music": {presetOpts(0.30, 0.70), -18, 1},
}

// produceInput is a create request.
type produceInput struct {
	Script, Title, Voice, Style, Preset, OutPath string
	Seed                                         *int64
	Takes                                        int
	Overwrite, AllowBattery                      bool
}

// job is the running project.
type job struct {
	dir          string
	m            *vproject.Manifest // guarded by producer.mu
	regen        map[int]int        // chunk -> extra takes requested
	cancel       atomic.Bool
	allowBattery atomic.Bool
	// assembleOnly marks a pause-only delivery run: settled chunks are
	// re-assembled without entering runChunks (no renders, no checkpoint).
	// Set before launch; run reads it after the goroutine starts.
	assembleOnly bool

	// ctx ends when the producer shuts down or the job is cancelled; waits
	// (dictation, battery) end with it, renders do not: they run under the
	// producer's own context so a cancelled job keeps its in-flight take.
	ctx      context.Context
	stopWait context.CancelFunc

	started  time.Time // when this run began
	elapsedS float64   // the elapsed time the export recorded (guarded by producer.mu)
}

// producer runs at most one job, through ports only.
type producer struct {
	ports producePorts
	root  string
	log   *slog.Logger
	mu    sync.Mutex
	cur   *job
	ctx   context.Context // shutdown context: renders run under it
	stop  context.CancelFunc
	wg    sync.WaitGroup
	once  sync.Once
}

func newProducer(ports producePorts) *producer {
	return &producer{ports: ports, root: filepath.Join(ports.Home(), produceDir), log: slog.Default()}
}

func (p *producer) start() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.ctx == nil {
		p.ctx, p.stop = context.WithCancel(context.Background())
	}
}

// shutdown cancels the running job (it ends interrupted) and waits up to
// stopBound; false when the bound was exceeded.
func (p *producer) shutdown() bool {
	ok := true
	p.once.Do(func() {
		p.mu.Lock()
		stop := p.stop
		p.mu.Unlock()
		if stop == nil {
			return
		}
		stop()
		done := make(chan struct{})
		go func() { p.wg.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(stopBound):
			ok = false
			p.log.Warn("produce: a job was still stopping at shutdown")
		}
	})
	return ok
}

func (p *producer) ready() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.ctx == nil || p.ctx.Err() != nil {
		return errProducerStopped
	}
	return nil
}

// active is the count of jobs a restart would interrupt: the producer
// runs at most one.
func (p *producer) active() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cur == nil {
		return 0
	}
	return 1
}

// launch makes j the running job, or answers busy. Crash leftovers are swept
// here, under the lock and behind the busy check, so the sweep never touches
// the directory of a running job (#154.6); fresh files are spared.
func (p *producer) launch(j *job) (vproject.Summary, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cur != nil {
		return vproject.Summary{}, &busyError{p.cur.m.ID}
	}
	if n := vproject.SweepStaleTemp(j.dir, tempSweepMinAge); n > 0 {
		p.log.Info("produce: removed crash leftovers", slog.String("job", j.m.ID), slog.Int("files", n))
	}
	p.cur = j
	j.started = time.Now()
	j.ctx, j.stopWait = context.WithCancel(p.ctx)
	j.m.Status, j.m.Error = vproject.StatusRunning, ""
	if err := j.m.Save(j.dir); err != nil {
		p.cur = nil
		return vproject.Summary{}, err
	}
	p.wg.Add(1)
	go p.run(j)
	return j.m.Summary(), nil
}

// run is one pass over a project: settle every chunk, then assemble.
func (p *producer) run(j *job) {
	defer p.wg.Done()
	defer j.stopWait()
	p.ports.Background(true)
	var err error
	if j.assembleOnly && countSettled(j.m.Chunks) == len(j.m.Chunks) {
		err = p.assemble(j)
	} else {
		err = p.runChunks(j, j.started)
		if err == nil {
			err = p.assemble(j)
		}
	}
	p.ports.Background(false)
	status, msg := p.outcome(j, err)
	// Superseded takes go while the job still holds the producer: a resume of
	// the same project cannot start rendering into takes/ during the prune.
	n, perr := pruneTakes(j)
	p.mu.Lock()
	j.m.Status, j.m.Error = status, msg
	if j.elapsedS > 0 {
		j.m.Progress.ElapsedS = j.elapsedS
	} else {
		j.m.Progress.ElapsedS = round2(time.Since(j.started).Seconds())
	}
	j.m.Progress.ETAS = 0
	saveErr := j.m.Save(j.dir)
	review := 0
	for _, c := range j.m.Chunks {
		if c.Status == vproject.ChunkReview {
			review++
		}
	}
	renders, chunks := j.m.Progress.Renders, len(j.m.Chunks)
	p.cur = nil
	p.mu.Unlock()
	if saveErr != nil {
		p.log.Error("produce: cannot save the manifest", slog.String("job", j.m.ID), slog.Any("error", saveErr))
	}
	if perr != nil || n > 0 {
		p.log.Info("produce: pruned superseded takes", slog.Int("removed", n), slog.Any("error", perr))
	}
	p.log.Info("produce done", slog.String("job", j.m.ID), slog.String("status", status), slog.Int("chunks", chunks),
		slog.Int("renders", renders), slog.Int("review", review), slog.Float64("elapsed_s", time.Since(j.started).Seconds()))
}

func (p *producer) outcome(j *job, err error) (string, string) {
	switch {
	case err == nil && j.m.AnyReview():
		return vproject.StatusReview, ""
	case err == nil:
		return vproject.StatusDone, ""
	case errors.Is(err, errCancelled):
		return vproject.StatusCancelled, ""
	case p.ctx.Err() != nil:
		return vproject.StatusInterrupted, ""
	default:
		p.log.Warn("produce failed", slog.String("job", j.m.ID), slog.Any("error", err))
		return vproject.StatusFailed, p.public(err)
	}
}

// setStatus records a transient status (waiting, paused, running).
func (p *producer) setStatus(j *job, s string) {
	p.mu.Lock()
	if j.m.Status != s {
		j.m.Status = s
		if err := j.m.Save(j.dir); err != nil {
			p.log.Warn("produce: cannot save the manifest", slog.Any("error", err))
		}
	}
	p.mu.Unlock()
}

// checkpoint runs between takes: cancel, shutdown, power, dictation.
func (p *producer) checkpoint(j *job) error {
	if j.cancel.Load() {
		return errCancelled
	}
	if err := p.ctx.Err(); err != nil {
		return err
	}
	if err := p.waitPower(j); err != nil {
		return err
	}
	return p.quiet(j)(j.ctx)
}

// quiet waits for dictation to be quiet, showing the waiting status (D12).
// The wait ends at once when the job is cancelled (errCancelled) or the
// producer shuts down; the caller's ctx is not used for the wait, because a
// render in flight must not be cut by a cancel.
func (p *producer) quiet(j *job) func(context.Context) error {
	return func(context.Context) error {
		err := p.ports.Quiet(j.ctx, func() { p.setStatus(j, vproject.StatusWaitingForDictation) })
		if err != nil && j.cancel.Load() {
			return errCancelled
		}
		p.setStatus(j, vproject.StatusRunning)
		return err
	}
}

// waitPower pauses on battery or in Low Power Mode unless allowed (D13).
func (p *producer) waitPower(j *job) error {
	for !j.allowBattery.Load() {
		onBattery, lowPower := p.ports.Power(p.ctx)
		if !onBattery && !lowPower {
			break
		}
		p.setStatus(j, vproject.StatusPausedOnBattery)
		select {
		case <-j.ctx.Done():
			if j.cancel.Load() {
				return errCancelled
			}
			return p.ctx.Err()
		case <-time.After(powerPoll):
		}
		if j.cancel.Load() {
			return errCancelled
		}
	}
	p.setStatus(j, vproject.StatusRunning)
	return nil
}

// runChunks refreshes the live inputs and settles every chunk in order.
func (p *producer) runChunks(j *job, start time.Time) error {
	specs, err := p.refresh(j)
	if err != nil {
		return err
	}
	tk := &taker{ports: p.ports, dir: filepath.Join(j.dir, vproject.TakesDir), quiet: p.quiet(j)}
	for i := range specs {
		if err := p.checkpoint(j); err != nil {
			return err
		}
		if err := p.runChunk(j, tk, i, specs[i], start); err != nil {
			return err
		}
	}
	return nil
}

// runChunk renders attempts until Takes passing takes exist (or 3
// automatic attempts), or exactly the requested extra takes on regenerate;
// then settles the pick.
func (p *producer) runChunk(j *job, tk *taker, i int, base takeSpec, start time.Time) error {
	p.mu.Lock()
	c := j.m.Chunks[i]
	want, extra := j.m.Settings.Takes, j.regen[i]
	first, passing := len(c.Takes), countPassing(c.Takes)
	done := extra == 0 && c.Status != vproject.ChunkPending && c.Pick != ""
	p.mu.Unlock()
	if done {
		return nil
	}
	last := maxTakeAttempts
	if extra > 0 {
		last = first + extra
	}
	for a := first; a < last && (extra > 0 || passing < want); a++ {
		if a > first {
			if err := p.checkpoint(j); err != nil {
				return err
			}
		}
		ref, rendered, err := tk.take(p.ctx, base.attempt(a), a)
		if err != nil {
			return err
		}
		if ref.Passed {
			passing++
		}
		if err := p.record(j, i, ref, rendered, start); err != nil {
			return err
		}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	settle(&j.m.Chunks[i])
	delete(j.regen, i)
	j.m.Progress.ChunksDone = countSettled(j.m.Chunks)
	return j.m.Save(j.dir)
}

// record appends a take and updates progress and ETA. The seed in the
// manifest is the one the take carries (TakeRef.Seed), never base + attempt.
func (p *producer) record(j *job, i int, ref vproject.TakeRef, rendered bool, start time.Time) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	c := &j.m.Chunks[i]
	c.Takes = append(c.Takes, ref)
	if rendered {
		j.m.Progress.Renders++
	}
	j.m.Progress.ElapsedS = round2(time.Since(start).Seconds())
	j.m.Progress.ETAS = round2(eta(j.m, time.Since(start).Seconds()))
	p.log.Info("produce take", slog.String("job", j.m.ID), slog.Int("chunk", i), slog.Int("attempt", ref.Attempt),
		slog.Int64("seed", ref.Seed), slog.Int("chars", utf8.RuneCountInString(c.Text)), slog.Float64("audio_s", ref.DurationS),
		slog.Float64("wer", ref.WER), slog.Bool("passed", ref.Passed), slog.Bool("rendered", rendered))
	return j.m.Save(j.dir)
}

// settle picks: a still-listed user pick wins and, being the person's choice
// after listening, is ok even if it failed the checks (UserPick; a silent take
// is never accepted, the assembly needs audio); else the first passing take;
// else the take with the lowest WER among the audible ones (review); a take
// that is silent is picked only when every take is, so the chunk is flagged
// for a listen instead of failing the assembly (#154 amendment 3).
func settle(c *vproject.Chunk) {
	var pick *vproject.TakeRef
	for k := range c.Takes {
		if c.Takes[k].Key == c.Pick {
			pick = &c.Takes[k]
		}
	}
	if pick == nil {
		c.UserPick = false // the take the person chose is gone: back to the checks
		for k := range c.Takes {
			if c.Takes[k].Passed {
				pick = &c.Takes[k]
				break
			}
		}
	}
	if pick == nil {
		for k := range c.Takes {
			t := &c.Takes[k]
			if pick == nil || better(t, pick) {
				pick = t
			}
		}
	}
	if pick == nil {
		return
	}
	c.Pick, c.Reasons = pick.Key, pick.Reasons
	c.Status = vproject.ChunkOK
	if !pick.Passed && (!c.UserPick || isSilent(pick)) {
		c.Status = vproject.ChunkReview
	}
}

// better reports whether take a is a better fallback than b: audible over
// silent, then fewer word errors.
func better(a, b *vproject.TakeRef) bool {
	as, bs := isSilent(a), isSilent(b)
	if as != bs {
		return bs
	}
	return a.WER < b.WER
}

func isSilent(t *vproject.TakeRef) bool {
	for _, r := range t.Reasons {
		if r == reasonSilent {
			return true
		}
	}
	return false
}

func countPassing(ts []vproject.TakeRef) int {
	n := 0
	for _, t := range ts {
		if t.Passed {
			n++
		}
	}
	return n
}

func countSettled(cs []vproject.Chunk) int {
	n := 0
	for _, c := range cs {
		if c.Status != vproject.ChunkPending {
			n++
		}
	}
	return n
}

// eta extrapolates the remaining spoken characters at the observed pace.
func eta(m *vproject.Manifest, elapsed float64) float64 {
	doneChars, left := 0, 0
	for _, c := range m.Chunks {
		if c.Status == vproject.ChunkPending {
			left += utf8.RuneCountInString(c.Spoken)
		} else {
			doneChars += utf8.RuneCountInString(c.Spoken)
		}
	}
	if doneChars == 0 {
		return float64(left) / estCharsPerSec * renderRTF
	}
	return float64(left) * elapsed / float64(doneChars)
}

// pruneTakes removes take files no chunk lists any more, keeping the
// superseded keys a delivery change recorded so a revert stays a cache hit.
func pruneTakes(j *job) (int, error) {
	keep := map[string]bool{}
	for _, c := range j.m.Chunks {
		for _, t := range c.Takes {
			keep[t.Key] = true
		}
		for _, k := range c.Superseded {
			keep[k] = true
		}
	}
	dir := filepath.Join(j.dir, vproject.TakesDir)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, e := range entries {
		key := e.Name()
		if ext := filepath.Ext(key); ext == ".wav" || ext == ".json" {
			key = key[:len(key)-len(ext)]
		}
		if !keep[key] && !e.IsDir() && os.Remove(filepath.Join(dir, e.Name())) == nil {
			n++
		}
	}
	return n, nil
}

// absPathRe finds absolute path tokens in an error text.
var absPathRe = regexp.MustCompile(`(^|[\s"'(:=])(/[^\s"'()<>]+)`)

// public is an error's text for a caller: no internal absolute path, ever
// (#154.5). Typed write/path errors become plain words naming only the file's
// base name; any other text has the daemon's own roots and any remaining
// absolute path removed. The detail belongs in the log, not in the answer.
func (p *producer) public(err error) string {
	return publicMessage(err, p.ports.Home(), p.ports.OutputRoot())
}

func publicMessage(err error, roots ...string) string {
	var we *vproject.WriteError
	var pe *fs.PathError
	var le *os.LinkError
	switch {
	case errors.Is(err, syscall.ENOSPC):
		return errDiskFull.Error()
	case errors.As(err, &we):
		return fmt.Sprintf("cannot write %s: %s", filepath.Base(we.Path), plainErrno(we.Err))
	case errors.As(err, &pe):
		return fmt.Sprintf("%s failed: %s", pe.Op, plainErrno(pe.Err))
	case errors.As(err, &le):
		return fmt.Sprintf("%s failed: %s", le.Op, plainErrno(le.Err))
	}
	msg := err.Error()
	for _, r := range roots {
		if r != "" && r != "/" {
			msg = regexp.MustCompile(regexp.QuoteMeta(r)+`[^\s"'()<>:]*`).ReplaceAllString(msg, "…")
		}
	}
	var re *requestError
	if errors.As(err, &re) {
		return msg // the caller's own words about the caller's own input: roots are already gone
	}
	return absPathRe.ReplaceAllStringFunc(msg, func(m string) string {
		sub := absPathRe.FindStringSubmatch(m)
		return sub[1] + filepath.Base(sub[2])
	})
}

// plainErrno is the OS reason of err without any path in it.
func plainErrno(err error) string {
	var en syscall.Errno
	if errors.As(err, &en) {
		return strings.ToLower(en.Error())
	}
	return "an error"
}

// Limits the CLI shares with the daemon, so a text there cannot drift.
const (
	MaxTakesPerChunk  = maxTakesPerChunk
	MaxListedProjects = maxListedProjects
)
