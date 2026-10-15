package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"syscall"

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
)

// outputExts are the five published siblings of one output stem.
var outputExts = []string{".wav", ".srt", ".vtt", ".words.json", ".manifest.json"}

var errDiskFull = errors.New("the disk is full: free some space, then resume the project")

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
	if err := p.ports.Normalize(p.ctx, tmp.Name(), norm, m.Settings.LUFS, tl.total); err != nil {
		return fmt.Errorf("loudness normalisation failed, so nothing was published: %w", err)
	}
	if rate, secs := wavInfoFile(norm); rate != tl.rate || secs <= 0 {
		return fmt.Errorf("loudness normalisation left %d Hz / %.2f s instead of %d Hz of audio, so nothing was published", rate, secs, tl.rate)
	}
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
		if err := tl.add(w, c, clip, d.Heard); err != nil {
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

// add appends one chunk at tl.total: its trimmed, faded take, then its gap.
// It records the chunk's times and the subtitle cues and word timings on the
// shared timeline.
func (tl *timeline) add(w *pcm.Writer, c *vproject.Chunk, clip pcm.Clip, heard []voices.Word) error {
	if !(c.PauseAfter >= 0 && c.PauseAfter <= maxPauseSec) { // also false for NaN
		return fmt.Errorf("chunk %d: a pause of %v s is out of range", c.Index, c.PauseAfter)
	}
	trimmed, lead := clip.Trim(trimFloorDB, trimPadSec)
	if len(trimmed.S) == 0 {
		return fmt.Errorf("chunk %d: the picked take is silent", c.Index)
	}
	at, dur := tl.total, trimmed.Seconds()
	ws := wordalign.AlignWords(c.Text, heard, clip.Seconds())
	for k := range ws {
		ws[k].S = at + math.Min(dur, math.Max(0, ws[k].S-lead))
		ws[k].E = at + math.Min(dur, math.Max(0, ws[k].E-lead))
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

// publish writes the siblings and then moves the normalised WAV into place
// (last, so its appearance means the rest is there); the job's manifest records
// chunk times and outputs only when everything succeeded. A failure removes
// what this call created.
func (p *producer) publish(j *job, stem, norm string, tl timeline, m *vproject.Manifest) (err error) {
	if err := os.MkdirAll(filepath.Dir(stem), outDirMode); err != nil {
		return err
	}
	m.Outputs = vproject.Outputs{WAV: stem + ".wav", SRT: stem + ".srt", VTT: stem + ".vtt",
		Words: stem + ".words.json", Manifest: stem + ".manifest.json", DurationS: round2(tl.total)}
	var created []string
	defer func() {
		if err != nil {
			for _, path := range created {
				_ = os.Remove(path)
			}
		}
	}()
	wj, err := json.MarshalIndent(tl.words, "", " ")
	if err != nil {
		return err
	}
	export, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	for _, f := range []struct {
		path string
		data []byte
	}{{m.Outputs.SRT, []byte(toSRT(tl.segs))}, {m.Outputs.VTT, []byte(toVTT(tl.segs))}, {m.Outputs.Words, wj}, {m.Outputs.Manifest, export}} {
		if _, serr := os.Lstat(f.path); os.IsNotExist(serr) {
			created = append(created, f.path)
		}
		if err = vproject.WriteAtomic(f.path, f.data, outFileMode); err != nil {
			return err
		}
	}
	if _, serr := os.Lstat(m.Outputs.WAV); os.IsNotExist(serr) {
		created = append(created, m.Outputs.WAV)
	}
	if err = os.Chmod(norm, outFileMode); err != nil {
		return err
	}
	if err = moveFile(norm, m.Outputs.WAV); err != nil {
		return err
	}
	p.mu.Lock()
	for i := range j.m.Chunks {
		j.m.Chunks[i].StartS, j.m.Chunks[i].EndS = m.Chunks[i].StartS, m.Chunks[i].EndS
	}
	j.m.Outputs = m.Outputs
	p.mu.Unlock()
	return nil
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

func ownedOutputs(m *vproject.Manifest) map[string]bool {
	owned := map[string]bool{}
	for _, p := range []string{m.Outputs.WAV, m.Outputs.SRT, m.Outputs.VTT, m.Outputs.Words, m.Outputs.Manifest} {
		if p != "" {
			owned[p] = true
		}
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
