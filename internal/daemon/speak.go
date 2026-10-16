package daemon

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/player"
)

const maxSpeakChars = 5000

// SpeakInput is the `speak` tool / shared synthesis request.
type SpeakInput struct {
	Text         string
	Voice        string
	Language     string
	Format       string // wav (default) | mp3 | opus
	OutPath      string // empty → timestamped file under the cache dir
	Overwrite    bool
	Play         bool
	Instructions string
	Seed         *int64
	// LoudnessLUFS normalises the finished take to this integrated loudness
	// (EBU R128); nil leaves the engine's level alone.
	LoudnessLUFS *float64

	// Model names the engine ("qwen3-tts" | "voxcpm2"); empty = the voice's
	// preferred engine, then the daemon default.
	Model string
	// CfgValue, InferenceTimesteps and CloneMode are voxcpm2 knobs; the qwen
	// engine refuses them.
	CfgValue           *float64
	InferenceTimesteps *int
	CloneMode          string
}

// SpeakResult is returned to the caller.
type SpeakResult struct {
	Path      string  `json:"path"`
	Format    string  `json:"format"`
	DurationS float64 `json:"duration_s"`
	ElapsedS  float64 `json:"elapsed_s"`
	Voice     string  `json:"voice"`
	// Model is the engine that rendered the take; Seed the one it used when
	// known; Warning is set when the take is suspect or the request degraded.
	Model   string `json:"model"`
	Seed    *int64 `json:"seed,omitempty"`
	Warning string `json:"warning,omitempty"`
}

var formatExts = map[string][]string{
	"wav":  {".wav"},
	"mp3":  {".mp3"},
	"opus": {".ogg", ".opus"},
}

// validateOutPath enforces the out_path rules before any engine work:
// absolute path, existing parent dir, extension within exts, and no
// overwrite of an existing file unless allowed.
func validateOutPath(path string, exts []string, overwrite bool) error {
	if !filepath.IsAbs(path) {
		return fmt.Errorf("out_path must be absolute, got %q", path)
	}
	dir := filepath.Dir(path)
	st, err := os.Stat(dir)
	if err != nil || !st.IsDir() {
		return fmt.Errorf("out_path parent %q does not exist", dir)
	}
	ext := strings.ToLower(filepath.Ext(path))
	ok := false
	for _, e := range exts {
		if ext == e {
			ok = true
		}
	}
	if !ok {
		return fmt.Errorf("out_path extension %q not allowed (want %s)", ext, strings.Join(exts, "|"))
	}
	if _, err := os.Stat(path); err == nil && !overwrite {
		return fmt.Errorf("out_path %q exists; set overwrite to replace it", path)
	}
	return nil
}

// SynthesizeWAV renders params via the engine that serves them (see
// prepareSpeech) and returns wav bytes. The in-flight guard is held for the
// whole upstream request.
func (d *Daemon) SynthesizeWAV(ctx context.Context, params map[string]any) ([]byte, error) {
	params = maps(params)
	d.normalizeSpeakText(params)
	out, err := d.render(ctx, params)
	if err != nil {
		return nil, err
	}
	return out.WAV, nil
}

// synthesizeQwen renders a prepared body on the qwen3-tts child.
func (d *Daemon) synthesizeQwen(ctx context.Context, body map[string]any) ([]byte, error) {
	return d.speechOn(ctx, d.Sup, body)
}

// speechOn POSTs one prepared body to sup's child and returns the WAV — the
// shared shape of every engine call (Acquire, EnsureReady, Speech, status).
func (d *Daemon) speechOn(ctx context.Context, sup *engine.Supervisor, body map[string]any) ([]byte, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	g := sup.Acquire()
	defer g.Release()
	base, err := sup.EnsureReady(ctx)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errEngineStart, err)
	}
	resp, err := d.ec.Speech(ctx, base, raw)
	if err != nil {
		return nil, fmt.Errorf("engine speech: %w", err)
	}
	defer resp.Body.Close()
	wav, err := readAllCap(resp.Body, maxEngineWAVBytes)
	if err != nil {
		return nil, fmt.Errorf("engine speech: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, &engineError{status: resp.StatusCode,
			msg: fmt.Sprintf("engine speech: %s: %s", resp.Status, strings.TrimSpace(string(wav)))}
	}
	return wav, nil
}

// Speak synthesizes text to a file — the shared core of the `speak` MCP tool.
func (d *Daemon) Speak(ctx context.Context, in SpeakInput) (*SpeakResult, error) {
	// Counted from entry: /status reports it under busy.speaking — the
	// MCP caller has no HTTP wrapper to stamp, so the count lives here.
	d.speaking.Add(1)
	defer d.speaking.Add(-1)
	if in.Text == "" {
		return nil, fmt.Errorf("text is required")
	}
	if n := utf8.RuneCountInString(in.Text); n > maxSpeakChars {
		return nil, fmt.Errorf("text is %d chars, max %d", n, maxSpeakChars)
	}
	format := in.Format
	if format == "" {
		format = "wav"
	}
	if _, ok := formatExts[format]; !ok {
		return nil, fmt.Errorf("unsupported format %q (want wav|mp3|opus)", format)
	}
	if in.OutPath != "" {
		if err := validateOutPath(in.OutPath, formatExts[format], in.Overwrite); err != nil {
			return nil, err
		}
	}
	if in.LoudnessLUFS != nil {
		if err := validLUFS(*in.LoudnessLUFS); err != nil {
			return nil, err
		}
	}
	if in.Play && format == "opus" {
		return nil, fmt.Errorf("opus produces an .ogg file the platform player (afplay) cannot play; use format wav or mp3 with play")
	}

	params := map[string]any{fieldInput: in.Text}
	if in.Voice != "" {
		params["voice"] = in.Voice
	}
	if in.Language != "" {
		params["language"] = in.Language
	}
	if in.Instructions != "" {
		params[fieldInstruct] = in.Instructions
	}
	if in.Seed != nil {
		params[fieldSeed] = *in.Seed
	}
	if in.Model != "" {
		params[fieldModel] = in.Model
	}
	if in.CfgValue != nil {
		params["cfg_value"] = *in.CfgValue
	}
	if in.InferenceTimesteps != nil {
		params["inference_timesteps"] = *in.InferenceTimesteps
	}
	if in.CloneMode != "" {
		params["clone_mode"] = in.CloneMode
	}
	d.normalizeSpeakText(params)

	start := time.Now()
	rendered, err := d.render(ctx, params)
	if err != nil {
		return nil, err
	}
	elapsed := time.Since(start)
	d.normalizeTake(ctx, rendered, in.LoudnessLUFS)
	wav := rendered.WAV

	audio := wav
	if format != "wav" {
		audio, err = transcode(ctx, wav, format)
		if err != nil {
			return nil, err
		}
	}

	out := in.OutPath
	if out == "" {
		if err := os.MkdirAll(d.Cfg.CacheDir, 0o755); err != nil {
			return nil, err
		}
		out = filepath.Join(d.Cfg.CacheDir,
			fmt.Sprintf("%s-%s.%s", time.Now().Format("20060102-150405"), slugify(in.Text), formatExt(format)))
	}
	if err := writeFile(out, audio, in.Overwrite); err != nil {
		return nil, err
	}
	if in.Play {
		if err := playFn(ctx, out); err != nil {
			return nil, fmt.Errorf("play %s: %w", out, err)
		}
	}

	voice := in.Voice
	if voice == "" {
		voice = d.configuredVoice(langHint(params))
	}
	if voice == "" {
		voice = "default"
	}
	return &SpeakResult{
		Path:      out,
		Format:    format,
		DurationS: math.Round(wavDuration(wav)*100) / 100,
		ElapsedS:  math.Round(elapsed.Seconds()*100) / 100,
		Voice:     voice,
		Model:     rendered.Model,
		Seed:      rendered.Seed,
		Warning:   rendered.Warning,
	}, nil
}

// playFn is the platform player hook — tests stub it.
var playFn = player.Play

func formatExt(format string) string {
	if format == "opus" {
		return "ogg"
	}
	return format
}

// writeFile writes audio to path; without overwrite the file is created
// exclusively (a second writer fails rather than clobbering).
func writeFile(path string, data []byte, overwrite bool) error {
	flags := os.O_WRONLY | os.O_CREATE
	if overwrite {
		// Never follow a planted symlink onto an unrelated file.
		if st, err := os.Lstat(path); err == nil && st.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("%q is a symlink; refusing to overwrite it", path)
		}
		flags |= os.O_TRUNC
	} else {
		flags |= os.O_EXCL
	}
	f, err := os.OpenFile(path, flags, 0o644)
	if err != nil {
		if os.IsExist(err) {
			return fmt.Errorf("%q exists; set overwrite to replace it", path)
		}
		return fmt.Errorf("write %s: %w", path, err)
	}
	defer f.Close()
	if _, err := f.Write(data); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

// slugify builds the <short slug> part of a default output name.
func slugify(text string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(text) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		} else if b.Len() > 0 && !strings.HasSuffix(b.String(), "-") {
			b.WriteByte('-')
		}
		if b.Len() >= 32 {
			break
		}
	}
	s := strings.Trim(b.String(), "-")
	if s == "" {
		return "speech"
	}
	return s
}

// wavDuration is the PCM duration in seconds, 0 when wav is not a PCM WAV.
func wavDuration(wav []byte) float64 {
	_, secs := wavInfo(wav)
	return secs
}

// wavInfo walks the RIFF chunks and returns the sample rate and the PCM
// duration; both are 0 when wav is not a PCM WAV.
func wavInfo(wav []byte) (rate int, secs float64) {
	if len(wav) < 44 || string(wav[:4]) != "RIFF" || string(wav[8:12]) != "WAVE" {
		return 0, 0
	}
	var channels, bits int
	var dataSize int64
	for off := 12; off+8 <= len(wav); {
		id := string(wav[off : off+4])
		size := int64(binary.LittleEndian.Uint32(wav[off+4:]))
		body := wav[off+8:]
		if id == "fmt " && len(body) >= 16 {
			channels = int(binary.LittleEndian.Uint16(body[2:]))
			rate = int(binary.LittleEndian.Uint32(body[4:]))
			bits = int(binary.LittleEndian.Uint16(body[14:]))
		}
		if id == "data" {
			dataSize = size
			break
		}
		off += 8 + int(size) + int(size&1) // chunks are 2-aligned
	}
	bytesPerSec := int64(rate * channels * (bits / 8))
	if bytesPerSec <= 0 || dataSize <= 0 {
		return rate, 0
	}
	return rate, float64(dataSize) / float64(bytesPerSec)
}
