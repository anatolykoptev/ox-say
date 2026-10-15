package daemon

import (
	"bytes"
	"context"
	"errors"
	"fmt"
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

// loudnorm normalises wav to lufs integrated loudness, single pass, keeping its
// sample rate: the filter resamples to 192 kHz internally, so the rate is
// forced back and the result is checked. ffmpeg writes to a temp file in dir:
// a WAV written to a pipe carries no sizes in its header. The long-form
// producer calls this (via normalizeLoudness) once on the assembled file.
func loudnorm(ctx context.Context, dir string, wav []byte, lufs float64) ([]byte, error) {
	rate, _ := wavInfo(wav)
	if rate <= 0 {
		return nil, fmt.Errorf("loudnorm: not a PCM WAV")
	}
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
	filter := fmt.Sprintf("loudnorm=I=%g:TP=%g:LRA=%d", lufs, loudnormTP, loudnormLRA)
	cmd := exec.CommandContext(ctx, "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
		"-f", "wav", "-i", "pipe:0", "-af", filter, "-ar", strconv.Itoa(rate), "-c:a", "pcm_s16le", out)
	cmd.Stdin = bytes.NewReader(wav)
	cmd.WaitDelay = loudnormWaitDelay
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("ffmpeg loudnorm: %w: %s", err, strings.TrimSpace(errb.String()))
	}
	res, err := os.ReadFile(out)
	if err != nil {
		return nil, err
	}
	// ffmpeg can exit 0 and leave nothing, or leave the wrong rate: neither
	// may pass for a normalised take.
	if gotRate, secs := wavInfo(res); gotRate != rate || secs <= 0 {
		return nil, fmt.Errorf("loudnorm: ffmpeg produced %d Hz / %.2f s, want %d Hz of audio", gotRate, secs, rate)
	}
	return res, nil
}

// normalizeLoudness is loudnorm that cannot lose the take: when ffmpeg is
// missing or fails, it returns wav untouched with a plain-words warning and
// logs the cause. Apply it to a finished take or to an assembled file, never
// inside synthesize.
func (d *Daemon) normalizeLoudness(ctx context.Context, wav []byte, lufs float64) (out []byte, warning string) {
	ctx, cancel := context.WithTimeout(ctx, loudnormTimeout)
	defer cancel()
	out, err := loudnorm(ctx, d.Cfg.CacheDir, wav, lufs)
	if err == nil {
		return out, ""
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
