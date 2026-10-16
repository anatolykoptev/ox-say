package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/anatolykoptev/ox-say/internal/pcm"
	"github.com/anatolykoptev/ox-say/internal/stt"
	"github.com/anatolykoptev/ox-say/internal/voices"
	"github.com/anatolykoptev/ox-say/internal/vproject"
	"github.com/anatolykoptev/ox-say/internal/wordalign"
)

const (
	trimFloorDB = gateFloorDB
	trimPadSec  = 0.04
	fadeSec     = 0.005
	outFileMode = 0o644
	outDirMode  = 0o755
	// maxPauseSec bounds one gap between chunks (consecutive [pause] markers
	// add up); silenceBlockSec is the most silence held in memory at once.
	maxPauseSec     = 600.0
	silenceBlockSec = 10.0
	workWAVPattern  = ".assembled" + vproject.TempMark + "*.wav"
	normSuffix      = ".norm.wav"
	// normLengthSlackSec is how far the normalised file may differ from the
	// timeline. the limiter chain keeps the length to a few samples; 50 ms covers
	// decoder padding and frame rounding yet is far below the loss of a word,
	// so a truncated or padded result cannot pass.
	normLengthSlackSec = 0.05
)

// outputExts are the five published siblings of one output stem.
var outputExts = []string{".wav", ".srt", ".vtt", ".words.json", ".manifest.json"}

var errDiskFull = errors.New("the disk is full: free some space, then resume the project")

// errOutputsRemoved is the plain-words end of a publish that failed after it
// had begun replacing the outputs: none are kept, rather than a mixed set.
var errOutputsRemoved = errors.New("the output files could not all be put in place, so none were kept; assemble the project again")

// errOutputsKept is the plain-words end of a publish whose very first rename
// failed: nothing was replaced, so the previous set is still whole.
var errOutputsKept = errors.New("the output files could not be put in place; the previous files were kept")

// syncOutputDir makes the renames of one publish durable; a var so a test can
// count it.
var syncOutputDir = vproject.SyncDir

// renameFile is os.Rename; a var so a test can stand in for another volume.
var renameFile = os.Rename

// outputStem is the common prefix of the five outputs of outPath, which must
// be an absolute .wav (any case).
func outputStem(outPath string) (string, error) {
	ext := filepath.Ext(outPath)
	if !filepath.IsAbs(outPath) || !strings.EqualFold(ext, ".wav") || filepath.Base(outPath) == ext {
		return "", &requestError{"the output must be an absolute path ending in .wav"}
	}
	return strings.TrimSuffix(outPath, ext), nil
}

// checkOutputs refuses an existing sibling unless overwrite is set or this
// project published it before (owned). Symlinks are always refused.
func checkOutputs(stem string, overwrite bool, owned map[string]bool) error {
	for _, ext := range outputExts {
		p := stem + ext
		st, err := os.Lstat(p)
		switch {
		case os.IsNotExist(err):
		case err != nil:
			return err
		case st.Mode()&os.ModeSymlink != 0:
			return &requestError{fmt.Sprintf("%s is a symlink; choose another output name", filepath.Base(p))}
		case !overwrite && !owned[p]:
			return &requestError{fmt.Sprintf("%s already exists; choose another output name or set overwrite", filepath.Base(p))}
		}
	}
	return nil
}

// timeline is what streaming the chunks leaves besides the audio.
type timeline struct {
	segs  []stt.Segment
	words []voices.Word
	rate  int
	total float64 // seconds of audio written
	// limited: the peak limiter pulled the loudest peaks down hard, or the
	// target could not be reached under the true-peak ceiling.
	limited bool
}

// assemble streams every chunk's picked take - trimmed, faded, then its gap -
// into a temp WAV, normalises it once (two passes), and publishes the five
// outputs. Only one take is in memory at a time. Nothing is published unless
// every step succeeded: a normalisation failure is an error, never a quiet
// fall back to the unnormalised file.
func (p *producer) assemble(j *job) error {
	if err := vproject.Contained(p.root, j.dir); err != nil {
		return fmt.Errorf("assemble: %w", err)
	}
	p.mu.Lock()
	m := j.m.Clone()
	p.mu.Unlock()
	if err := validLUFS(m.Settings.LUFS); err != nil {
		return err
	}
	stem, err := outputStem(m.Settings.OutPath)
	if err != nil {
		return err
	}
	if err := checkOutputs(stem, m.Settings.Overwrite, ownedOutputs(m)); err != nil {
		return err
	}
	work := filepath.Join(j.dir, vproject.WorkDir)
	if err := os.MkdirAll(work, vproject.DirMode); err != nil {
		return diskErr(err)
	}
	tmp, err := os.CreateTemp(work, workWAVPattern)
	if err != nil {
		return diskErr(err)
	}
	norm := tmp.Name() + normSuffix
	defer func() { _ = os.Remove(tmp.Name()); _ = os.Remove(norm) }()
	tl, err := p.stream(j.dir, m, tmp)
	if err != nil {
		return diskErr(err)
	}
	if tl.total <= 0 {
		return errors.New("every chunk is silent, so there is nothing to publish: regenerate the chunks marked review")
	}
	tl.limited, err = p.ports.Normalize(p.ctx, tmp.Name(), norm, m.Settings.LUFS, tl.total)
	if err != nil {
		return fmt.Errorf("loudness normalisation failed, so nothing was published: %w", err)
	}
	if rate, secs := wavInfoFile(norm); rate != tl.rate || secs <= 0 || math.Abs(secs-tl.total) > normLengthSlackSec {
		return fmt.Errorf("loudness normalisation left %d Hz / %.2f s instead of %d Hz / %.2f s, so nothing was published", rate, secs, tl.rate, tl.total)
	}
	if tl.limited {
		p.log.Warn("produce: loudness needed the peak limiter", slog.Float64("target_lufs", m.Settings.LUFS))
	}
	m.Notes = withNote(m.Notes, vproject.NoteLimitedLoudness, tl.limited)
	if err := checkOutputs(stem, m.Settings.Overwrite, ownedOutputs(m)); err != nil { // write-time re-check
		return err
	}
	return diskErr(p.publish(j, stem, norm, tl, m))
}

// stream writes the timeline into f and closes it. On any error the temp
// file is closed and removed.
func (p *producer) stream(dir string, m *vproject.Manifest, f *os.File) (tl timeline, err error) {
	var w *pcm.Writer
	defer func() {
		switch {
		case err == nil:
		case w != nil:
			_ = w.Abort()
		default:
			_ = f.Close()
		}
	}()
	work := filepath.Join(dir, vproject.WorkDir)
	stretch := func(clip pcm.Clip, rate float64) (pcm.Clip, error) {
		return atempoClip(p.ctx, work, clip, rate)
	}
	for i := range m.Chunks {
		c := &m.Chunks[i]
		clip, d, err := loadPick(dir, c)
		if err != nil {
			return tl, err
		}
		if w == nil {
			if w, err = pcm.NewWriter(f, clip.Rate); err != nil {
				return tl, err
			}
			tl.rate = clip.Rate
		}
		if err := tl.add(w, c, clip, d.Heard, stretch); err != nil {
			return tl, err
		}
	}
	if w == nil {
		return tl, errors.New("nothing to assemble")
	}
	return tl, w.Close()
}

// loadPick reads the picked take of c and its sidecar; the pick is a key from
// disk and is checked before it becomes a path.
func loadPick(dir string, c *vproject.Chunk) (pcm.Clip, takeDetail, error) {
	if !vproject.ValidKey(c.Pick) {
		return pcm.Clip{}, takeDetail{}, fmt.Errorf("chunk %d has no picked take", c.Index)
	}
	takes := filepath.Join(dir, vproject.TakesDir)
	d, err := readDetail(filepath.Join(takes, c.Pick+".json"))
	if err != nil || d.Ref.Key != c.Pick {
		return pcm.Clip{}, takeDetail{}, fmt.Errorf("chunk %d has no usable take: its sidecar is missing or belongs to another take", c.Index)
	}
	clip, err := readClip(filepath.Join(takes, c.Pick+".wav"))
	if err != nil {
		return pcm.Clip{}, takeDetail{}, fmt.Errorf("chunk %d has no usable take: %w", c.Index, err)
	}
	return clip, d, nil
}

// add appends one chunk at tl.total: its trimmed take, stretched by a
// non-neutral pace, faded, then its gap. It records the chunk's times and
// the subtitle cues and word timings on the shared timeline; a paced
// chunk's words scale by 1/rate so they keep their place on the audio.
func (tl *timeline) add(w *pcm.Writer, c *vproject.Chunk, clip pcm.Clip, heard []voices.Word, stretch paceStretch) error {
	if !(c.PauseAfter >= 0 && c.PauseAfter <= maxPauseSec) { // also false for NaN
		return fmt.Errorf("chunk %d: a pause of %v s is out of range", c.Index, c.PauseAfter)
	}
	if !(c.Pace == 0 || (c.Pace >= vproject.PaceMin && c.Pace <= vproject.PaceMax)) { // NaN and ±Inf fail too
		return fmt.Errorf("chunk %d: a pace of %v is out of range", c.Index, c.Pace)
	}
	rate := c.Pace
	if rate == 0 {
		rate = 1
	}
	trimmed, lead := clip.Trim(trimFloorDB, trimPadSec)
	if len(trimmed.S) == 0 {
		if c.Status != vproject.ChunkReview {
			return fmt.Errorf("chunk %d: the picked take is silent", c.Index)
		}
		// Every take of a review chunk was silent: the file is still made, with
		// the chunk's gap and no speech, and the chunk stays flagged for a listen.
		c.StartS, c.EndS = round2(tl.total), round2(tl.total)
		tl.total += c.PauseAfter
		return writeSilence(w, clip.Rate, c.PauseAfter)
	}
	if rate != 1 {
		if stretch == nil {
			return fmt.Errorf("chunk %d: a pace of %v cannot be stretched here", c.Index, c.Pace)
		}
		var err error
		if trimmed, err = stretch(trimmed, rate); err != nil {
			return fmt.Errorf("chunk %d: %w", c.Index, err)
		}
	}
	at, dur := tl.total, trimmed.Seconds()
	ws := wordalign.AlignWords(c.Text, heard, clip.Seconds())
	for k := range ws {
		ws[k].S = at + math.Min(dur, math.Max(0, ws[k].S-lead)/rate)
		ws[k].E = at + math.Min(dur, math.Max(0, ws[k].E-lead)/rate)
	}
	for _, q := range wordalign.Cues(ws) {
		tl.segs = append(tl.segs, stt.Segment{S: q.S, E: q.E, Text: q.Text})
	}
	tl.words = append(tl.words, ws...)
	if err := w.Write(trimmed.Fade(fadeSec)); err != nil {
		return err
	}
	if err := writeSilence(w, trimmed.Rate, c.PauseAfter); err != nil {
		return err
	}
	c.StartS, c.EndS = round2(at), round2(at+dur)
	tl.total = at + dur + c.PauseAfter
	return nil
}

// writeSilence writes sec of silence in blocks, so a long gap is never held
// in memory whole.
func writeSilence(w *pcm.Writer, rate int, sec float64) error {
	for sec > 0 {
		step := math.Min(sec, silenceBlockSec)
		if err := w.Write(pcm.Silence(rate, step)); err != nil {
			return err
		}
		sec -= step
	}
	return nil
}

// withNote returns notes with note present exactly when want.
func withNote(notes []string, note string, want bool) []string {
	out := make([]string, 0, len(notes)+1)
	for _, n := range notes {
		if n != note {
			out = append(out, n)
		}
	}
	if want {
		out = append(out, note)
	}
	return out
}

// staged is a file written beside its destination, not yet renamed to it.
type staged struct{ tmp, dest string }

// publish puts the five outputs in place as one set. It first STAGES all of
// them - every sibling as an fsynced temp beside its destination, the
// normalised WAV moved or copied to a temp beside its destination - so a full
// disk, a permission error or a cross-volume copy fails here, with the previous
// set untouched and the staged temps removed. Only then does it rename the
// staged set into place, the WAV last. If a rename in that burst fails, the
// whole output set (new and old) is removed rather than left mixed. The job's
// manifest records chunk times and outputs only when everything succeeded.
func (p *producer) publish(j *job, stem, norm string, tl timeline, m *vproject.Manifest) error {
	if err := os.MkdirAll(filepath.Dir(stem), outDirMode); err != nil {
		return err
	}
	finalizeExport(j, m)
	sum, err := fileSHA(norm)
	if err != nil {
		return err
	}
	m.Outputs = vproject.Outputs{WAVSHA256: sum, WAV: stem + ".wav", SRT: stem + ".srt", VTT: stem + ".vtt",
		Words: stem + ".words.json", Manifest: stem + ".manifest.json", DurationS: round2(tl.total)}
	set, err := stageOutputs(norm, tl, m)
	if err != nil {
		return err
	}
	for k, s := range set {
		if err := renameFile(s.tmp, s.dest); err != nil {
			if k == 0 {
				// Nothing was replaced yet: drop the staged temps only and keep
				// the previous good set (#154.8).
				for _, st := range set {
					_ = os.Remove(st.tmp)
				}
				return fmt.Errorf("%w: %v", errOutputsKept, err)
			}
			removeOutputs(set, m.Outputs)
			return fmt.Errorf("%w: %v", errOutputsRemoved, err)
		}
	}
	if err := syncOutputDir(filepath.Dir(stem)); err != nil {
		p.log.Warn("produce: cannot sync the output directory", slog.Any("error", err))
	}
	p.mu.Lock()
	for i := range j.m.Chunks {
		j.m.Chunks[i].StartS, j.m.Chunks[i].EndS = m.Chunks[i].StartS, m.Chunks[i].EndS
	}
	j.m.Outputs = m.Outputs
	j.m.Progress.ElapsedS, j.m.Progress.ETAS = m.Progress.ElapsedS, 0
	j.elapsedS = m.Progress.ElapsedS
	j.m.Notes = withNote(j.m.Notes, vproject.NoteLimitedLoudness, tl.limited)
	p.mu.Unlock()
	return nil
}

// finalizeExport sets on the clone that becomes the .manifest.json export what
// the project will read once this assembly is over: the final status, the
// elapsed time and no ETA (#154.6). run() adopts the same elapsed value.
func finalizeExport(j *job, m *vproject.Manifest) {
	m.Status, m.Error = vproject.StatusDone, ""
	if m.AnyReview() {
		m.Status = vproject.StatusReview
	}
	m.Progress.ETAS = 0
	if !j.started.IsZero() {
		m.Progress.ElapsedS = round2(time.Since(j.started).Seconds())
	}
}

// stageOutputs stages the siblings and then the WAV (last); on a failure it
// removes what it staged and nothing else.
func stageOutputs(norm string, tl timeline, m *vproject.Manifest) (set []staged, err error) {
	defer func() {
		if err != nil {
			for _, s := range set {
				_ = os.Remove(s.tmp)
			}
			set = nil
		}
	}()
	wj, err := json.MarshalIndent(tl.words, "", " ")
	if err != nil {
		return nil, err
	}
	export, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return nil, err
	}
	for _, f := range []struct {
		dest string
		data []byte
	}{{m.Outputs.SRT, []byte(toSRT(tl.segs))}, {m.Outputs.VTT, []byte(toVTT(tl.segs))}, {m.Outputs.Words, wj}, {m.Outputs.Manifest, export}} {
		tmp, err := vproject.Stage(f.dest, f.data, outFileMode)
		if err != nil {
			return set, err
		}
		set = append(set, staged{tmp, f.dest})
	}
	wav, err := stageWAV(norm, m.Outputs.WAV)
	if err != nil {
		return set, err
	}
	return append(set, staged{wav, m.Outputs.WAV}), nil
}

// stageWAV moves the normalised file to a temp name beside dest (a rename on
// one volume, a fsynced copy across volumes) and returns that name.
func stageWAV(norm, dest string) (string, error) {
	if err := os.Chmod(norm, outFileMode); err != nil {
		return "", err
	}
	f, err := os.CreateTemp(filepath.Dir(dest), "."+filepath.Base(dest)+vproject.TempMark+"*")
	if err != nil {
		return "", err
	}
	tmp := f.Name()
	_ = f.Close()
	if err := moveFile(norm, tmp); err != nil {
		_ = os.Remove(tmp)
		return "", &vproject.WriteError{Path: dest, Err: err}
	}
	return tmp, nil
}

// removeOutputs deletes the five output files and any staged temp left: never
// a directory, which is the user's.
func removeOutputs(set []staged, out vproject.Outputs) {
	paths := []string{out.WAV, out.SRT, out.VTT, out.Words, out.Manifest}
	for _, s := range set {
		paths = append(paths, s.tmp)
	}
	for _, path := range paths {
		if st, err := os.Lstat(path); err == nil && !st.IsDir() {
			_ = os.Remove(path)
		}
	}
}

// moveFile renames src to dst; across volumes (EXDEV) it copies beside dst and
// renames there, so dst is never seen half written.
func moveFile(src, dst string) error {
	err := renameFile(src, dst)
	if !errors.Is(err, syscall.EXDEV) {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()
	out, err := os.CreateTemp(filepath.Dir(dst), "."+filepath.Base(dst)+vproject.TempMark+"*")
	if err != nil {
		return err
	}
	tmp := out.Name()
	_, err = io.Copy(out, in)
	if err == nil {
		err = out.Chmod(outFileMode)
	}
	if err == nil {
		err = out.Sync()
	}
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = renameFile(tmp, dst)
	}
	if err != nil {
		_ = os.Remove(tmp)
	}
	return err
}

// ownedOutputs are the output files the project can prove are its own
// (ownedPaths): empty when the proof fails, so files that merely sit at the
// project's output name are never overwritten without the overwrite flag.
func ownedOutputs(m *vproject.Manifest) map[string]bool {
	owned := map[string]bool{}
	paths, err := ownedPaths(m)
	if err != nil {
		return owned
	}
	for _, p := range paths {
		owned[p] = true
	}
	return owned
}

// diskErr turns ENOSPC into plain words.
func diskErr(err error) error {
	if errors.Is(err, syscall.ENOSPC) {
		return errDiskFull
	}
	return err
}
