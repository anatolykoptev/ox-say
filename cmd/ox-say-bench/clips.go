package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	sttSampleRate    = 16000
	refSampleRate    = 24000
	wavHeader        = 44
	pcm16Bytes       = 2
	narrationRepeats = 20  // ≈ 25 s per paragraph at say's default rate → ≥ 360 s
	longClip         = 360 // s: the README's "6 minutes of audio" CLI figure
	sessionClip      = 15  // s streamed through a dictation session
	refMaxSecs       = 20  // voices.Store keeps at most 20 s of a reference
	shortCutSlack    = 1.0 // s a cut may fall short of its target
	enVoice          = "Samantha"
	ruVoice          = "Milena"
)

// sweepLengths are the whole-clip lengths, in seconds, of the STT sweep;
// 300 s is the daemon's cap for the resident server (stt.serverMaxAudio),
// where the encoder's super-linear cost would show.
var sweepLengths = []int{5, 15, 30, 60, 120, 300}

const enNarration = "Local speech on a laptop should feel instant. You hold a key, say a sentence, " +
	"and the words appear where the cursor is, with the punctuation in place. The same machine reads " +
	"text back in a voice you choose, and it never sends a recording anywhere. That is the whole " +
	"promise, and every number in this report measures how well this Mac keeps it."

const ruReference = "Здравствуйте! Это короткая запись моего голоса. Я читаю её спокойно и " +
	"разборчиво, чтобы по ней можно было повторить тембр и интонацию."

// clips makes every audio input from macOS's own voices, so the benchmark
// needs no download beyond the models and gives the same input every run.
type clips struct {
	dir       string
	narration string // English speech, ≥ longClip seconds (AIFF from say)
	ref       string // Russian voice reference: 24 kHz mono PCM16 WAV
	refText   string
}

func makeClips(ctx context.Context, dir string) (*clips, error) {
	c := &clips{dir: dir, refText: ruReference}
	txt := filepath.Join(dir, "narration.txt")
	if err := os.WriteFile(txt, []byte(strings.Repeat(enNarration+"\n", narrationRepeats)), filePerm); err != nil {
		return nil, err
	}
	c.narration = filepath.Join(dir, "narration.aiff")
	if err := runTool(ctx, "say", "-v", enVoice, "-f", txt, "-o", c.narration); err != nil {
		return nil, fmt.Errorf("%w (is the %s voice installed?)", err, enVoice)
	}
	refAIFF := filepath.Join(dir, "ref.aiff")
	if err := runTool(ctx, "say", "-v", ruVoice, "-o", refAIFF, ruReference); err != nil {
		return nil, fmt.Errorf("%w (is the %s voice installed?)", err, ruVoice)
	}
	c.ref = filepath.Join(dir, "ref.wav")
	err := ffmpeg(ctx, refAIFF, c.ref, "-t", strconv.Itoa(refMaxSecs),
		"-ar", strconv.Itoa(refSampleRate), "-ac", "1", "-c:a", "pcm_s16le")
	return c, err
}

// wav cuts the first secs seconds of the narration into a 16 kHz mono PCM16
// WAV — the format the daemon hands ox-stt — and refuses a short cut.
func (c *clips) wav(ctx context.Context, secs int) (string, error) {
	out := filepath.Join(c.dir, fmt.Sprintf("en-%ds.wav", secs))
	err := ffmpeg(ctx, c.narration, out, "-t", strconv.Itoa(secs),
		"-ar", strconv.Itoa(sttSampleRate), "-ac", "1", "-c:a", "pcm_s16le")
	if err != nil {
		return "", err
	}
	fi, err := os.Stat(out)
	if err != nil {
		return "", err
	}
	if got := float64(fi.Size()-wavHeader) / (sttSampleRate * pcm16Bytes); got < float64(secs)-shortCutSlack {
		return "", fmt.Errorf("narration gives %.1f s, want %d s: raise narrationRepeats", got, secs)
	}
	return out, nil
}

// f32 is the same cut as raw float32 little-endian PCM — a session /audio body.
func (c *clips) f32(ctx context.Context, secs int) (string, error) {
	out := filepath.Join(c.dir, fmt.Sprintf("en-%ds.f32", secs))
	return out, ffmpeg(ctx, c.narration, out, "-t", strconv.Itoa(secs),
		"-ar", strconv.Itoa(sttSampleRate), "-ac", "1", "-f", "f32le")
}

func ffmpeg(ctx context.Context, in, out string, args ...string) error {
	full := append([]string{"-hide_banner", "-loglevel", "error", "-y", "-i", in}, args...)
	return runTool(ctx, "ffmpeg", append(full, out)...)
}

// runTool runs a command and folds its stderr into the error.
func runTool(ctx context.Context, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s: %w: %s", name, err, strings.TrimSpace(stderr.String()))
	}
	return nil
}
