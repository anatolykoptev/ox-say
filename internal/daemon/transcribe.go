package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/stt"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// TranscribeInput is the shared STT request of the HTTP route and the MCP
// transcribe tool.
type TranscribeInput struct {
	AudioPath string // absolute path (HTTP: the upload's temp file)
	Engine    string // parakeet (default) | whisper
	Language  string // whisper only; parakeet auto-detects
	Prompt    string // whisper only
}

// Transcribe runs one stt.Transcribe with the daemon's config; the STT
// device choice sees the live TTS supervisor state so a CLI ox-stt never
// takes GPU memory the TTS child is holding. Parakeet clips go to the
// resident CPU server when it is enabled — independent of TTS state — and
// fall back to the CLI on a server failure.
func (d *Daemon) Transcribe(ctx context.Context, in TranscribeInput) (*stt.Result, error) {
	opts := stt.Options{
		Engine:       in.Engine,
		Language:     in.Language,
		Prompt:       in.Prompt,
		Bin:          d.Cfg.STTBin,
		Model:        d.Cfg.STTModel,
		WhisperModel: d.Cfg.STTWhisperModel,
		GPU:          d.Cfg.STTGPU,
		Timeout:      d.Cfg.STTTimeout,
		MaxAudio:     d.Cfg.STTMaxAudio,
		EngineBusy: func() bool {
			s := d.Sup.State()
			return s == engine.StateStarting || s == engine.StateReady
		},
	}
	if d.STTSup != nil {
		opts.Server = d.sttServer
		opts.OnServerError = func(err error) {
			d.log.Warn("stt server failed; retrying via CLI", slog.Any("error", err))
		}
	}
	return stt.Transcribe(ctx, in.AudioPath, opts)
}

// handleTranscribe is OpenAI-compatible /v1/audio/transcriptions. The
// multipart body is streamed: the "file" part goes to a temp file under the
// size cap and is removed when the request ends, success or failure.
// transcribeFields are the multipart fields the route reads; anything else is
// ignored unread beyond its first 4 KB.
var transcribeFields = map[string]bool{"model": true, "language": true, "prompt": true, "response_format": true}

func (d *Daemon) handleTranscribe(w http.ResponseWriter, r *http.Request) {
	maxUp := d.Cfg.STTMaxUploadMB << 20
	// The server's 30 s read timeout covers the whole body; a large upload from
	// slow storage needs longer. The size cap still bounds it.
	if err := http.NewResponseController(w).SetReadDeadline(time.Now().Add(d.Cfg.STTTimeout)); err != nil {
		d.log.Warn("transcriptions: cannot extend the read deadline; large uploads hit the server read timeout", slog.Any("error", err))
	}
	if stt.QueueFull(0) {
		writeErr(w, http.StatusServiceUnavailable, stt.ErrBusy.Error())
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxUp+(1<<20))
	mr, err := r.MultipartReader()
	if err != nil {
		writeErr(w, http.StatusBadRequest, "expected a multipart/form-data body")
		return
	}
	var tmp string
	defer func() {
		if tmp != "" {
			_ = os.Remove(tmp)
		}
	}()
	fields := map[string]string{}
	for {
		part, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			var mbErr *http.MaxBytesError
			if errors.As(err, &mbErr) {
				writeErr(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("upload exceeds %d MB", d.Cfg.STTMaxUploadMB))
			} else {
				writeErr(w, http.StatusBadRequest, "invalid multipart body")
			}
			return
		}
		if part.FormName() == "file" {
			if tmp != "" {
				writeErr(w, http.StatusBadRequest, "multiple file parts")
				return
			}
			f, err := os.CreateTemp("", "ox-say-upload-*")
			if err != nil {
				writeErr(w, http.StatusInternalServerError, err.Error())
				return
			}
			n, err := io.Copy(f, io.LimitReader(part, maxUp+1))
			_ = f.Close()
			tmp = f.Name()
			var mbErr *http.MaxBytesError
			if n > maxUp || errors.As(err, &mbErr) {
				writeErr(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("upload exceeds %d MB", d.Cfg.STTMaxUploadMB))
				return
			}
			if err != nil {
				writeErr(w, http.StatusBadRequest, fmt.Sprintf("upload failed: %v", err))
				return
			}
			continue
		}
		v, err := io.ReadAll(io.LimitReader(part, 4<<10+1))
		if err != nil {
			writeErr(w, http.StatusBadRequest, "invalid multipart body")
			return
		}
		if transcribeFields[part.FormName()] {
			if len(v) > 4<<10 {
				writeErr(w, http.StatusBadRequest, fmt.Sprintf("field %q exceeds 4 KB", part.FormName()))
				return
			}
			fields[part.FormName()] = string(v)
		}
	}
	if tmp == "" {
		writeErr(w, http.StatusBadRequest, `"file" is required`)
		return
	}

	eng := "parakeet"
	switch fields["model"] {
	case "", "parakeet":
	case "whisper", "whisper-1":
		eng = "whisper"
	default:
		writeErr(w, http.StatusBadRequest, fmt.Sprintf("unsupported model %q (want parakeet|whisper)", fields["model"]))
		return
	}
	format := fields["response_format"]
	switch format {
	case "", "json", "text", "verbose_json", "srt", "vtt", "ox_json":
	default:
		writeErr(w, http.StatusBadRequest, fmt.Sprintf("unsupported response_format %q (want json|text|verbose_json|srt|vtt|ox_json)", format))
		return
	}
	if format == "" {
		format = "json"
	}

	res, err := d.Transcribe(r.Context(), TranscribeInput{
		AudioPath: tmp,
		Engine:    eng,
		Language:  fields["language"],
		Prompt:    fields["prompt"],
	})
	if err != nil {
		writeErr(w, transcribeStatus(err), err.Error())
		return
	}

	switch format {
	case "text":
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, res.Text)
	case "srt":
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, toSRT(res.Segments))
	case "vtt":
		w.Header().Set("Content-Type", "text/vtt; charset=utf-8")
		_, _ = io.WriteString(w, toVTT(res.Segments))
	case "verbose_json":
		writeJSON(w, http.StatusOK, toOpenAIVerbose(res))
	case "ox_json":
		// ox-say extension: ox-stt's own JSON (words as w/s/e/p, times in seconds)
		writeJSON(w, http.StatusOK, res)
	default:
		writeJSON(w, http.StatusOK, map[string]any{"text": res.Text})
	}
}

// transcribeStatus maps an stt error to an HTTP status.
func transcribeStatus(err error) int {
	var iErr *stt.InputError
	var tErr *stt.TimeoutError
	var mErr *stt.ModelError
	switch {
	case errors.As(err, &iErr):
		return http.StatusBadRequest
	case errors.As(err, &tErr):
		return http.StatusGatewayTimeout
	case errors.As(err, &mErr), errors.Is(err, stt.ErrBusy):
		return http.StatusServiceUnavailable
	default:
		return http.StatusInternalServerError
	}
}

// openAIVerbose is OpenAI's verbose_json transcription shape, which OpenAI
// clients parse; words are always included. Fields the engines do not produce
// (tokens, compression_ratio, no_speech_prob) carry neutral values;
// avg_logprob is the mean log probability of the segment's words. language is
// the engine's code ("" for parakeet), not OpenAI's full name.
type openAIVerbose struct {
	Task     string          `json:"task"`
	Language string          `json:"language"`
	Duration float64         `json:"duration"`
	Text     string          `json:"text"`
	Segments []openAISegment `json:"segments"`
	Words    []openAIWord    `json:"words"`
}

type openAISegment struct {
	ID               int     `json:"id"`
	Seek             int     `json:"seek"`
	Start            float64 `json:"start"`
	End              float64 `json:"end"`
	Text             string  `json:"text"`
	Tokens           []int   `json:"tokens"`
	Temperature      float64 `json:"temperature"`
	AvgLogprob       float64 `json:"avg_logprob"`
	CompressionRatio float64 `json:"compression_ratio"`
	NoSpeechProb     float64 `json:"no_speech_prob"`
}

type openAIWord struct {
	Word  string  `json:"word"`
	Start float64 `json:"start"`
	End   float64 `json:"end"`
}

func toOpenAIVerbose(res *stt.Result) openAIVerbose {
	v := openAIVerbose{
		Task:     "transcribe",
		Duration: res.DurationS,
		Text:     res.Text,
		Segments: make([]openAISegment, 0, len(res.Segments)),
		Words:    make([]openAIWord, 0, len(res.Words)),
	}
	if res.Language != nil {
		v.Language = *res.Language
	}
	for i, s := range res.Segments {
		v.Segments = append(v.Segments, openAISegment{
			ID: i, Start: s.S, End: s.E, Text: s.Text,
			Tokens: []int{}, AvgLogprob: avgLogprob(res.Words, s.S, s.E),
		})
	}
	for _, w := range res.Words {
		v.Words = append(v.Words, openAIWord{Word: w.W, Start: w.S, End: w.E})
	}
	return v
}

// avgLogprob is the mean ln(p) of the words that start inside [s, e).
func avgLogprob(words []stt.Word, s, e float64) float64 {
	sum, n := 0.0, 0
	for _, w := range words {
		if w.S >= s && w.S < e && w.P > 0 {
			sum += math.Log(w.P)
			n++
		}
	}
	if n == 0 {
		return 0
	}
	return sum / float64(n)
}

// srtStamp renders seconds as HH:MM:SS,mmm.
func srtStamp(t float64) string {
	ms := int64(math.Round(t * 1000))
	if ms < 0 {
		ms = 0
	}
	return fmt.Sprintf("%02d:%02d:%02d,%03d",
		ms/3600000, ms/60000%60, ms/1000%60, ms%1000)
}

// vttStamp renders seconds as HH:MM:SS.mmm.
func vttStamp(t float64) string {
	ms := int64(math.Round(t * 1000))
	if ms < 0 {
		ms = 0
	}
	return fmt.Sprintf("%02d:%02d:%02d.%03d",
		ms/3600000, ms/60000%60, ms/1000%60, ms%1000)
}

func toSRT(segs []stt.Segment) string {
	var b strings.Builder
	for i, s := range segs {
		fmt.Fprintf(&b, "%d\n%s --> %s\n%s\n\n", i+1, srtStamp(s.S), srtStamp(s.E), s.Text)
	}
	return b.String()
}

func toVTT(segs []stt.Segment) string {
	var b strings.Builder
	b.WriteString("WEBVTT\n\n")
	for _, s := range segs {
		fmt.Fprintf(&b, "%s --> %s\n%s\n\n", vttStamp(s.S), vttStamp(s.E), s.Text)
	}
	return b.String()
}

type transcribeToolIn struct {
	AudioPath string `json:"audio_path" jsonschema:"Absolute path to the audio file (any format ffmpeg reads; converted to 16 kHz mono WAV)"`
	Engine    string `json:"engine,omitempty" jsonschema:"parakeet (default) | whisper"`
	Language  string `json:"language,omitempty" jsonschema:"Language hint for whisper (e.g. en, ru); parakeet auto-detects and ignores this"`
	Prompt    string `json:"prompt,omitempty" jsonschema:"Initial prompt for whisper; ignored by parakeet"`
	Words     bool   `json:"words,omitempty" jsonschema:"Include per-word timings in the result"`
	OutPath   string `json:"out_path,omitempty" jsonschema:"Absolute .json path for the full result; parent must exist; an existing file is refused"`
}

type transcribeToolOut struct {
	Text      string     `json:"text"`
	Language  *string    `json:"language,omitempty"`
	DurationS float64    `json:"duration_s"`
	ElapsedS  float64    `json:"elapsed_s"`
	Engine    string     `json:"engine"`
	Path      string     `json:"path,omitempty"`
	Words     []stt.Word `json:"words,omitempty"`
}

func (d *Daemon) toolTranscribe(ctx context.Context, _ *mcp.CallToolRequest, in transcribeToolIn) (*mcp.CallToolResult, transcribeToolOut, error) {
	if in.AudioPath == "" {
		return nil, transcribeToolOut{}, fmt.Errorf("audio_path is required")
	}
	if in.OutPath != "" {
		if err := validateOutPath(in.OutPath, []string{".json"}, false); err != nil {
			return nil, transcribeToolOut{}, err
		}
	}
	res, err := d.Transcribe(ctx, TranscribeInput{
		AudioPath: in.AudioPath,
		Engine:    in.Engine,
		Language:  in.Language,
		Prompt:    in.Prompt,
	})
	if err != nil {
		return nil, transcribeToolOut{}, err
	}
	if in.OutPath != "" {
		raw, err := json.Marshal(res)
		if err != nil {
			return nil, transcribeToolOut{}, err
		}
		if err := writeFile(in.OutPath, raw, false); err != nil {
			// the transcription itself succeeded: do not lose it
			return nil, transcribeToolOut{}, fmt.Errorf("transcript not saved to %s (%v); text: %s", in.OutPath, err, res.Text)
		}
	}
	out := transcribeToolOut{
		Text:      res.Text,
		Language:  res.Language,
		DurationS: res.DurationS,
		ElapsedS:  res.ElapsedS,
		Engine:    res.Engine,
		Path:      in.OutPath,
	}
	if in.Words {
		out.Words = res.Words
	}
	return nil, out, nil
}
