// Package stt transcribes audio with the ox-stt engine child: input of any
// format is converted to a 16 kHz mono PCM16 WAV with ffmpeg, then ox-stt
// runs on it and its JSON is parsed into a typed Result. One transcription
// runs at a time per process — the engine holds ~1.3 GB of GPU memory while
// it runs, on top of whatever the TTS child holds.
package stt

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// InputError marks a failure caused by caller input — a relative path, an
// unreadable file, a clip ffmpeg cannot decode. The HTTP layer maps it to
// 400; everything else is a 500.
type InputError struct{ msg string }

func (e *InputError) Error() string { return e.msg }

// EngineError is an ox-stt run failure (nonzero exit): the input was
// decodable but the engine failed. Mapped to 500 by the HTTP layer.
type EngineError struct{ msg string }

func (e *EngineError) Error() string { return e.msg }

// Word is one timed token from the engine's "words" array.
type Word struct {
	W string  `json:"w"`
	S float64 `json:"s"`
	E float64 `json:"e"`
	P float64 `json:"p"`
}

// Segment is one timed span from the engine's "segments" array.
type Segment struct {
	S    float64 `json:"s"`
	E    float64 `json:"e"`
	Text string  `json:"text"`
}

// Result is ox-stt's JSON output, times in seconds.
type Result struct {
	Engine    string    `json:"engine"`
	Language  *string   `json:"language"` // string or null (parakeet reports none)
	DurationS float64   `json:"duration_s"`
	ElapsedS  float64   `json:"elapsed_s"`
	Text      string    `json:"text"`
	Segments  []Segment `json:"segments"`
	Words     []Word    `json:"words"`
}

// Options controls one Transcribe call. The daemon fills the Bin/Model/GPU
// fields from config; EngineBusy reports whether the TTS supervisor holds
// the GPU (state starting or ready).
type Options struct {
	Engine   string // "parakeet" (default) | "whisper"
	Language string // whisper only; parakeet auto-detects
	Prompt   string // whisper only

	Bin          string        // ox-stt binary
	Model        string        // parakeet model
	WhisperModel string        // whisper model
	GPU          string        // "auto" (default) | "on" | "off"
	EngineBusy   func() bool   // nil → false
	Timeout      time.Duration // cap on the conversion+run; 0 → DefaultTimeout
	MaxAudio     time.Duration // audio past this is not decoded; 0 → DefaultMaxAudio
	MaxQueue     int           // callers allowed to wait; 0 → DefaultMaxQueue
}

// Defaults and bounds.
const (
	DefaultTimeout  = 10 * time.Minute
	DefaultMaxAudio = 4 * time.Hour
	DefaultMaxQueue = 8
	stderrTail      = 4 << 10
)

// ErrBusy means the queue of waiting transcriptions is full.
var ErrBusy = errors.New("stt: busy, too many transcriptions queued")

// ModelError means the model file is missing; the daemon is not set up.
type ModelError struct{ msg string }

func (e *ModelError) Error() string { return e.msg }

// TimeoutError means the transcription hit Options.Timeout.
type TimeoutError struct{ After time.Duration }

func (e *TimeoutError) Error() string { return fmt.Sprintf("stt: timed out after %s", e.After) }

// sem serializes transcriptions: a second ox-stt would contend for GPU
// memory with the one already running (and with the TTS child). waiting
// counts callers queued for it, so a burst cannot pile up uploads on disk.
var (
	sem     = make(chan struct{}, 1)
	waiting atomic.Int32
)

// ffmpeg is a variable so tests can point it at a missing binary.
var ffmpeg = "ffmpeg"

// Transcribe converts audioPath (absolute) to a 16 kHz mono PCM16 WAV and
// runs ox-stt on it under ctx — a cancelled context kills the engine child.
func Transcribe(ctx context.Context, audioPath string, opts Options) (*Result, error) {
	if !filepath.IsAbs(audioPath) {
		return nil, &InputError{fmt.Sprintf("stt: audio path %q is not absolute", audioPath)}
	}
	if _, err := os.Stat(audioPath); err != nil {
		return nil, &InputError{fmt.Sprintf("stt: audio: %v", err)}
	}
	engine := opts.Engine
	if engine == "" {
		engine = "parakeet"
	}
	if engine != "parakeet" && engine != "whisper" {
		return nil, &InputError{fmt.Sprintf("stt: unsupported engine %q (want parakeet|whisper)", engine)}
	}
	model := opts.Model
	if engine == "whisper" {
		model = opts.WhisperModel
	}
	if _, err := os.Stat(model); err != nil {
		return nil, &ModelError{fmt.Sprintf("stt: model %s not found — fetch it with scripts/fetch-models.sh", filepath.Base(model))}
	}

	maxQueue := queueLimit(opts.MaxQueue)
	if waiting.Add(1) > int32(maxQueue) {
		waiting.Add(-1)
		return nil, ErrBusy
	}
	select {
	case sem <- struct{}{}:
		waiting.Add(-1)
		defer func() { <-sem }()
	case <-ctx.Done():
		waiting.Add(-1)
		return nil, ctx.Err()
	}

	timeout := opts.Timeout
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	parent := ctx
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	// a deadline of ours, not the caller going away
	timedOut := func() bool { return ctx.Err() != nil && parent.Err() == nil }

	maxAudio := opts.MaxAudio
	if maxAudio <= 0 {
		maxAudio = DefaultMaxAudio
	}
	wav, err := convert(ctx, audioPath, maxAudio)
	if err != nil {
		if timedOut() {
			return nil, &TimeoutError{After: timeout}
		}
		return nil, err
	}
	defer func() { _ = os.Remove(wav) }()

	args := []string{"-m", model, "-f", wav, "--engine", engine}
	if engine == "whisper" {
		if opts.Language != "" {
			args = append(args, "-l", opts.Language)
		}
		if opts.Prompt != "" {
			args = append(args, "--prompt", opts.Prompt)
		}
	}
	if !gpuAllowed(opts.GPU, engineBusy(opts.EngineBusy)) {
		args = append(args, "-ng")
	}

	cmd := exec.CommandContext(ctx, opts.Bin, args...)
	var out bytes.Buffer
	errb := &tailBuffer{max: stderrTail}
	cmd.Stdout = &out
	cmd.Stderr = errb
	if err := cmd.Run(); err != nil {
		if timedOut() {
			return nil, &TimeoutError{After: timeout}
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return nil, &EngineError{fmt.Sprintf("stt: ox-stt failed: %s", strings.TrimSpace(errb.String()))}
		}
		return nil, fmt.Errorf("stt: cannot run %s: %w", opts.Bin, err)
	}
	var res Result
	if err := json.Unmarshal(out.Bytes(), &res); err != nil {
		return nil, &EngineError{fmt.Sprintf("stt: ox-stt returned invalid JSON: %v", err)}
	}
	return &res, nil
}

func engineBusy(f func() bool) bool { return f != nil && f() }

func queueLimit(n int) int {
	if n <= 0 {
		return DefaultMaxQueue
	}
	return n
}

// QueueFull reports whether a new transcription would be refused with ErrBusy
// right now; the HTTP route checks it before accepting an upload.
func QueueFull(maxQueue int) bool { return waiting.Load() >= int32(queueLimit(maxQueue)) }

// gpuAllowed resolves the -ng decision: "on" always uses the GPU, "off"
// never, and "auto" stays off the GPU while the TTS engine occupies it
// (its ~2 GB plus the ~1.3 GB ox-stt wants would not fit the card). The
// exclusion is one-way: a TTS start during a GPU transcription is not held
// back, so both can briefly share the card (accepted; see the README).
func gpuAllowed(mode string, ttsBusy bool) bool {
	switch mode {
	case "on":
		return true
	case "off":
		return false
	default: // auto
		return !ttsBusy
	}
}

// tailBuffer keeps the last max bytes written to it: enough of a tool's
// stderr to explain a failure, bounded however much it prints.
type tailBuffer struct {
	max int
	b   []byte
}

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.b = append(t.b, p...)
	if len(t.b) > t.max {
		t.b = t.b[len(t.b)-t.max:]
	}
	return len(p), nil
}

func (t *tailBuffer) String() string { return string(t.b) }

// convert turns any input ffmpeg reads into a 16 kHz mono PCM16 WAV temp
// file of at most maxAudio. A clip ffmpeg ran against and refused is caller
// input; a missing binary or a kill on the timeout is a daemon fault — same
// split as voices.Prepare. It runs under the caller's context, which carries
// the overall transcription timeout.
func convert(ctx context.Context, audioPath string, maxAudio time.Duration) (string, error) {
	tmp, err := os.CreateTemp("", "ox-say-stt-*.wav")
	if err != nil {
		return "", fmt.Errorf("stt: %w", err)
	}
	tmpName := tmp.Name()
	_ = tmp.Close()
	ok := false
	defer func() {
		if !ok {
			_ = os.Remove(tmpName)
		}
	}()
	errb := &tailBuffer{max: stderrTail}
	cmd := exec.CommandContext(ctx, ffmpeg,
		"-hide_banner", "-loglevel", "error", "-y",
		"-protocol_whitelist", "file",
		"-i", "file:"+audioPath,
		// a small compressed upload can decode to hours of PCM: stop a second
		// past the cap, and refuse (below) what is still longer than the cap
		"-t", strconv.FormatFloat(maxAudio.Seconds()+1, 'f', 3, 64),
		"-ar", "16000",
		"-ac", "1",
		"-c:a", "pcm_s16le",
		tmpName,
	)
	cmd.Stdout = errb
	cmd.Stderr = errb
	// no path in messages: over HTTP it is the upload's temp file
	tail := func() string {
		return strings.TrimSpace(strings.ReplaceAll(errb.String(), audioPath, "<input>"))
	}
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && ctx.Err() == nil {
			return "", &InputError{fmt.Sprintf("stt: cannot decode audio: %s", tail())}
		}
		return "", fmt.Errorf("stt: ffmpeg: %w: %s", err, tail())
	}
	fi, err := os.Stat(tmpName)
	if err != nil {
		return "", fmt.Errorf("stt: %w", err)
	}
	// 16 kHz mono PCM16 after a 44-byte header
	if secs := float64(fi.Size()-44) / (16000 * 2); secs > maxAudio.Seconds()+0.05 {
		return "", &InputError{fmt.Sprintf("stt: audio is longer than the %s limit (OX_SAY_STT_MAX_AUDIO_SECS)", maxAudio)}
	}
	ok = true
	return tmpName, nil
}
