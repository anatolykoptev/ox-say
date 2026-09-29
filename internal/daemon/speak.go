package daemon

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"

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
}

// SpeakResult is returned to the caller.
type SpeakResult struct {
	Path      string  `json:"path"`
	Format    string  `json:"format"`
	DurationS float64 `json:"duration_s"`
	ElapsedS  float64 `json:"elapsed_s"`
	Voice     string  `json:"voice"`
}

var formatExts = map[string][]string{
	"wav":  {".wav"},
	"mp3":  {".mp3"},
	"opus": {".ogg", ".opus"},
}

// validateOutPath enforces the out_path rules before any synthesis work:
// absolute path, existing parent dir, extension matching the format, and no
// overwrite of an existing file unless Overwrite.
func validateOutPath(path, format string, overwrite bool) error {
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
	for _, e := range formatExts[format] {
		if ext == e {
			ok = true
		}
	}
	if !ok {
		return fmt.Errorf("out_path extension %q does not match format %s", ext, format)
	}
	if _, err := os.Stat(path); err == nil && !overwrite {
		return fmt.Errorf("out_path %q exists; set overwrite to replace it", path)
	}
	return nil
}

// SynthesizeWAV renders params via the engine and returns wav bytes. The
// in-flight guard is held for the whole upstream request.
func (d *Daemon) SynthesizeWAV(ctx context.Context, params map[string]any) ([]byte, error) {
	body := maps(params)
	body["response_format"] = "wav"
	d.applyLanguageDefault(body)
	raw, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	base, g, err := d.engineBase(ctx)
	if err != nil {
		return nil, fmt.Errorf("engine failed to start: %w", err)
	}
	defer g.Release()
	resp, err := d.ec.Speech(ctx, base, raw)
	if err != nil {
		return nil, fmt.Errorf("engine speech: %w", err)
	}
	defer resp.Body.Close()
	wav, err := io.ReadAll(io.LimitReader(resp.Body, 256<<20))
	if err != nil {
		return nil, fmt.Errorf("engine speech: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("engine speech: %s: %s", resp.Status, strings.TrimSpace(string(wav)))
	}
	return wav, nil
}

// Speak synthesizes text to a file — the shared core of the `speak` MCP tool.
func (d *Daemon) Speak(ctx context.Context, in SpeakInput) (*SpeakResult, error) {
	if in.Text == "" {
		return nil, fmt.Errorf("text is required")
	}
	if len(in.Text) > maxSpeakChars {
		return nil, fmt.Errorf("text is %d chars, max %d", len(in.Text), maxSpeakChars)
	}
	format := in.Format
	if format == "" {
		format = "wav"
	}
	if _, ok := formatExts[format]; !ok {
		return nil, fmt.Errorf("unsupported format %q (want wav|mp3|opus)", format)
	}
	if in.OutPath != "" {
		if err := validateOutPath(in.OutPath, format, in.Overwrite); err != nil {
			return nil, err
		}
	}
	if in.Play && format == "opus" {
		return nil, fmt.Errorf("opus produces an .ogg file the platform player (afplay) cannot play; use format wav or mp3 with play")
	}

	params := map[string]any{"input": in.Text}
	if in.Voice != "" {
		params["voice"] = in.Voice
	}
	if in.Language != "" {
		params["language"] = in.Language
	}
	if in.Instructions != "" {
		params["instructions"] = in.Instructions
	}
	if in.Seed != nil {
		params["seed"] = *in.Seed
	}

	start := time.Now()
	wav, err := d.SynthesizeWAV(ctx, params)
	if err != nil {
		return nil, err
	}
	elapsed := time.Since(start)

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
		voice = "default"
	}
	return &SpeakResult{
		Path:      out,
		Format:    format,
		DurationS: math.Round(wavDuration(wav)*100) / 100,
		ElapsedS:  math.Round(elapsed.Seconds()*100) / 100,
		Voice:     voice,
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

// wavDuration walks the RIFF chunks and computes the PCM duration.
func wavDuration(wav []byte) float64 {
	if len(wav) < 44 || string(wav[:4]) != "RIFF" || string(wav[8:12]) != "WAVE" {
		return 0
	}
	var rate, channels, bits int
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
		return 0
	}
	return float64(dataSize) / float64(bytesPerSec)
}
