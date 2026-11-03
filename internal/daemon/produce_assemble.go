package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"math"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

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

// errOutputsBroken is the plain-words end of a publish whose rollback could
// not put the whole previous set back. The sentence is all a person is shown;
// the exact file names and causes go to the log (publish).
var errOutputsBroken = errors.New("the output files could not all be put in place, and the previous files could not all be restored; the previous version is kept beside the files")

// errOutputsKept is the plain-words end of a publish whose burst failed but
// whose rollback left the previous set whole: nothing a reader sees changed.
var errOutputsKept = errors.New("the output files could not be put in place; the previous files were kept")

// syncOutputDir makes the renames of one publish durable; a var so a test can
// count it.
var syncOutputDir = vproject.SyncDir

// syncPath fsyncs the file at path; a var so a test can observe it against the
// rename.
var syncPath = func(path string) error {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	err = f.Sync()
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// renameFile is os.Rename; a var so a test can stand in for another volume.
var renameFile = os.Rename

// linkFile is os.Link; a var so a test can stand in for a volume without hard
// links.
var linkFile = os.Link

// removeFile is os.Remove for the temp left after a link, a file a rollback
// takes out and a backup; a var so a test can make it fail.
var removeFile = os.Remove

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

// checkProjectOutputs is checkOutputs for the assembly of an existing project.
// When the project published before and a file at its output name is no longer
// provably its own (edited, re-exported, moved back), resume and the chunk ops
// have no overwrite flag to offer, so the answer says what the person can do:
// move the files away (#156.10).
func checkProjectOutputs(m *vproject.Manifest, stem string) (map[string]bool, error) {
	owned := ownedOutputs(m)
	if m.Outputs.WAV != "" && !m.Settings.Overwrite {
		for _, ext := range outputExts {
			pth := stem + ext
			if st, err := os.Lstat(pth); err == nil && st.Mode()&os.ModeSymlink == 0 && !owned[pth] {
				return nil, &requestError{fmt.Sprintf("%s was published by this voiceover but has since been changed or replaced; move or rename the files named %s.* beside it, then resume",
					filepath.Base(pth), filepath.Base(stem))}
			}
		}
	}
	return owned, checkOutputs(stem, m.Settings.Overwrite, owned)
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
	// A loudness-only delivery carries its target on the job until publish.
	if j.pendingLUFS != nil {
		m.Settings.LUFS = *j.pendingLUFS
	}
	if err := validLUFS(m.Settings.LUFS); err != nil {
		return err
	}
	stem, err := outputStem(m.Settings.OutPath)
	if err != nil {
		return err
	}
	if _, err := checkProjectOutputs(m, stem); err != nil {
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
	owned, err := checkProjectOutputs(m, stem) // write-time re-check
	if err != nil {
		return err
	}
	return diskErr(p.publish(j, stem, norm, tl, m, owned))
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
		return fmt.Errorf("chunk %d: %w", c.Index, err)
	}
	if err := writeSilence(w, trimmed.Rate, c.PauseAfter); err != nil {
		return fmt.Errorf("chunk %d: %w", c.Index, err)
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
// id is the staged file's identity (device and inode), taken once it is fully
// written: a rename or a link keeps it, so after the burst the file at dest is
// the burst's own exactly when it is the same file as id.
type staged struct {
	tmp, dest string
	id        os.FileInfo
}

// publish puts the five outputs in place as one set. It first STAGES all of
// them - every sibling as an fsynced temp beside its destination, the
// normalised WAV moved or copied to a temp beside its destination - so a full
// disk, a permission error or a cross-volume copy fails here, with the previous
// set untouched and the staged temps removed. Then it BACKS UP the previous
// set: each file the burst may replace gets a second name, ".<name>.prev-<id>",
// by hard link (a copy where the volume has none); the old file itself never
// moves. Only then does it place the staged set, the WAV last: a replaceable
// name by an atomic rename over the old file, a new name by link(2), which
// refuses to clobber. A published name is therefore never absent. If a place
// fails, undoBurst renames the backups back over what the burst placed and
// removes what it created, so the folder holds the whole previous set again -
// never a mixed one. On success the directory is synced first and the backups,
// this publish's and any left by a crashed one, go last: new data durable,
// then old data gone. The job's manifest records chunk times and outputs only
// when everything succeeded, and is saved at once.
func (p *producer) publish(j *job, stem, norm string, tl timeline, m *vproject.Manifest, owned map[string]bool) error {
	if err := os.MkdirAll(filepath.Dir(stem), outDirMode); err != nil {
		return err
	}
	sweepOutputTemps(stem, tempSweepMinAge)
	// Backups a crashed publish left: the only copy of the old set may be
	// among them, so they stay until this publish has succeeded.
	stale := listBackups(stem)
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
	replaceable := func(dest string) bool { return m.Settings.Overwrite || owned[dest] }
	backups, err := backupOutputs(set, replaceable)
	if err != nil {
		// Nothing was placed and no old file moved: drop what this call made.
		undoBurst(p.log, set, backups, 0)
		return fmt.Errorf("%w: %v", errOutputsKept, err)
	}
	for k, s := range set {
		left, err := placeStaged(s, replaceable(s.dest))
		if left != nil {
			p.log.Warn("produce: cannot remove a staged temp after publishing; it will be swept later",
				slog.String("file", filepath.Base(s.tmp)), slog.Any("error", errors.Unwrap(left)))
		}
		if err != nil {
			problems := undoBurst(p.log, set, backups, k)
			if len(problems) > 0 {
				// The exact names are for the log; the person is shown the sentence.
				p.log.Error("produce: the previous output files could not all be restored",
					slog.String("job", j.m.ID), slog.Any("error", err), slog.Any("problems", problems))
				return errOutputsBroken
			}
			if errors.Is(err, fs.ErrExist) {
				if k == 0 {
					return &requestError{fmt.Sprintf("%s appeared while the files were being written and was left alone; choose another output name or set overwrite", filepath.Base(s.dest))}
				}
				return fmt.Errorf("%w: %s appeared while the files were being written and was left alone", errOutputsKept, filepath.Base(s.dest))
			}
			return fmt.Errorf("%w: %v", errOutputsKept, err)
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
	// The loudness the published file was normalised to is the manifest's
	// target: a pending loudness-only change is persisted only now.
	j.m.Settings.LUFS, j.m.PendingLUFS, j.m.PendingStatus = m.Settings.LUFS, nil, ""
	j.m.Progress.ElapsedS, j.m.Progress.ETAS = m.Progress.ElapsedS, 0
	j.elapsedS = m.Progress.ElapsedS
	j.m.Notes = withNote(j.m.Notes, vproject.NoteLimitedLoudness, tl.limited)
	// Saved at once: a daemon that dies between the burst and run()'s save
	// must not leave a manifest that names the old files and a pending change
	// that already applied.
	if err := j.m.Save(j.dir); err != nil {
		p.log.Warn("produce: cannot save the manifest after publishing", slog.String("job", j.m.ID), slog.Any("error", err))
	}
	p.mu.Unlock()
	for _, b := range append(stale, backupPaths(backups)...) {
		if err := removeFile(b); err != nil && !errors.Is(err, fs.ErrNotExist) {
			p.log.Warn("produce: cannot remove a backup of the previous output; it will be removed by the next publish",
				slog.String("file", filepath.Base(b)), slog.Any("error", err))
		}
	}
	return nil
}

// sweepOutputTemps removes the crash leftovers of an earlier publish beside
// stem: the staged temps of its five outputs (".reel.srt.tmp-123") that nobody
// wrote to for minAge. It looks only at the names this project's outputs would
// have, in the output directory itself; the files are the user's, so nothing
// else there is touched. The backups of a publish (".prev-") are not temps and
// are never matched here: a crash can leave the only copy of the old set among
// them (see backupOutputs).
func sweepOutputTemps(stem string, minAge time.Duration) {
	dir, base := filepath.Split(stem)
	entries, _ := os.ReadDir(dir)
	for _, ext := range outputExts {
		prefix := vproject.TempPrefix(base + ext)
		for _, e := range entries {
			if e.IsDir() || !strings.HasPrefix(e.Name(), prefix) {
				continue
			}
			if info, err := e.Info(); err != nil || !info.Mode().IsRegular() || time.Since(info.ModTime()) < minAge {
				continue
			}
			_ = os.Remove(filepath.Join(dir, e.Name()))
		}
	}
}

// finalizeExport sets on the clone that becomes the .manifest.json export what
// the project will read once this assembly is over: the final status, the
// elapsed time and no ETA (#154.6). run() adopts the same elapsed value.
// The export never records a pending loudness change: it is written beside
// the file the change either produced or did not.
func finalizeExport(j *job, m *vproject.Manifest) {
	m.Status, m.Error = vproject.StatusDone, ""
	if m.AnyReview() {
		m.Status = vproject.StatusReview
	}
	m.PendingLUFS = nil
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
		set = append(set, staged{tmp: tmp, dest: f.dest})
	}
	wav, err := stageWAV(norm, m.Outputs.WAV)
	if err != nil {
		return set, err
	}
	set = append(set, staged{tmp: wav, dest: m.Outputs.WAV})
	for i := range set {
		if set[i].id, err = os.Lstat(set[i].tmp); err != nil {
			return set, err
		}
	}
	return set, nil
}

// stageWAV moves the normalised file to a temp name beside dest (a rename on
// one volume, a fsynced copy across volumes) and returns that name.
func stageWAV(norm, dest string) (string, error) {
	if err := os.Chmod(norm, outFileMode); err != nil {
		return "", err
	}
	// The rename below is durable only if the audio is: ffmpeg wrote norm
	// without an fsync, and a power cut after the rename could leave a WAV
	// of the right name and no samples (#154.2).
	if err := syncPath(norm); err != nil {
		return "", &vproject.WriteError{Path: dest, Err: err}
	}
	f, err := os.CreateTemp(filepath.Dir(dest), vproject.TempPattern(filepath.Base(dest)))
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

// placeStaged puts one staged file at its destination. A destination the
// project may replace (its own earlier output, or overwrite was asked for) is
// renamed over. Any other is claimed with link(2), which fails if a file
// appeared there since the check: the no-clobber promise is kept to the end,
// not only up to a pre-check (#154.3). A volume without hard links gets the
// rename, which keeps only the pre-check.
//
// leftover is set when the link worked but the staged temp could not be unlinked: the publish
// succeeded, and the temp (a second hard link to the output) is reaped by sweepOutputTemps.
func placeStaged(s staged, replace bool) (leftover, err error) {
	if replace {
		return nil, renameFile(s.tmp, s.dest)
	}
	err = linkFile(s.tmp, s.dest)
	switch {
	case err == nil:
		if rerr := removeFile(s.tmp); rerr != nil && !errors.Is(rerr, fs.ErrNotExist) {
			return rerr, nil
		}
		return nil, nil
	case errors.Is(err, fs.ErrExist):
		return nil, err
	default:
		return nil, renameFile(s.tmp, s.dest)
	}
}

// backupMark marks the backup of an output the burst may replace. It is not
// TempMark on purpose: every sweep of temps (sweepOutputTemps, a project's
// SweepStaleTemp) matches TempMark, and a backup must outlive a crash - it can
// be the only copy of the old file - until a publish has succeeded.
const backupMark = ".prev-"

// backupPrefix is the start of the backup names of the output called base,
// cut on a rune boundary so the finished name fits a file name.
func backupPrefix(base string) string {
	room := 255 - len(".") - len(backupMark) - 20
	for len(base) > room {
		_, n := utf8.DecodeLastRuneInString(base)
		base = base[:len(base)-n]
	}
	return "." + base + backupMark
}

// listBackups are the backups of the five outputs of stem that sit in its
// directory: the leftovers of a publish that did not finish (or whose cleanup
// did not). Regular files only.
func listBackups(stem string) []string {
	dir, base := filepath.Split(stem)
	if dir == "" {
		dir = "."
	}
	entries, _ := os.ReadDir(dir)
	var out []string
	for _, ext := range outputExts {
		prefix := backupPrefix(base + ext)
		for _, e := range entries {
			if strings.HasPrefix(e.Name(), prefix) && e.Type().IsRegular() {
				out = append(out, filepath.Join(dir, e.Name()))
			}
		}
	}
	return out
}

func backupPaths(backups map[string]string) []string {
	out := make([]string, 0, len(backups))
	for _, b := range backups {
		out = append(out, b)
	}
	return out
}

// backupOutputs gives every regular file the burst may replace a second name
// beside it, by hard link, so a failed burst can rename it back over the file
// the burst put there. The old file never moves: until the burst renames over
// it, the published name holds exactly what it held. A volume without hard
// links gets a copy (same bytes, mode and mtime) instead. A name nothing sits
// at, a directory and a symlink are left alone - there is nothing of ours to
// keep. dest -> backup. On an error the backups made so far are returned, so
// the caller can drop them.
func backupOutputs(set []staged, replaceable func(dest string) bool) (map[string]string, error) {
	backups := map[string]string{}
	for _, s := range set {
		if !replaceable(s.dest) {
			continue
		}
		st, err := os.Lstat(s.dest)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			continue
		case err != nil:
			return backups, err
		case !st.Mode().IsRegular():
			continue
		}
		b, err := backupFile(s.dest, st)
		if err != nil {
			return backups, err
		}
		backups[s.dest] = b
	}
	return backups, nil
}

// backupFile hard-links src to a fresh backup name, or copies it where the
// link is refused.
func backupFile(src string, st os.FileInfo) (string, error) {
	prefix := backupPrefix(filepath.Base(src))
	for range 8 {
		b := filepath.Join(filepath.Dir(src), prefix+strconv.FormatUint(rand.Uint64N(1<<40), 36))
		err := linkFile(src, b)
		switch {
		case err == nil:
			return b, nil
		case errors.Is(err, fs.ErrExist):
			continue
		default:
			return copyBackup(src, st, prefix)
		}
	}
	return copyBackup(src, st, prefix)
}

// copyBackup copies src to a new file named prefix + random beside it, with
// the bytes, mode and mtime of src, fsynced.
func copyBackup(src string, st os.FileInfo, prefix string) (string, error) {
	in, err := os.Open(src)
	if err != nil {
		return "", err
	}
	defer func() { _ = in.Close() }()
	out, err := os.CreateTemp(filepath.Dir(src), prefix+"*")
	if err != nil {
		return "", err
	}
	b := out.Name()
	_, err = io.Copy(out, in)
	if err == nil {
		err = out.Chmod(st.Mode().Perm())
	}
	if err == nil {
		err = out.Sync()
	}
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Chtimes(b, st.ModTime(), st.ModTime())
	}
	if err != nil {
		_ = os.Remove(b)
		return "", err
	}
	return b, nil
}

// undoBurst puts the published names back the way they were before a burst
// that placed set[:placed] and then failed. The staged temps that were never
// placed go. Each placed name, last first, is restored by renaming its backup
// back over it - atomically replacing the file the burst put there - or, where
// nothing was backed up, the file the burst created is removed. Both only
// while the file at the name is the burst's own (same file as the staged one):
// whatever else sits there appeared meanwhile and belongs to someone else, so
// it is left, and the miss is a problem. When no problem is left the set is
// whole again and the remaining backups go; otherwise they all stay, because
// one of them may be the only copy of an old file. It returns the problems in
// plain words, for the log.
func undoBurst(log *slog.Logger, set []staged, backups map[string]string, placed int) (problems []string) {
	for i := placed; i < len(set); i++ {
		_ = os.Remove(set[i].tmp)
	}
	left := map[string]string{} // backups not consumed
	for d, b := range backups {
		left[d] = b
	}
	for i := placed - 1; i >= 0; i-- {
		s := set[i]
		base := filepath.Base(s.dest)
		cur, lerr := os.Lstat(s.dest)
		foreign := lerr == nil && !os.SameFile(s.id, cur)
		b, hasBackup := backups[s.dest]
		switch {
		case foreign:
			problems = append(problems, fmt.Sprintf("%s was replaced by another program during the publish and was left alone", base))
		case hasBackup:
			if err := renameFile(b, s.dest); err != nil {
				problems = append(problems, fmt.Sprintf("the previous %s could not be put back (%v); it is kept as %s", base, err, filepath.Base(b)))
			} else {
				delete(left, s.dest)
			}
		case lerr == nil:
			if err := removeFile(s.dest); err != nil {
				problems = append(problems, fmt.Sprintf("the new %s could not be removed (%v)", base, err))
			}
		}
	}
	if len(problems) == 0 {
		for _, b := range left {
			if err := removeFile(b); err != nil && !errors.Is(err, fs.ErrNotExist) {
				log.Warn("produce: cannot remove a backup of the previous output; it will be removed by the next publish",
					slog.String("file", filepath.Base(b)), slog.Any("error", err))
			}
		}
	}
	return problems
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
	out, err := os.CreateTemp(filepath.Dir(dst), vproject.TempPattern(filepath.Base(dst)))
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
