// Package stt transcribes audio with the ox-stt engine: input of any format
// is converted to a 16 kHz mono PCM16 WAV with ffmpeg, then decoded either
// by the resident `ox-stt --serve` process (the default for parakeet clips
// up to serverMaxAudio — the model is loaded once, so a warm call is far
// faster than a cold CLI start) or by a per-call ox-stt child. One
// transcription runs at a time per process. The resident server runs on
// the CPU (it is spawned with -ng unless OX_SAY_STT_GPU=on), so it never
// takes GPU memory from the TTS child; its idle cost is ~1.4 GB of RAM.
package stt

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
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
	Timeout      time.Duration // fixed allowance: bounds the conversion alone and seeds the engine's base + k×duration budget; 0 → DefaultTimeout
	MaxAudio     time.Duration // audio past this is not decoded; 0 → DefaultMaxAudio
	MaxQueue     int           // callers allowed to wait; 0 → DefaultMaxQueue

	// Server, when non-nil, acquires the resident ox-stt server: it returns
	// its base URL plus a release func the caller runs once the response
	// body is read. A nil Server means CLI only. The daemon wires it to the
	// STT supervisor's Acquire+EnsureReady.
	Server func(ctx context.Context) (baseURL string, release func(), err error)
	// OnServerError is called with the error that sent a request back to
	// the CLI path; nil → ignore.
	OnServerError func(error)
}

// Defaults and bounds.
const (
	DefaultTimeout  = 10 * time.Minute
	DefaultMaxAudio = 4 * time.Hour
	DefaultMaxQueue = 8
	stderrTail      = 4 << 10
)

// sttK is the decode budget's per-second rate: seconds of engine time
// allowed per second of audio, by engine and device. Both engines scale
// linearly — fixed start + per-second slope, measured with `ox-stt -ng`
// on this Mac at v0.1.5 (issue #16):
//
//	parakeet   70 s → 11.6 s, 630 s → 68.0 s   (≈4.5 s fixed + 0.10 s/s)
//	whisper    70 s → 111.2 s, 630 s → 487.0 s (≈64 s fixed + 0.67 s/s)
//
// The rates carry a ≈4.5–5× safety factor over those slopes; the fixed
// part (model load, spawn) is covered by base. The GPU cells reuse the
// CPU rate: the GPU is strictly faster, so the budget stays
// conservative there. A var so tests can scale the rate.
var sttK = map[string]map[bool]float64{
	"parakeet": {false: 0.5, true: 0.5},
	"whisper":  {false: 3.0, true: 3.0},
}

// serverMaxAudio caps the clips routed to the resident server: a cancelled
// server decode is not killed the way a CLI child is, so long files stay on
// the CLI. Tests shrink it.
var serverMaxAudio = 300 * time.Second

// serverHTTP has no Timeout: the caller's ctx carries the deadline.
var serverHTTP = &http.Client{}

// ErrBusy means the queue of waiting transcriptions is full.
var ErrBusy = errors.New("stt: busy, too many transcriptions queued")

// ModelError means the model file is missing; the daemon is not set up.
type ModelError struct{ msg string }

func (e *ModelError) Error() string { return e.msg }

// TimeoutError means the transcription hit a phase budget — the
// conversion's base allowance or the engine's scaled deadline; After
// names the one that fired.
type TimeoutError struct{ After time.Duration }

func (e *TimeoutError) Error() string { return fmt.Sprintf("stt: timed out after %s", e.After) }

// sttTimeout is the engine-run budget for one clip: the fixed base
// (Options.Timeout, from OX_SAY_STT_TIMEOUT_SECS) plus sttK seconds per
// second of audio. A flat cap cannot fit both a 10 s clip and a 4 h
// file — the old 600 s covered only ~3.2 h of parakeet-CPU audio
// (issue #16). engine is validated before this is called.
func sttTimeout(engine string, gpu bool, secs float64, base time.Duration) time.Duration {
	if base <= 0 {
		base = DefaultTimeout
	}
	return base + time.Duration(sttK[engine][gpu]*secs*float64(time.Second))
}

// WorstTimeout bounds one transcription at the longest allowed clip on
// the slowest engine/device. The daemon sizes the transcribe tool's MCP
// timeout on it so a long run is never cut before its own deadline.
func WorstTimeout(maxAudio, base time.Duration) time.Duration {
	if maxAudio <= 0 {
		maxAudio = DefaultMaxAudio
	}
	var worst time.Duration
	for engine, dev := range sttK {
		for gpu := range dev {
			if d := sttTimeout(engine, gpu, maxAudio.Seconds(), base); d > worst {
				worst = d
			}
		}
	}
	return worst
}

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

	base := opts.Timeout
	if base <= 0 {
		base = DefaultTimeout
	}
	maxAudio := opts.MaxAudio
	if maxAudio <= 0 {
		maxAudio = DefaultMaxAudio
	}
	parent := ctx

	// Conversion runs under the base alone: the duration that would
	// scale its budget is only known once ffmpeg has run, and ffmpeg
	// self-caps the decode at maxAudio + 1 s anyway.
	cctx, ccancel := context.WithTimeout(parent, base)
	wav, secs, err := convert(cctx, audioPath, maxAudio)
	// Snapshot the timeout check BEFORE ccancel — after it, cctx.Err()
	// is Canceled regardless of why convert failed.
	convTimedOut := cctx.Err() != nil && parent.Err() == nil
	ccancel()
	if err != nil {
		if convTimedOut {
			return nil, &TimeoutError{After: base}
		}
		return nil, err
	}
	defer func() { _ = os.Remove(wav) }()

	// The engine budget scales with the real duration (issue #16). The
	// device is the worst the run may land on: only OX_SAY_STT_GPU=on
	// keeps every leg — the resident server and the CLI fallback — off
	// the CPU.
	timeout := sttTimeout(engine, opts.GPU == "on", secs, base)
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	// a deadline of ours, not the caller going away
	timedOut := func() bool { return ctx.Err() != nil && parent.Err() == nil }

	// The resident server decodes parakeet only and returns the CLI's JSON
	// shape; short clips go to it whatever the TTS state is (the server is
	// CPU-only by default). Long files stay on the CLI: a cancelled CLI run
	// is killed, a cancelled server decode is not.
	if engine == "parakeet" && opts.Server != nil && secs <= serverMaxAudio.Seconds() {
		res, err := transcribeServer(ctx, wav, opts)
		switch {
		case err == nil:
			return res, nil
		case timedOut():
			return nil, &TimeoutError{After: timeout}
		case ctx.Err() != nil:
			return nil, ctx.Err()
		}
		if opts.OnServerError != nil {
			opts.OnServerError(err)
		}
	}

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

// transcribeServer posts the converted WAV to the resident ox-stt server.
// Any failure — acquire, transport, non-200, invalid JSON — is the caller's
// fallback signal; a caller-side cancellation surfaces as the ctx error.
func transcribeServer(ctx context.Context, wav string, opts Options) (*Result, error) {
	base, release, err := opts.Server(ctx)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(wav)
	if err != nil {
		release()
		return nil, err
	}
	defer func() { _ = f.Close() }()
	fi, err := f.Stat()
	if err != nil {
		release()
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/transcribe", f)
	if err != nil {
		release()
		return nil, err
	}
	req.ContentLength = fi.Size()
	// ox-stt's httplib caps a form-urlencoded body at 8 KB; a raw WAV body
	// under its own content type is unlimited.
	req.Header.Set("Content-Type", "audio/wav")
	resp, err := serverHTTP.Do(req)
	if err != nil {
		release()
		return nil, err
	}
	body, rerr := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	_ = resp.Body.Close()
	release()
	if rerr != nil {
		return nil, rerr
	}
	if resp.StatusCode != http.StatusOK {
		msg := strings.TrimSpace(string(body))
		if len(msg) > 256 {
			msg = msg[:256]
		}
		return nil, fmt.Errorf("stt: server %s: %s", resp.Status, msg)
	}
	var res Result
	if err := json.Unmarshal(body, &res); err != nil {
		return nil, fmt.Errorf("stt: server returned invalid JSON: %v", err)
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

// gpuAllowed resolves the -ng decision for the per-call CLI — the resident
// server has its own device choice (CPU unless OX_SAY_STT_GPU=on). "on"
// always uses the GPU, "off" never, and "auto" stays off the GPU while the
// TTS engine occupies it (its ~2 GB plus the ~1.3 GB ox-stt wants would not
// fit the card). The exclusion is one-way: a TTS start during a GPU
// transcription is not held back, so both can briefly share the card
// (accepted; see the README).
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
// file of at most maxAudio and reports the decoded duration. A clip ffmpeg
// ran against and refused is caller input; a missing binary or a kill on
// the timeout is a daemon fault — same split as voices.Prepare. It runs
// under the caller's context, which carries the overall transcription
// timeout.
func convert(ctx context.Context, audioPath string, maxAudio time.Duration) (wav string, secs float64, err error) {
	tmp, err := os.CreateTemp("", "ox-say-stt-*.wav")
	if err != nil {
		return "", 0, fmt.Errorf("stt: %w", err)
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
			return "", 0, &InputError{fmt.Sprintf("stt: cannot decode audio: %s", tail())}
		}
		return "", 0, fmt.Errorf("stt: ffmpeg: %w: %s", err, tail())
	}
	fi, err := os.Stat(tmpName)
	if err != nil {
		return "", 0, fmt.Errorf("stt: %w", err)
	}
	// 16 kHz mono PCM16 after a 44-byte header
	secs = float64(fi.Size()-44) / (16000 * 2)
	if secs > maxAudio.Seconds()+0.05 {
		return "", 0, &InputError{fmt.Sprintf("stt: audio is longer than the %s limit (OX_SAY_STT_MAX_AUDIO_SECS)", maxAudio)}
	}
	ok = true
	return tmpName, secs, nil
}
