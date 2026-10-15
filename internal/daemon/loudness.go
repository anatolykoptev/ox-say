package daemon

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Why not ffmpeg's loudnorm: even its second pass, given the measured values
// and linear=true, silently switches to a dynamic mode when the gain needed
// would push the true peak past the ceiling (issue #153), and on a 2-3 s take
// its own reading is off (issue #162). Loudness is instead set by a chain whose
// behaviour is predictable: measure the integrated loudness with the EBU R128
// meter, apply one constant gain, and hold the true peak with an oversampled
// limiter. The result is measured again with the same meter and, when it landed
// off target, corrected - so the file is judged by the oracle that grades it.

// Loudness settings. The ceiling is the true-peak limit for voiceover.
const (
	loudnessCeilingDB = -1.5 // dBTP
	// absoluteGateLUFS is the EBU R128 absolute gate: a programme with no block
	// above it has no integrated loudness (silence reads exactly this).
	absoluteGateLUFS = -70.0
	// gatingBlockSec is one EBU R128 gating block. A clip shorter than that has
	// no block to measure, so it is measured on a looped copy.
	gatingBlockSec = 0.4
	// tiledClipSec is how long a looped copy of a sub-block clip is.
	tiledClipSec = 2 * gatingBlockSec
	// loudnessToleranceLU is how far off target a result may land before it is
	// corrected; loudnessRefinements bounds the corrections.
	loudnessToleranceLU = 0.3
	loudnessRefinements = 4
	// missedTargetLU is how far under the target a result may land before the
	// take carries a warning (the peaks, not the gain, were the limit).
	missedTargetLU = 0.5
	// limitNoteDB is how far the limiter may pull the loudest peak down before
	// the take carries a note: beyond it speech can sound slightly squashed.
	limitNoteDB = 6.0
	// limiterOversample times the sample rate is the rate the limiter runs at,
	// so inter-sample peaks are seen (BS.1770 true-peak metering uses 4x).
	limiterOversample = 4
	limiterAttackMs   = 5
	limiterReleaseMs  = 50
	tpFloorDB         = -200.0 // true peak of digital silence
	// maxGainDB is the most a take may be raised. The real takes in the
	// evidence corpus needed at most 15.8 dB (assembled reels at -14 LUFS from
	// -29.8); 25 dB leaves room for quiet clones yet refuses a hiss-only take
	// (-62 LUFS needs +46 dB), whose noise would become the signal.
	maxGainDB = 25.0
)

// loudnormWaitDelay bounds how long Run waits for ffmpeg's pipes after the
// process was killed.
const loudnormWaitDelay = 2 * time.Second

// loudnormTimeout bounds one normalisation: ffmpeg runs far faster than real
// time, so this only fires on a hung process. A var so a test can shorten it.
var loudnormTimeout = 10 * time.Minute

// errUnmeasurable marks a take with no measurable loudness (silence).
var errUnmeasurable = errors.New("loudness: the audio is silent or too short to measure")

// errTooQuiet marks a take that would need more than maxGainDB.
var errTooQuiet = errors.New("loudness: the audio is too quiet to raise to the target")

// level is a take's EBU R128 reading.
type level struct {
	lufs float64 // integrated loudness
	tpDB float64 // true peak, dBTP
}

// levelOutcome is what levelling a take achieved.
type levelOutcome struct {
	lufs      float64 // measured loudness of the result
	limitedDB float64 // how far the limiter pulled the loudest peak down
	target    float64
}

// shortBy is how far under the target the result landed (0 when on or above).
func (o levelOutcome) shortBy() float64 { return math.Max(0, o.target-o.lufs) }

// limited reports that the take needed more than a light touch from the
// limiter, or could not reach the target under the ceiling.
func (o levelOutcome) limited() bool {
	return o.limitedDB > limitNoteDB || o.shortBy() > missedTargetLU
}

// note is the plain-words account of a limited take (empty when it is not).
func (o levelOutcome) note() string {
	switch {
	case o.shortBy() > missedTargetLU:
		return fmt.Sprintf("loudness landed %.1f LU under the target: the speech is too peaky to be louder without passing the %.1f dBTP peak ceiling", o.shortBy(), loudnessCeilingDB)
	case o.limitedDB > limitNoteDB:
		return fmt.Sprintf("loudness was reached with a peak limiter that pulled the loudest peaks down by %.0f dB, so very peaky speech may sound slightly squashed", o.limitedDB)
	}
	return ""
}

// ebu128Filter prints the running readings of the EBU R128 meter as metadata.
const ebu128Filter = "ebur128=peak=true:metadata=1,ametadata=mode=print:file=-"

// measureFilter is the metering filter for a clip of secs seconds at rate: a
// clip shorter than one gating block is looped up to tiledClipSec first.
func measureFilter(secs float64, rate int) string {
	if secs >= gatingBlockSec {
		return ebu128Filter
	}
	copies := int(math.Ceil(tiledClipSec / secs))
	size := int(math.Ceil(secs*float64(rate))) + 1
	return fmt.Sprintf("aloop=loop=%d:size=%d,%s", copies-1, size, ebu128Filter)
}

// measureLevel reads src's integrated loudness and true peak. Silence (no
// block above the absolute gate) is errUnmeasurable.
func measureLevel(ctx context.Context, src loudnormSource, secs float64, rate int) (level, error) {
	args := append([]string{"-hide_banner", "-nostats", "-loglevel", "error"}, src.args()...)
	args = append(args, "-af", measureFilter(secs, rate), "-f", "null", "-")
	cmd := exec.CommandContext(ctx, "ffmpeg", args...)
	cmd.Stdin = src.stdin()
	cmd.WaitDelay = loudnormWaitDelay
	var errb bytes.Buffer
	cmd.Stderr = &errb
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return level{}, err
	}
	if err := cmd.Start(); err != nil {
		return level{}, fmt.Errorf("ffmpeg ebur128: %w", err)
	}
	lvl, found := scanLevel(stdout)
	if err := cmd.Wait(); err != nil {
		return level{}, fmt.Errorf("ffmpeg ebur128: %w: %s", err, strings.TrimSpace(errb.String()))
	}
	if !found {
		return level{}, fmt.Errorf("ffmpeg ebur128: no loudness and true-peak reading in its output")
	}
	if lvl.lufs <= absoluteGateLUFS {
		return level{}, errUnmeasurable
	}
	return lvl, nil
}

// scanLevel reads the meter's metadata lines: the last integrated loudness
// (it is cumulative) and the highest true peak seen, from the combined key or
// the per-channel ones. found is true only when both were read: a build whose
// meter prints no true peak must not pass for a measured take. NaN readings
// are ignored.
func scanLevel(r io.Reader) (lvl level, found bool) {
	lvl.tpDB = tpFloorDB
	sawLUFS, sawTP := false, false
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		key, val, ok := strings.Cut(sc.Text(), "=")
		if !ok {
			continue
		}
		f, err := strconv.ParseFloat(val, 64)
		if err != nil || math.IsNaN(f) {
			continue
		}
		switch {
		case key == "lavfi.r128.I":
			lvl.lufs, sawLUFS = f, true
		case key == "lavfi.r128.true_peak" || strings.HasPrefix(key, "lavfi.r128.true_peaks_ch"):
			sawTP = true
			if f > 0 {
				lvl.tpDB = math.Max(lvl.tpDB, 20*math.Log10(f))
			}
		}
	}
	return lvl, sawLUFS && sawTP
}

// levelFilter is the ffmpeg chain for one constant gain: volume, and when the
// peaks would pass the ceiling, an oversampled look-ahead limiter at it. The
// limiter's own auto-level and delay are off/compensated so only the peaks
// move and the length is kept.
func levelFilter(gainDB float64, limit bool, rate int) string {
	f := fmt.Sprintf("volume=%.4fdB", gainDB)
	if !limit {
		return f
	}
	ceiling := math.Pow(10, loudnessCeilingDB/20)
	return fmt.Sprintf("%s,aresample=%d,alimiter=limit=%.5f:attack=%d:release=%d:level=false:latency=true,aresample=%d",
		f, rate*limiterOversample, ceiling, limiterAttackMs, limiterReleaseMs, rate)
}

// renderLevel applies filter to src into out at rate and checks the result:
// ffmpeg can exit 0 and leave nothing, or leave the wrong rate, and neither may
// pass for a levelled file.
func renderLevel(ctx context.Context, src loudnormSource, out string, rate int, filter string) error {
	args := append([]string{"-hide_banner", "-nostats", "-loglevel", "error", "-y"}, src.args()...)
	args = append(args, "-af", filter, "-ar", strconv.Itoa(rate), "-c:a", "pcm_s16le", "-f", "wav", out)
	cmd := exec.CommandContext(ctx, "ffmpeg", args...)
	cmd.Stdin = src.stdin()
	cmd.WaitDelay = loudnormWaitDelay
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ffmpeg level: %w: %s", err, strings.TrimSpace(errb.String()))
	}
	if gotRate, secs := wavInfoFile(out); gotRate != rate || secs <= 0 {
		return fmt.Errorf("loudness: ffmpeg produced %d Hz / %.2f s, want %d Hz of audio", gotRate, secs, rate)
	}
	return nil
}

// trySuffix names the scratch file of one levelling attempt beside its output.
const trySuffix = ".try"

// levelTo sets src (rate Hz, secs long) to lufs integrated loudness in out,
// keeping the rate: measure, one constant gain, and an oversampled limiter at
// the true-peak ceiling when the peaks need it. Limiting costs a little
// loudness on peaky speech, so the result is measured and the gain corrected up
// to loudnessRefinements times; the attempt nearest the target wins. A silent
// take is errUnmeasurable and out is left absent.
func levelTo(ctx context.Context, src loudnormSource, secs float64, rate int, out string, lufs float64) (levelOutcome, error) {
	in, err := measureLevel(ctx, src, secs, rate)
	if err != nil {
		return levelOutcome{}, err
	}
	if lufs-in.lufs > maxGainDB {
		return levelOutcome{}, fmt.Errorf("%w: it would need +%.0f dB, the limit is +%.0f dB", errTooQuiet, lufs-in.lufs, maxGainDB)
	}
	try := out + trySuffix
	defer func() { _ = os.Remove(try) }()
	var best levelOutcome
	haveBest := false
	gain := lufs - in.lufs
	for pass := 0; pass <= loudnessRefinements; pass++ {
		limit := in.tpDB+gain > loudnessCeilingDB
		if err := renderLevel(ctx, src, try, rate, levelFilter(gain, limit, rate)); err != nil {
			return levelOutcome{}, err
		}
		outRate, outSecs := wavInfoFile(try)
		got, err := measureLevel(ctx, loudnormSource{path: try}, outSecs, outRate)
		if err != nil {
			return levelOutcome{}, err
		}
		o := levelOutcome{lufs: got.lufs, target: lufs}
		if limit {
			o.limitedDB = math.Max(0, in.tpDB+gain-got.tpDB)
		}
		if !haveBest || math.Abs(o.lufs-lufs) < math.Abs(best.lufs-lufs) {
			if err := os.Rename(try, out); err != nil {
				return levelOutcome{}, err
			}
			best, haveBest = o, true
		}
		if math.Abs(best.lufs-lufs) <= loudnessToleranceLU {
			break
		}
		gain += lufs - got.lufs
	}
	return best, nil
}

// loudnorm normalises wav to lufs integrated loudness, keeping its sample
// rate (see levelTo). note is the plain-words account of a take that needed
// the limiter hard or could not reach the target (empty otherwise). The result
// goes through a temp file in dir: a WAV written to a pipe carries no sizes in
// its header. The long-form producer calls the file variant, loudnormFile.
func loudnorm(ctx context.Context, dir string, wav []byte, lufs float64) (out []byte, note string, err error) {
	rate, secs := wavInfo(wav)
	if rate <= 0 || secs <= 0 {
		return nil, "", fmt.Errorf("loudnorm: not a PCM WAV")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, "", err
	}
	f, err := os.CreateTemp(dir, ".loudnorm-*.wav")
	if err != nil {
		return nil, "", err
	}
	path := f.Name()
	_ = f.Close()
	defer func() { _ = os.Remove(path) }()
	o, err := levelTo(ctx, loudnormSource{wav: wav}, secs, rate, path, lufs)
	if err != nil {
		return nil, "", err
	}
	out, err = os.ReadFile(path)
	return out, o.note(), err
}

// Bounds of one long-file normalisation: ffmpeg runs far faster than real
// time; the slack covers a loaded machine. The passes are the first reading
// plus a render and a reading for each attempt.
const (
	wavHeadProbe       = 64 << 10
	loudnormFileBase   = 30 * time.Second
	loudnormFilePerSec = 0.25
	loudnormPasses     = 1 + 2*(1+loudnessRefinements)
)

// loudnormFileTimeout bounds every pass of loudnormFile for durSec of audio.
func loudnormFileTimeout(durSec float64) time.Duration {
	return loudnormPasses * (loudnormFileBase + time.Duration(durSec*loudnormFilePerSec*float64(time.Second)))
}

// loudnormFile is loudnormFileReport without the report.
func loudnormFile(ctx context.Context, in, out string, lufs float64) error {
	_, err := loudnormFileReport(ctx, in, out, lufs)
	return err
}

// loudnormFileReport is the producer's STRICT normalisation of the file in into
// the file out, at in's sample rate (see levelTo). Unlike loudnorm it never
// keeps the input: any failure, including a take that reads silence, is
// returned, and out is left absent, so an unnormalised file can never pass for
// the result. limited reports that the limiter pulled the loudest peaks down by
// more than limitNoteDB, or that the target was missed under the ceiling.
func loudnormFileReport(ctx context.Context, in, out string, lufs float64) (limited bool, err error) {
	if in == out {
		return false, fmt.Errorf("loudnorm: the output must be a different file from the input")
	}
	rate, secs := wavInfoFile(in)
	if rate <= 0 || secs <= 0 {
		return false, fmt.Errorf("loudnorm: the assembled file is not a PCM WAV")
	}
	defer func() {
		if err != nil {
			_ = os.Remove(out)
		}
	}()
	o, err := levelTo(ctx, loudnormSource{path: in}, secs, rate, out, lufs)
	return o.limited(), err
}
