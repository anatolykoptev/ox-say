package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// fieldLoudness is ox-say's own request field: never forwarded to an engine.
const fieldLoudness = "loudness_lufs"

// EBU R128 bounds for a requested target, and loudnorm's true-peak / range
// settings for voiceover.
const (
	minLUFS     = -40.0
	maxLUFS     = -5.0
	loudnormTP  = -1.5
	loudnormLRA = 11
)

// loudnormWaitDelay bounds how long Run waits for ffmpeg's pipes after the
// process was killed.
const loudnormWaitDelay = 2 * time.Second

// loudnormTimeout bounds one normalisation: ffmpeg runs far faster than real
// time, so this only fires on a hung process. A var so a test can shorten it.
var loudnormTimeout = 10 * time.Minute

// Plain-words reasons a take kept its original level.
const (
	warnNoFFmpeg     = "loudness was not normalised: ffmpeg is not installed, so the take keeps its original level"
	warnFFmpegFailed = "loudness was not normalised: ffmpeg could not process the audio, so the take keeps its original level"
	warnSinglePass   = "loudness was normalised in a single pass because the measuring pass failed, so it may be a little off the target"
	warnFFmpegSlow   = "loudness was not normalised: ffmpeg took too long, so the take keeps its original level"
)

// lufsError is the caller's mistake in plain words.
func lufsError() error {
	return &requestError{fmt.Sprintf("%s must be a number in %.0f..%.0f (-16 online video and podcasts, -14 music streaming, -23 EBU broadcast)", fieldLoudness, minLUFS, maxLUFS)}
}

// validLUFS checks a requested integrated-loudness target.
func validLUFS(v float64) error {
	if math.IsNaN(v) || v < minLUFS || v > maxLUFS {
		return lufsError()
	}
	return nil
}

// loudnessTarget pops loudness_lufs (ox-say's own field, never an engine's)
// and validates it; nil = no normalisation. An explicit null counts as absent.
func loudnessTarget(body map[string]any) (*float64, error) {
	raw, ok := body[fieldLoudness]
	if !ok {
		return nil, nil
	}
	delete(body, fieldLoudness)
	if raw == nil {
		return nil, nil
	}
	v, ok := number(raw)
	if !ok {
		return nil, lufsError()
	}
	if err := validLUFS(v); err != nil {
		return nil, err
	}
	return &v, nil
}

// loudnormStats are the measuring pass's readings of the take.
type loudnormStats struct {
	InputI      string `json:"input_i"`
	InputTP     string `json:"input_tp"`
	InputLRA    string `json:"input_lra"`
	InputThresh string `json:"input_thresh"`
	Offset      string `json:"target_offset"`
}

// measuredArgs renders the stats as loudnorm's measured_* options, or an error
// when a reading is missing or not finite (silence measures -inf).
func (m loudnormStats) measuredArgs() (string, error) {
	var v [5]float64
	for i, raw := range []string{m.InputI, m.InputTP, m.InputLRA, m.InputThresh, m.Offset} {
		f, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
		if err != nil || math.IsInf(f, 0) || math.IsNaN(f) {
			return "", fmt.Errorf("loudnorm: unusable measurement %q", raw)
		}
		v[i] = f
	}
	return fmt.Sprintf("measured_I=%.2f:measured_TP=%.2f:measured_LRA=%.2f:measured_thresh=%.2f:offset=%.2f:linear=true",
		v[0], v[1], v[2], v[3], v[4]), nil
}

// loudnormFilter is the filter for a target; measured (nil = single pass)
// switches it to loudnorm's two-pass mode with linear=true. "Linear" is a
// request: when the measured peak plus the gain needed would pass the
// true-peak ceiling, or the measured range exceeds LRA, ffmpeg runs the
// dynamic mode anyway and reports normalization_type "dynamic".
func loudnormFilter(lufs float64, measured *loudnormStats) (string, error) {
	f := fmt.Sprintf("loudnorm=I=%g:TP=%g:LRA=%d", lufs, loudnormTP, loudnormLRA)
	if measured == nil {
		return f, nil
	}
	args, err := measured.measuredArgs()
	if err != nil {
		return "", err
	}
	return f + ":" + args, nil
}

// loudnormSource is an ffmpeg input: a WAV in memory (piped) or a file on
// disk (the producer's assembled voiceover, which may be hundreds of MB).
type loudnormSource struct {
	wav  []byte // non-nil: piped through stdin
	path string
}

func (s loudnormSource) args() []string {
	if s.wav != nil {
		return []string{"-f", "wav", "-i", "pipe:0"}
	}
	return []string{"-i", s.path}
}

func (s loudnormSource) stdin() io.Reader {
	if s.wav != nil {
		return bytes.NewReader(s.wav)
	}
	return nil
}

// measureLoudness is loudnorm's first pass over one take held in memory.
func measureLoudness(ctx context.Context, wav []byte, lufs float64) (*loudnormStats, error) {
	return measureLoudnessFrom(ctx, loudnormSource{wav: wav}, lufs)
}

// measureLoudnessFrom reads src and reports its integrated loudness, true
// peak, range and gate threshold as JSON on stderr. A reading that is missing
// or not finite (silence measures -inf) is an error.
func measureLoudnessFrom(ctx context.Context, src loudnormSource, lufs float64) (*loudnormStats, error) {
	args := append([]string{"-hide_banner", "-nostats"}, src.args()...)
	args = append(args, "-af", fmt.Sprintf("loudnorm=I=%g:TP=%g:LRA=%d:print_format=json", lufs, loudnormTP, loudnormLRA),
		"-f", "null", "-")
	cmd := exec.CommandContext(ctx, "ffmpeg", args...)
	cmd.Stdin = src.stdin()
	cmd.WaitDelay = loudnormWaitDelay
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("ffmpeg loudnorm measure: %w: %s", err, strings.TrimSpace(errb.String()))
	}
	txt := errb.String()
	start, end := strings.LastIndex(txt, "{"), strings.LastIndex(txt, "}")
	var st loudnormStats
	if start < 0 || end < start || json.Unmarshal([]byte(txt[start:end+1]), &st) != nil {
		return nil, fmt.Errorf("ffmpeg loudnorm measure: no JSON report in its output")
	}
	if _, err := st.measuredArgs(); err != nil {
		return nil, err
	}
	return &st, nil
}

// loudnorm normalises wav to lufs integrated loudness in two passes (measure,
// then a linear gain from the measurement), keeping its sample rate: the
// filter resamples to 192 kHz internally, so the rate is forced back and the
// result is checked. If the measuring pass fails the take is normalised in a
// single pass and note says so (empty otherwise).
//
// Peak-limited takes land below the target by design: when the take's
// peak-to-loudness ratio exceeds TP minus the target (14.5 dB for -16 LUFS),
// the true-peak ceiling wins over the loudness target. ffmpeg writes to a temp
// file in dir: a WAV written to a pipe carries no sizes in its header. The
// long-form producer calls this (via normalizeLoudness) once on the assembled
// file.
func loudnorm(ctx context.Context, dir string, wav []byte, lufs float64) (out []byte, note string, err error) {
	rate, _ := wavInfo(wav)
	if rate <= 0 {
		return nil, "", fmt.Errorf("loudnorm: not a PCM WAV")
	}
	st, merr := measureLoudness(ctx, wav, lufs)
	if merr != nil && ctx.Err() != nil {
		return nil, "", merr
	}
	filter, ferr := loudnormFilter(lufs, st)
	if ferr != nil {
		return nil, "", ferr
	}
	if merr != nil {
		note = warnSinglePass
	}
	out, err = runLoudnorm(ctx, dir, wav, rate, filter)
	if err != nil {
		return nil, "", err
	}
	return out, note, nil
}

// runLoudnorm applies filter to wav and returns the checked result at rate.
func runLoudnorm(ctx context.Context, dir string, wav []byte, rate int, filter string) ([]byte, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	f, err := os.CreateTemp(dir, ".loudnorm-*.wav")
	if err != nil {
		return nil, err
	}
	out := f.Name()
	_ = f.Close()
	defer func() { _ = os.Remove(out) }()
	if err := applyLoudnorm(ctx, loudnormSource{wav: wav}, out, rate, filter); err != nil {
		return nil, err
	}
	return os.ReadFile(out)
}

// applyLoudnorm runs filter over src into the file out at rate and checks the
// result: ffmpeg can exit 0 and leave nothing, or leave the wrong rate, and
// neither may pass for a normalised file.
func applyLoudnorm(ctx context.Context, src loudnormSource, out string, rate int, filter string) error {
	_, err := applyLoudnormReport(ctx, src, out, rate, filter, false)
	return err
}

// normTypeDynamic is the normalization_type ffmpeg reports when it could not
// keep the gain constant.
const normTypeDynamic = "dynamic"

// applyLoudnormReport is applyLoudnorm that can also ask ffmpeg for its own
// report and return the normalization_type it ran ("linear", "dynamic"; empty
// when not asked or the report is unreadable).
func applyLoudnormReport(ctx context.Context, src loudnormSource, out string, rate int, filter string, report bool) (normType string, err error) {
	level := "error"
	if report {
		level, filter = "info", filter+":print_format=json" // the JSON is an info-level message
	}
	args := append([]string{"-hide_banner", "-nostats", "-loglevel", level, "-y"}, src.args()...)
	args = append(args, "-af", filter, "-ar", strconv.Itoa(rate), "-c:a", "pcm_s16le", out)
	cmd := exec.CommandContext(ctx, "ffmpeg", args...)
	cmd.Stdin = src.stdin()
	cmd.WaitDelay = loudnormWaitDelay
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("ffmpeg loudnorm: %w: %s", err, strings.TrimSpace(errb.String()))
	}
	if gotRate, secs := wavInfoFile(out); gotRate != rate || secs <= 0 {
		return "", fmt.Errorf("loudnorm: ffmpeg produced %d Hz / %.2f s, want %d Hz of audio", gotRate, secs, rate)
	}
	if report {
		normType = reportedNormType(errb.String())
	}
	return normType, nil
}

// reportedNormType reads normalization_type from loudnorm's JSON report.
func reportedNormType(stderr string) string {
	start, end := strings.LastIndex(stderr, "{"), strings.LastIndex(stderr, "}")
	var rep struct {
		Type string `json:"normalization_type"`
	}
	if start < 0 || end < start || json.Unmarshal([]byte(stderr[start:end+1]), &rep) != nil {
		return ""
	}
	return rep.Type
}

// Bounds of one long-file normalisation: ffmpeg's loudnorm runs far faster
// than real time; the slack covers a loaded machine. Two passes.
const (
	wavHeadProbe       = 64 << 10
	loudnormFileBase   = 30 * time.Second
	loudnormFilePerSec = 0.25
	loudnormPasses     = 2
)

// loudnormFileTimeout bounds both passes of loudnormFile for durSec of audio.
func loudnormFileTimeout(durSec float64) time.Duration {
	return loudnormPasses * (loudnormFileBase + time.Duration(durSec*loudnormFilePerSec*float64(time.Second)))
}

// loudnormFile is loudnormFileReport without the report.
func loudnormFile(ctx context.Context, in, out string, lufs float64) error {
	_, err := loudnormFileReport(ctx, in, out, lufs)
	return err
}

// loudnormFileReport is the producer's STRICT two-pass normalisation of the
// file in into the file out, at in's sample rate: measure, then a gain from
// the measurement (linear=true). Unlike loudnorm it never falls back to a
// single pass and the producer never calls normalizeLoudness's soft fallback:
// any failure, including a measuring pass that reads silence, is returned, and
// out is left absent, so an unnormalised file can never pass for the result.
//
// The gain is constant only when loudnorm can keep it so. A programme whose
// peak would pass the true-peak ceiling at the needed gain (hot TTS at -14
// LUFS), or whose range exceeds LRA, is normalised in loudnorm's dynamic mode
// whatever linear=true asks (issue #153). dynamic reports that, from ffmpeg's
// own normalization_type.
func loudnormFileReport(ctx context.Context, in, out string, lufs float64) (dynamic bool, err error) {
	if in == out {
		return false, fmt.Errorf("loudnorm: the output must be a different file from the input")
	}
	rate, _ := wavInfoFile(in)
	if rate <= 0 {
		return false, fmt.Errorf("loudnorm: the assembled file is not a PCM WAV")
	}
	defer func() {
		if err != nil {
			_ = os.Remove(out)
		}
	}()
	src := loudnormSource{path: in}
	st, err := measureLoudnessFrom(ctx, src, lufs)
	if err != nil {
		return false, err
	}
	filter, err := loudnormFilter(lufs, st)
	if err != nil {
		return false, err
	}
	normType, err := applyLoudnormReport(ctx, src, out, rate, filter, true)
	return normType == normTypeDynamic, err
}

// wavInfoFile is wavInfo over a file's first 64 KiB: wavInfo reads the sizes
// from the header, which pcm.Writer patches on Close and ffmpeg writes.
func wavInfoFile(path string) (int, float64) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0
	}
	defer func() { _ = f.Close() }()
	head := make([]byte, wavHeadProbe)
	n, _ := io.ReadFull(f, head)
	return wavInfo(head[:n])
}

// normalizeLoudness is loudnorm that cannot lose the take: when ffmpeg is
// missing or fails, it returns wav untouched with a plain-words warning and
// logs the cause. Apply it to a finished take or to an assembled file, never
// inside synthesize.
func (d *Daemon) normalizeLoudness(ctx context.Context, wav []byte, lufs float64) (out []byte, warning string) {
	ctx, cancel := context.WithTimeout(ctx, loudnormTimeout)
	defer cancel()
	out, note, err := loudnorm(ctx, d.Cfg.CacheDir, wav, lufs)
	if err == nil {
		if note != "" {
			d.log.Warn("loudness measuring pass failed; normalised in a single pass", slog.Float64("target_lufs", lufs))
		}
		return out, note
	}
	d.log.Warn("loudness normalisation failed; keeping the take as rendered",
		slog.Float64("target_lufs", lufs), slog.Any("error", err))
	switch {
	case errors.Is(err, exec.ErrNotFound):
		return wav, warnNoFFmpeg
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return wav, warnFFmpegSlow
	default:
		return wav, warnFFmpegFailed
	}
}

// normalizeTake applies a requested target (nil = none) to a finished take.
func (d *Daemon) normalizeTake(ctx context.Context, take *synthOut, lufs *float64) {
	if lufs == nil {
		return
	}
	wav, warning := d.normalizeLoudness(ctx, take.WAV, *lufs)
	take.WAV = wav
	take.addWarning(warning)
}
