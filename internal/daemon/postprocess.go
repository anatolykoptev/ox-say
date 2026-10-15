package daemon

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"os"
	"os/exec"
)

// fieldLoudness is ox-say's own request field: never forwarded to an engine.
const fieldLoudness = "loudness_lufs"

// EBU R128 bounds for a requested target.
const (
	minLUFS = -40.0
	maxLUFS = -5.0
)

// Plain-words reasons a take kept its original level.
const (
	warnNoFFmpeg     = "loudness was not normalised: ffmpeg is not installed, so the take keeps its original level"
	warnFFmpegFailed = "loudness was not normalised: ffmpeg could not process the audio, so the take keeps its original level"
	warnTooQuiet     = "loudness was not normalised: the take is too quiet to raise to the target without boosting its noise, so it keeps its original level"
	warnUnmeasurable = "loudness was not normalised: the take is silent or too short to measure, so it keeps its original level"
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
// logs the cause. A take that was levelled but needed a peak limiter, or could
// not reach the target under the true-peak ceiling, comes back with the
// matching warning. Apply it to a finished take or to an assembled file, never
// inside synthesize.
func (d *Daemon) normalizeLoudness(ctx context.Context, wav []byte, lufs float64) (out []byte, warning string) {
	ctx, cancel := context.WithTimeout(ctx, loudnormTimeout)
	defer cancel()
	out, note, err := loudnorm(ctx, d.Cfg.CacheDir, wav, lufs)
	if err == nil {
		if note != "" {
			d.log.Warn("loudness needed the peak limiter", slog.Float64("target_lufs", lufs), slog.String("note", note))
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
	case errors.Is(err, errTooQuiet):
		return wav, warnTooQuiet
	case errors.Is(err, errUnmeasurable):
		return wav, warnUnmeasurable
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
