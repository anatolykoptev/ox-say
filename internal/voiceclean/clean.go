// Package voiceclean is the ffmpeg orchestration of voice cleanup: a file or video in, the same file out with only its
// first audio stream replaced by the cleaned voice, mixed back with a share of the original. The model itself is the
// ox-clean helper (mono, 48 kHz, float WAV in and out); everything that touches ffmpeg is ported from the voice-clean
// script (~/Developer/utilities/voice-clean/voice-clean), graph for graph and refusal for refusal.
//
// This package writes a user's file. The rules that keep it safe, each pinned by a test:
//   - the input is never written, and an output that is the input (same path, hard link, symlink, other spelling on a
//     case-insensitive volume) is refused;
//   - an existing output is replaced only on request, and only by a complete file: the result is written beside the
//     output under a name this run created exclusively, flushed, and moved into place (rename, or link when nothing
//     may be replaced), so a cancel or a crash leaves the output as it was and a concurrent run cannot clobber it;
//   - on any error or cancel the run removes what it created (its scratch directory and its part file) and nothing
//     else;
//   - the forbidden trees (the daemon passes the meetings directory) are compared by resolved path and by file
//     identity, so neither a symlink nor the other case spelling of a directory gets in.
//
// Only internal/daemon imports this package (TestOnlyTheDaemonImportsThisPackage): cleanup is never applied to
// meetings or dictation.
package voiceclean

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/anatolykoptev/ox-say/internal/oneshot"
)

// Runner starts a tool and returns its stdout. Production is oneshot.Run with a bounded stderr tail; tests pass a
// recorder or the real exec.
type Runner func(ctx context.Context, bin string, args []string) ([]byte, error)

// Options is one cleanup run.
type Options struct {
	In, Out         string   // absolute paths
	Wet             float64  // 0..1 (the caller applies the 0.85 default)
	Stereo          string   // "mid" (default) | "channels"
	Overwrite       bool     // replace an existing Out
	Engine          string   // path to ox-clean
	ModelsDir       string   // passed to ox-clean as --models
	FFmpeg, FFprobe string   // default "ffmpeg", "ffprobe"
	Forbidden       []string // directory trees In and Out may not live under (the daemon passes <Home>/meetings)
	MaxSeconds      float64  // 0 = 7200
	TempDir         string   // "" = os.TempDir()
	Run             Runner   // nil = exec; ox-clean is wrapped in /usr/bin/nice -n 15 as voice-clean does

	// offsetSkew is added to the first guess of the audio offset; tests set it per run to stand in for an ffmpeg
	// whose encoder or muxer delay differs from the one the guess was measured on. Unexported: production never sets it.
	offsetSkew float64
}

// Result describes a finished run.
type Result struct {
	Out                   string
	Video                 bool
	Channels, SampleRate  int
	Seconds, ModelSeconds float64
	Stereo                string // "mid" or "channels" for a stereo source, "" for mono
	Wet                   float64
	Dropped               []DroppedStream // input streams the output leaves out (extra audio tracks, cover art, data, subtitles ...)
	// LagMs is the measured audio-to-picture lag of the output minus the input's, in milliseconds, after any
	// correction. Within +-1 ms for every published video run; 0 for audio-only.
	LagMs float64
}

const (
	defaultMaxSeconds = 7200
	modelRate         = 48000
	minRate           = 8000 // the model's lower band limit
	niceBin           = "/usr/bin/nice"
	waitDelay         = 5 * time.Second
)

// Seams for tests: the free-space probe, the random part of the part file's name, hard-linking and the walk bound.
var (
	statFS     = diskFree
	partSuffix = randomHex
	linkFile   = os.Link
	// afterPublishCheck runs in the no-hard-link fallback between the pre-check and the atomic rename, where a
	// concurrent creator would land.
	afterPublishCheck = func() {}
	// maxWalk bounds the hard-link search of a forbidden tree (directory entries visited).
	maxWalk = 500_000
)

// execRunner is the production Runner.
func execRunner(ctx context.Context, bin string, args []string) ([]byte, error) {
	return oneshot.Run(ctx, bin, args, oneshot.Options{StderrTail: stderrKeep, WaitDelay: waitDelay})
}

// Run cleans o.In into o.Out. The error is nil, a *Error, or the context's own error when it ended (nothing is left
// behind in that case either).
func Run(ctx context.Context, o Options) (*Result, error) {
	if err := normalize(&o); err != nil {
		return nil, err
	}
	if o.Run == nil {
		o.Run = execRunner
	}
	j := &job{ctx: ctx, o: o}
	return j.run()
}

func normalize(o *Options) error {
	if o.In == "" || o.Out == "" || !filepath.IsAbs(o.In) || !filepath.IsAbs(o.Out) {
		return newErr(CodeInvalidRequest, "in and out must be absolute paths")
	}
	o.In, o.Out = filepath.Clean(o.In), filepath.Clean(o.Out)
	if !audioExts[extOf(o.Out)] && !videoExts[extOf(o.Out)] {
		return newErr(CodeInvalidRequest, "the output must be .wav, .flac, .mp3 or .m4a for audio, or .mov, .mp4, .m4v, .mkv or .webm for video")
	}
	if !(o.Wet >= 0 && o.Wet <= 1) {
		return newErr(CodeInvalidRequest, "wet must be between 0 and 1")
	}
	switch o.Stereo {
	case "":
		o.Stereo = "mid"
	case "mid", "channels":
	default:
		return newErr(CodeInvalidRequest, `stereo must be "mid" or "channels"`)
	}
	if o.MaxSeconds < 0 || math.IsNaN(o.MaxSeconds) {
		return newErr(CodeInvalidRequest, "max seconds must not be negative")
	}
	if o.MaxSeconds == 0 {
		o.MaxSeconds = defaultMaxSeconds
	}
	if o.FFmpeg == "" {
		o.FFmpeg = "ffmpeg"
	}
	if o.FFprobe == "" {
		o.FFprobe = "ffprobe"
	}
	if o.TempDir == "" {
		o.TempDir = os.TempDir()
	}
	abs, err := filepath.Abs(o.TempDir)
	if err != nil {
		return newErr(CodeInvalidRequest, "the temporary directory is not usable")
	}
	o.TempDir = abs
	return nil
}

type job struct {
	ctx context.Context
	o   Options

	temp string   // scratch directory this run created; "" until then
	lock *os.File // the marker of temp, locked for the whole run
	part string   // part file this run created exclusively; "" when none is owned
	plan *videoPlan
	// dropped is what the output leaves out of the input, reported in Result.Dropped
	dropped []DroppedStream
	// lagMs is the verified output-minus-input A/V lag, reported in Result.LagMs
	lagMs float64
}

func (j *job) run() (res *Result, err error) {
	o := j.o
	if err := j.checkPaths(); err != nil {
		return nil, err
	}
	inSt, err := os.Stat(o.In)
	if err != nil {
		return nil, newErr(CodeNotFound, "the input file does not exist or cannot be read")
	}
	if !inSt.Mode().IsRegular() {
		return nil, newErr(CodeInvalidRequest, "the input is not a regular file")
	}
	if err := j.checkOut(inSt); err != nil {
		return nil, err
	}

	info, err := j.probe()
	if err != nil {
		return nil, err
	}
	video := info.HasVideo
	if video && !videoExts[extOf(o.Out)] {
		return nil, newErr(CodeInvalidRequest, "the input has a picture: the output must be .mov, .mp4, .m4v, .mkv or .webm")
	}
	if !video && !audioExts[extOf(o.Out)] && extOf(o.Out) != "mp4" {
		return nil, newErr(CodeInvalidRequest, "the input is audio only: the output must be .wav, .flac, .mp3 or .m4a")
	}
	if info.Channels != 1 && info.Channels != 2 {
		return nil, newErr(CodeUnsupportedChannels, fmt.Sprintf("the audio has %d channels; only mono and stereo can be cleaned", info.Channels))
	}
	if info.SampleRate < minRate {
		return nil, newErr(CodeInvalidRequest, fmt.Sprintf("the sample rate %d Hz is below the model's 8 kHz minimum", info.SampleRate))
	}
	if info.Seconds <= 0 {
		return nil, newErr(CodeInvalidRequest, "the length of the audio cannot be determined")
	}
	if info.Seconds > o.MaxSeconds {
		return nil, newErr(CodeTooLong, fmt.Sprintf("the audio is %.0f seconds; the limit is %.0f", info.Seconds, o.MaxSeconds))
	}
	if video {
		plan, err := planVideo(info, extOf(o.Out))
		if err != nil {
			return nil, err
		}
		j.plan = plan
		j.dropped = plan.dropped
	} else {
		j.dropped = audioDropped(info, extOf(o.Out))
	}
	if st, err := os.Stat(o.Engine); err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0o111 == 0 {
		return nil, newErr(CodeUnavailable, "the cleanup engine is not installed")
	}
	if o.ModelsDir == "" {
		return nil, newErr(CodeUnavailable, "the cleanup model is not installed")
	}
	if err := j.diskPreflight(info, inSt.Size()); err != nil {
		return nil, err
	}

	temp, err := os.MkdirTemp(o.TempDir, "voice-clean.")
	if err != nil {
		return nil, newErr(CodeUnavailable, "cannot create a scratch directory")
	}
	j.temp = temp
	defer j.cleanup()
	if j.lock, err = claimScratch(temp); err != nil {
		return nil, newErr(CodeUnavailable, "cannot create a scratch directory")
	}

	mix, modelSeconds, err := j.mixdown(info)
	if err != nil {
		return nil, err
	}
	if err := j.write(info, inSt, mix); err != nil {
		return nil, err
	}
	res = &Result{Out: o.Out, Video: video, Channels: info.Channels, SampleRate: info.SampleRate,
		Seconds: info.Seconds, ModelSeconds: modelSeconds, Wet: o.Wet}
	res.Dropped = j.dropped
	res.LagMs = j.lagMs
	if info.Channels == 2 {
		res.Stereo = o.Stereo
	}
	return res, nil
}

// cleanup removes what this run created: its part file if it still owns one, and its scratch directory. It never
// looks at the output and never touches a name it did not create.
func (j *job) cleanup() {
	if j.part != "" {
		_ = os.Remove(j.part)
		j.part = ""
	}
	if j.temp != "" && filepath.IsAbs(j.temp) && strings.HasPrefix(filepath.Base(j.temp), "voice-clean.") {
		_ = os.RemoveAll(j.temp)
		j.temp = ""
	}
	if j.lock != nil {
		_ = j.lock.Close()
		j.lock = nil
	}
}

// ---- path guards ----------------------------------------------------------------------------------------------------

// checkPaths refuses an In or Out inside a forbidden tree. What it covers:
//   - location: the comparison is made on resolved paths (symlinks of the longest existing prefix, so an Out that does
//     not exist yet but whose parent is a link into the tree is caught) and on file identity of every existing
//     ancestor (so another spelling of the same directory, such as its other case on a case-insensitive volume, is
//     caught too);
//   - hard links: an In, or an existing Out, with more than one link may be another name of a file in the tree, so
//     each forbidden tree is walked for the same device and inode (walkForHardLink). The walk runs only for such files,
//     costs one lstat per directory entry of the tree, does not follow symlinks, and refuses (fail closed) when it
//     cannot finish: a directory or entry it cannot read, or more than maxWalk entries.
//
// It does not cover a copy of a meeting's audio: a copied file is an ordinary file.
func (j *job) checkPaths() error {
	for _, f := range j.o.Forbidden {
		if f == "" {
			continue
		}
		if !filepath.IsAbs(f) {
			return newErr(CodeInvalidRequest, "a forbidden tree must be an absolute path")
		}
		root, err := resolvePrefix(filepath.Clean(f))
		if err != nil {
			return newErr(CodeInvalidRequest, "a path could not be resolved")
		}
		rootSt, _ := os.Stat(root)
		for _, p := range []string{j.o.In, j.o.Out} { // both: the output must not land in the tree either
			if st := linkedFile(p); st != nil {
				found, err := walkForHardLink(root, st)
				if err != nil || found {
					return newErr(CodeForbiddenPath, "voice cleanup does not work on files in this location")
				}
			}
			real, err := resolvePrefix(p)
			if err != nil {
				return newErr(CodeInvalidRequest, "a path could not be resolved")
			}
			if under(root, real) || sameAsAncestor(rootSt, real) {
				return newErr(CodeForbiddenPath, "voice cleanup does not work on files in this location")
			}
		}
	}
	return nil
}

// linkedFile returns the file at p (the link itself for an Out that is a symlink, the target for an In) when it has
// more than one hard link, nil otherwise or when it does not exist.
func linkedFile(p string) os.FileInfo {
	st, err := os.Stat(p)
	if lst, lerr := os.Lstat(p); lerr == nil && lst.Mode()&os.ModeSymlink == 0 {
		st, err = lst, nil
	}
	if err != nil || st.IsDir() {
		return nil
	}
	if sys, ok := st.Sys().(*syscall.Stat_t); ok && uint64(sys.Nlink) > 1 {
		return st
	}
	return nil
}

// walkForHardLink reports whether the tree under root holds another name for the file st. It fails (error) when the
// tree is bigger than maxWalk entries or any part of it cannot be read, so the caller refuses rather than guesses.
func walkForHardLink(root string, st os.FileInfo) (bool, error) {
	var seen int
	found := false
	errTooBig := errors.New("tree too large to search")
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil // vanished while walking
			}
			return err // an unreadable directory is a search that did not finish: the caller refuses
		}
		if seen++; seen > maxWalk {
			return errTooBig
		}
		if d.Type().IsRegular() {
			fi, ierr := d.Info()
			if ierr != nil {
				if errors.Is(ierr, fs.ErrNotExist) {
					return nil
				}
				return ierr
			}
			if os.SameFile(fi, st) {
				found = true
				return fs.SkipAll
			}
		}
		return nil
	})
	return found, err
}

// resolvePrefix returns p with the symlinks of its longest existing prefix resolved and the missing tail appended.
func resolvePrefix(p string) (string, error) {
	p = filepath.Clean(p)
	tail := ""
	for cur := p; ; {
		real, err := filepath.EvalSymlinks(cur)
		if err == nil {
			return filepath.Join(real, tail), nil
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return p, nil
		}
		tail = filepath.Join(filepath.Base(cur), tail)
		cur = parent
	}
}

// under reports whether p is root or inside it, by path components.
func under(root, p string) bool {
	rel, err := filepath.Rel(root, p)
	if err != nil {
		return false
	}
	return rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)))
}

// sameAsAncestor reports whether p or any of its existing ancestors is the very directory rootSt describes.
func sameAsAncestor(rootSt os.FileInfo, p string) bool {
	if rootSt == nil {
		return false
	}
	for cur := p; ; cur = filepath.Dir(cur) {
		if st, err := os.Stat(cur); err == nil && os.SameFile(st, rootSt) {
			return true
		}
		if filepath.Dir(cur) == cur {
			return false
		}
	}
}

// checkOut refuses an output that is the input (by path and by file identity) or that already exists without
// Overwrite, and an output directory that is not there.
func (j *job) checkOut(inSt os.FileInfo) error {
	o := j.o
	dir := filepath.Dir(o.Out)
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return newErr(CodeInvalidRequest, "the output directory does not exist")
	}
	rin, _ := resolvePrefix(o.In)
	rout, _ := resolvePrefix(o.Out)
	if rin == rout {
		return newErr(CodeSameFile, "the output is the input file; refusing to overwrite it")
	}
	if outSt, err := os.Stat(o.Out); err == nil && os.SameFile(inSt, outSt) {
		return newErr(CodeSameFile, "the output is the input file; refusing to overwrite it")
	}
	lst, err := os.Lstat(o.Out) // Lstat: a dangling link is something that exists
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return newErr(CodeInvalidRequest, "the output path cannot be inspected")
	}
	if lst.IsDir() {
		return newErr(CodeInvalidRequest, "the output is a directory")
	}
	if !o.Overwrite {
		return newErr(CodeExists, "the output file already exists")
	}
	return nil
}

// ---- probe and preflight ----------------------------------------------------------------------------------------------

func (j *job) probe() (*probeInfo, error) {
	raw, err := j.o.Run(withTool(j.ctx, ToolProbe), j.o.FFprobe, probeArgs(j.o.In))
	if err != nil {
		if cerr := j.ctx.Err(); cerr != nil {
			return nil, cerr
		}
		if notStarted(err) {
			return nil, newErr(CodeUnavailable, "ffprobe is not installed (brew install ffmpeg)")
		}
		return nil, newErrDetail(CodeInvalidRequest, "This file is not audio or video OxSay can read.", "ffprobe: "+tailClip(err.Error(), stderrKeep))
	}
	info, err := parseProbe(raw)
	if errors.Is(err, errNoAudio) {
		return nil, newErr(CodeNoAudio, "the file has no audio stream")
	}
	if err != nil {
		return nil, newErrDetail(CodeInvalidRequest, "This file is not audio or video OxSay can read.", err.Error())
	}
	return info, nil
}

// notStarted reports a tool that could not be started at all (missing binary), as opposed to one that ran and failed.
func notStarted(err error) bool {
	var ee *oneshot.ExitError
	if errors.As(err, &ee) {
		return false
	}
	return errors.Is(err, exec.ErrNotFound) || errors.Is(err, fs.ErrNotExist) || errors.Is(err, fs.ErrPermission)
}

// diskPreflight refuses a run that cannot finish. The scratch directory needs about seconds * max(source rate, 48 kHz)
// * 4 bytes * (3 * channels + 2) with a fifth to spare (the source and the mix are kept at the source rate, the model's
// files at 48 kHz). The output directory needs what the target codec will write (outputBytes), not the input's size.
// When both are on one volume the needs add up.
func (j *job) diskPreflight(info *probeInfo, inSize int64) error {
	scratch := uint64(info.Seconds * float64(max(info.SampleRate, modelRate)) * 4 * float64(3*info.Channels+2) * 1.2)
	output := uint64(outputBytes(info, extOf(j.o.Out), info.HasVideo, inSize)*1.1) + 1<<20
	tFree, tID, err := statFS(j.o.TempDir)
	if err != nil {
		return newErr(CodeUnavailable, "the scratch directory cannot be inspected")
	}
	oFree, oID, err := statFS(filepath.Dir(j.o.Out))
	if err != nil {
		return newErr(CodeUnavailable, "the output directory cannot be inspected")
	}
	if tID == oID {
		if tFree < scratch+output {
			return newErr(CodeDiskSpace, "not enough free disk space to clean this file")
		}
		return nil
	}
	if tFree < scratch {
		return newErr(CodeDiskSpace, "not enough free disk space for the scratch files")
	}
	if oFree < output {
		return newErr(CodeDiskSpace, "not enough free disk space for the output")
	}
	return nil
}

func diskFree(path string) (uint64, string, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, "", err
	}
	return uint64(st.Bsize) * st.Bavail, fmt.Sprint(st.Fsid), nil
}

// ---- the pipeline ---------------------------------------------------------------------------------------------------

// source is a file as ffmpeg is given it: only the file protocol, so a crafted playlist cannot reach the network.
func source(path string) []string {
	return []string{"-protocol_whitelist", "file", "-i", "file:" + path}
}

var ffBase = []string{"-nostdin", "-v", "error", "-y"}

// ff runs ffmpeg with the common prefix; a failure becomes an engine_failed carrying the tail of its stderr.
func (j *job) ff(args ...string) error {
	_, err := j.o.Run(withTool(j.ctx, ToolFFmpeg), j.o.FFmpeg, append(append([]string(nil), ffBase...), args...))
	return j.toolErr("ffmpeg", err)
}

func (j *job) toolErr(tool string, err error) error {
	if err == nil {
		return nil
	}
	if cerr := j.ctx.Err(); cerr != nil {
		return cerr
	}
	if notStarted(err) {
		return newErr(CodeUnavailable, tool+" is not installed or cannot be started")
	}
	return newErr(CodeEngineFailed, tool+" failed: "+tailClip(err.Error(), stderrKeep))
}

func (j *job) tmp(name string) string { return filepath.Join(j.temp, name) }

func drop(paths ...string) {
	for _, p := range paths {
		_ = os.Remove(p)
	}
}

// model runs ox-clean (mono 48 kHz float WAV in, the same out) at nice 15, one process.
func (j *job) model(in, out string) (time.Duration, error) {
	bin, args := j.o.Engine, []string{in, out, "--models", j.o.ModelsDir}
	if _, err := os.Stat(niceBin); err == nil {
		bin, args = niceBin, append([]string{"-n", "15", j.o.Engine}, args...)
	}
	t0 := time.Now()
	_, err := j.o.Run(withTool(j.ctx, ToolEngine), bin, args)
	if err := j.toolErr("the cleanup engine", err); err != nil {
		return 0, err
	}
	if st, serr := os.Stat(out); serr != nil || st.Size() == 0 {
		return 0, newErr(CodeEngineFailed, "the cleanup engine wrote no output")
	}
	return time.Since(t0), nil
}

// mixdown extracts the first audio stream at the source rate (at most 48 kHz), cleans it through the model and blends
// it with the dry source at the source rate. It returns the mix file and the wall time spent in the model.
func (j *job) mixdown(info *probeInfo) (string, float64, error) {
	o := j.o
	mr := min(info.SampleRate, modelRate)
	src := j.tmp("src.wav")
	if err := j.ff(append(source(o.In), "-map", "0:"+strconv.Itoa(info.AudioIndex), "-ar", strconv.Itoa(mr), "-map_metadata", "-1", "-c:a", "pcm_f32le", src)...); err != nil {
		return "", 0, err
	}
	base := src // the source at 48 kHz, which is what the model and the add-back work on
	if mr != modelRate {
		base = j.tmp("src48.wav")
		if err := j.ff("-i", src, "-ar", strconv.Itoa(modelRate), "-c:a", "pcm_f32le", base); err != nil {
			return "", 0, err
		}
	}
	var modelTime time.Duration
	enh := j.tmp("enh.wav")
	switch {
	case info.Channels == 2 && o.Stereo == "mid":
		mid, midE := j.tmp("mid.wav"), j.tmp("mid_e.wav")
		if err := j.ff("-i", base, "-af", midPanFilter, "-c:a", "pcm_f32le", mid); err != nil {
			return "", 0, err
		}
		d, err := j.model(mid, midE)
		if err != nil {
			return "", 0, err
		}
		modelTime += d
		err = j.ff("-i", base, "-i", mid, "-i", midE, "-filter_complex", MidMergeFilter(), "-map", "[o]", "-c:a", "pcm_f32le", enh)
		drop(mid, midE)
		if err != nil {
			return "", 0, err
		}
	case info.Channels == 2:
		var cleaned [2]string
		for i, pan := range []string{leftFilter, rightFilter} {
			ch, chE := j.tmp(fmt.Sprintf("ch%d.wav", i)), j.tmp(fmt.Sprintf("ch%d_e.wav", i))
			if err := j.ff("-i", base, "-af", pan, "-c:a", "pcm_f32le", ch); err != nil {
				return "", 0, err
			}
			d, err := j.model(ch, chE)
			drop(ch)
			if err != nil {
				return "", 0, err
			}
			modelTime += d
			cleaned[i] = chE
		}
		err := j.ff("-i", cleaned[0], "-i", cleaned[1], "-filter_complex", channelsMergeFilter(), "-map", "[o]", "-c:a", "pcm_f32le", enh)
		drop(cleaned[0], cleaned[1])
		if err != nil {
			return "", 0, err
		}
	default:
		d, err := j.model(base, enh)
		if err != nil {
			return "", 0, err
		}
		modelTime += d
	}
	if base != src {
		drop(base)
	}
	mix := j.tmp("mix.wav")
	err := j.ff("-i", src, "-i", enh, "-filter_complex", MixFilter(info.SampleRate, o.Wet), "-map", "[m]", "-map_metadata", "-1", "-c:a", "pcm_f32le", mix)
	drop(src, enh)
	if err != nil {
		return "", 0, err
	}
	return mix, modelTime.Seconds(), nil
}

// ---- writing the output -----------------------------------------------------------------------------------------------

// write muxes the mix into a part file beside Out and puts it in place.
func (j *job) write(info *probeInfo, inSt os.FileInfo, mix string) error {
	o := j.o
	if err := j.ctx.Err(); err != nil {
		return err
	}
	part, mode, err := j.createPart(inSt)
	if err != nil {
		return err
	}
	j.part = part
	var args []string
	var videoArgs func(offset float64) []string // the video mux for a given audio offset (the lag check re-runs it)
	if info.HasVideo {
		format, audio := videoMux(extOf(o.Out))
		videoArgs = func(offset float64) []string {
			a := append(source(o.In), "-itsoffset", strconv.FormatFloat(offset, 'f', 6, 64), "-i", mix)
			// every input stream keeps its place; only the first audio stream is replaced by the cleaned mix (input 1)
			a = append(a, j.plan.maps...)
			// every carried stream, the replaced audio one included, keeps its own metadata (language, handler name)
			a = append(a, "-map_metadata", "0", "-map_chapters", "0")
			a = append(a, j.plan.meta...)
			a = append(a, "-c", "copy", "-copy_unknown")
			a = append(a, audio...)
			a = append(a, j.plan.codecs...)
			a = append(a, "-ac:a:0", strconv.Itoa(info.Channels), "-f", format)
			if format == "mp4" || format == "mov" {
				a = append(a, "-movflags", "+faststart")
			}
			return append(a, part)
		}
		args = videoArgs(audioOffset(info, extOf(o.Out)) + o.offsetSkew)
	} else {
		enc, _ := audioMuxArgs(extOf(o.Out))
		// input 1 is the source again, for its tags and cover art; the audio is the cleaned mix (input 0)
		args = append(append([]string{"-i", mix}, source(o.In)...), "-map", "0:a:0", "-map_metadata", "1")
		if coverExts[extOf(o.Out)] {
			args = append(args, "-map", "1:v?", "-c:v", "copy", "-disposition:v", "attached_pic")
		}
		args = append(args, enc...)
		args = append(args, part)
	}
	if err := j.ff(args...); err != nil {
		return err
	}
	if videoArgs != nil {
		lag, err := j.correctLag(info, part, audioOffset(info, extOf(o.Out))+o.offsetSkew, videoArgs)
		if err != nil {
			return err
		}
		j.lagMs = lag
	}
	if err := flush(part, mode); err != nil {
		return newErr(CodeEngineFailed, "the cleaned file could not be flushed to disk")
	}
	if err := j.ctx.Err(); err != nil {
		return err
	}
	return j.publish()
}

// createPart reserves the part file's name: created exclusively, so a file already there (ours from another run, or
// anyone's) is never opened, truncated or removed. It returns the file's mode ceiling: the input's permissions, so a
// private recording does not come back world-readable.
func (j *job) createPart(inSt os.FileInfo) (string, os.FileMode, error) {
	dir := filepath.Dir(j.o.Out)
	for range 8 {
		name := filepath.Join(dir, fmt.Sprintf(".voice-clean.%d.%s.part", os.Getpid(), partSuffix()))
		f, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o666) // the umask applies
		if errors.Is(err, fs.ErrExist) {
			continue
		}
		if err != nil {
			return "", 0, newErr(CodeUnavailable, "cannot create the output file in that directory")
		}
		_ = f.Close()
		return name, inSt.Mode().Perm() & 0o666, nil
	}
	return "", 0, newErr(CodeUnavailable, "cannot find a free temporary name in the output directory")
}

// flush syncs the finished part file and narrows its permissions to the input's.
func flush(part string, ceiling os.FileMode) error {
	st, err := os.Stat(part)
	if err != nil || st.Size() == 0 {
		return errors.New("empty output")
	}
	if err := os.Chmod(part, st.Mode().Perm()&ceiling); err != nil {
		return err
	}
	f, err := os.OpenFile(part, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}

// publish moves the finished part file onto Out. With Overwrite it is a rename (atomic, replaces a file or a link
// itself, never what the link points to). Without it a hard link is made first, which fails if Out appeared since the
// check, so a concurrent run's output is never replaced; on a volume without hard links it falls back to an atomic
// no-replace rename (renamex_np RENAME_EXCL on macOS, renameat2 RENAME_NOREPLACE on Linux).
func (j *job) publish() error {
	o := j.o
	if o.Overwrite {
		return j.moved(os.Rename(j.part, o.Out))
	}
	err := linkFile(j.part, o.Out)
	switch {
	case err == nil:
		_ = os.Remove(j.part)
		j.part = ""
		return nil
	case errors.Is(err, fs.ErrExist):
		return newErr(CodeExists, "the output file already exists")
	}
	// no hard links on this volume: an atomic rename that fails if Out exists, so nothing created since the check
	// is replaced. (exFAT and some SMB shares may lack RENAME_EXCL/NOREPLACE too; then the checked-rename window
	// below remains. Documented, not fixed.)
	if _, serr := os.Lstat(o.Out); serr == nil {
		return newErr(CodeExists, "the output file already exists")
	}
	afterPublishCheck()
	rerr, unsupported := renameNoReplace(j.part, o.Out)
	if unsupported { // a filesystem without an atomic form: a re-check and a plain rename, the best left
		if _, serr := os.Lstat(o.Out); serr == nil {
			return newErr(CodeExists, "the output file already exists")
		}
		rerr = os.Rename(j.part, o.Out)
	}
	if errors.Is(rerr, fs.ErrExist) {
		return newErr(CodeExists, "the output file already exists")
	}
	return j.moved(rerr)
}

func (j *job) moved(err error) error {
	if err != nil {
		return newErr(CodeEngineFailed, "the cleaned file could not be moved into place")
	}
	j.part = "" // the rename consumed it
	return nil
}

func randomHex() string {
	var b [6]byte
	if _, err := rand.Read(b[:]); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return hex.EncodeToString(b[:])
}

// lagTolerance is how far the output's audio-to-picture lag may sit from the input's before the mux is corrected, and
// the most it may sit from it for the file to be published. lagCeiling is the largest correction trusted: a bigger gap
// means the probe is not telling us what we think. lagEpsilon absorbs float rounding in the comparison (start times
// are microsecond decimals, so a gap of exactly 1 ms can read 1.0000000000003 ms and must not count as over).
const (
	lagTolerance = 0.001
	lagCeiling   = 2.0
	lagEpsilon   = 1e-9
)

func lagWithin(delta float64) bool { return math.Abs(delta) <= lagTolerance+lagEpsilon }

// lagGap probes the part file and returns input lag minus output lag in seconds. A file that cannot be probed, or
// shows no picture, has an unknown lag, which is a refusal, not a pass.
func (j *job) lagGap(info *probeInfo, part string) (float64, error) {
	raw, err := j.o.Run(withTool(j.ctx, ToolProbe), j.o.FFprobe, probeArgs(part))
	if err != nil {
		if cerr := j.ctx.Err(); cerr != nil {
			return 0, cerr
		}
		return 0, newErr(CodeLagUnverified, "the cleaned file's audio/picture sync could not be checked, so it was not saved")
	}
	out, err := parseProbe(raw)
	if err != nil || !out.HasVideo {
		return 0, newErr(CodeLagUnverified, "the cleaned file's audio/picture sync could not be checked, so it was not saved")
	}
	return (info.AudioStart - info.VideoStart) - (out.AudioStart - out.VideoStart), nil
}

// correctLag measures what the muxer actually produced and refuses to publish a file whose lag it cannot prove. How far
// an AAC or Opus track lands from where it was asked to start depends on the encoder's priming, the container and the
// ffmpeg version (measured: ffmpeg 9.0.2 puts mkv exact and mp4 one frame early; 6.1 puts mkv one frame early and webm
// 6 ms), so no table by container name is reliable. The output's audio and picture start times are read back with
// ffprobe; if their lag differs from the input's by more than lagTolerance the mux is run once more with the offset
// moved by the difference, and measured again. One correction, no loop. It returns the verified output-minus-input
// lag in ms, or lag_unverified when the gap is over the ceiling, the correction did not land, or the output cannot be
// probed.
func (j *job) correctLag(info *probeInfo, part string, offset float64, build func(float64) []string) (float64, error) {
	delta, err := j.lagGap(info, part)
	if err != nil {
		return 0, err
	}
	if math.Abs(delta) > lagCeiling {
		return 0, newErr(CodeLagUnverified, fmt.Sprintf("the cleaned file's audio is %.1f s out of sync with its picture, so it was not saved", math.Abs(delta)))
	}
	if !lagWithin(delta) {
		if err := j.ff(build(offset + delta)...); err != nil {
			return 0, err
		}
		if delta, err = j.lagGap(info, part); err != nil {
			return 0, err
		}
		if !lagWithin(delta) {
			return 0, newErr(CodeLagUnverified, fmt.Sprintf("the cleaned file's audio stayed %.0f ms out of sync with its picture after a correction, so it was not saved", math.Abs(delta)*1000))
		}
	}
	return -delta * 1000, nil
}
