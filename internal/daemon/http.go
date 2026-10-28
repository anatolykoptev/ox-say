package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os/exec"
	"strings"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/voices"
)

// Routes registers the daemon's HTTP API on mux — mounted by go-mcpserver's
// Config.Routes next to /mcp and /health.
func (d *Daemon) Routes(mux *http.ServeMux) {
	// Dictation and speak-selection routes are counted in flight so the
	// producer yields to them (D12); every pattern of interactiveRoutes is
	// registered here, and only those.
	interactiveHandlers := map[string]http.HandlerFunc{
		"POST /v1/audio/speech":                              d.handleSpeech,
		"POST /v1/audio/transcriptions":                      d.handleTranscribe,
		"POST /v1/audio/transcriptions/sessions":             d.handleSTTSessionCreate,
		"POST /v1/audio/transcriptions/sessions/{id}/audio":  d.handleSTTSessionAudio,
		"POST /v1/audio/transcriptions/sessions/{id}/finish": d.handleSTTSessionFinish,
		"DELETE /v1/audio/transcriptions/sessions/{id}":      d.handleSTTSessionDelete,
	}
	for _, pattern := range interactiveRoutes {
		mux.HandleFunc(pattern, d.interactive(interactiveHandlers[pattern]))
	}
	mux.HandleFunc("GET /v1/audio/voices", d.handleListVoices)
	mux.HandleFunc("POST /v1/audio/voices", d.handleAddVoice)
	mux.HandleFunc("POST /v1/audio/voices/design", d.handleDesignVoice)
	mux.HandleFunc("POST /v1/audio/voices/design/save", d.handleSaveDesign)
	mux.HandleFunc("GET /v1/audio/voices/{name}", d.handleGetVoice)
	mux.HandleFunc("PATCH /v1/audio/voices/{name}", d.handleUpdateVoice)
	mux.HandleFunc("DELETE /v1/audio/voices/{name}", d.handleDeleteVoice)
	mux.HandleFunc("GET /status", d.handleStatus)
	d.produceRoutes(mux)
	d.meetingRoutes(mux)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]any{"message": msg, "type": http.StatusText(status)},
	})
}

// writeSynthErr is writeErr for a synthesis error; a runaway also carries its
// typed code, which the app reads to show a sentence instead of the raw JSON.
func writeSynthErr(w http.ResponseWriter, err error) {
	var rwe *runawayError
	if errors.As(err, &rwe) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"error": map[string]any{"message": err.Error(), "type": engineRunawayType},
		})
		return
	}
	writeErr(w, synthStatus(err), err.Error())
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// handleSpeech is OpenAI-compatible /v1/audio/speech. wav and pcm stream
// straight through; mp3 and opus are transcoded from the child's wav via
// ffmpeg (opus in an OGG container — Telegram voice notes). The request
// counts under busy.speaking for its whole life — a restart mid-render
// loses the take.
func (d *Daemon) handleSpeech(w http.ResponseWriter, r *http.Request) {
	d.speaking.Add(1)
	defer d.speaking.Add(-1)
	var body map[string]any
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	dec.UseNumber() // keep e.g. seed's int64 precision when proxying upstream
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	// The mark is the daemon's own (applySeedDefault); a client that sends it would turn a pinned seed into one the
	// daemon may swap on a retry.
	delete(body, fieldSeedDefaulted)
	input, _ := body["input"].(string)
	if input == "" {
		writeErr(w, http.StatusBadRequest, `"input" is required`)
		return
	}
	if n := utf8.RuneCountInString(input); n > maxSpeakChars {
		writeErr(w, http.StatusBadRequest, fmt.Sprintf("input is %d chars, max %d", n, maxSpeakChars))
		return
	}
	format, _ := body["response_format"].(string)
	switch format {
	case "", "wav", "pcm", "mp3", "opus":
	default:
		writeErr(w, http.StatusBadRequest, fmt.Sprintf("unsupported response_format %q (want wav|pcm|mp3|opus)", format))
		return
	}
	lufs, err := loudnessTarget(body)
	if err != nil {
		writeErr(w, synthStatus(err), err.Error())
		return
	}
	model, warning, err := d.prepareSpeech(body)
	if err != nil {
		writeErr(w, synthStatus(err), err.Error())
		return
	}
	d.normalizeSpeakText(body)
	spoken, _ := body[fieldInput].(string) // as the engine will get it: numbers may have grown it
	// A normalised take is buffered, whichever engine rendered it. Without a
	// target the qwen path streams through unchanged.
	if model == config.TTSModelVoxCPM2 || lufs != nil || utf8.RuneCountInString(spoken) > qwenChunkChars {
		d.handleSpeechBuffered(w, r, bufferedSpeech{body: body, model: model, format: format, warning: warning, lufs: lufs})
		return
	}
	w.Header().Set("X-Ox-Say-Model", model)
	if warning != "" {
		w.Header().Set("X-Ox-Say-Warning", warning)
	}

	base, g, err := d.engineBase(r.Context())
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, fmt.Sprintf("engine failed to start: %v", err))
		return
	}
	defer g.Release()

	seedDefaulted := popSeedDefaulted(body)
	upstream := body
	if format == "mp3" || format == "opus" {
		upstream = maps(body)
		upstream["response_format"] = "wav"
	}
	var resp *http.Response
	// Decided before the loop: the retry writes a seed into upstream (which is body for wav), and that seed is not
	// the caller's.
	_, fixed := seedFixed(body)
	pinned := fixed && !seedDefaulted
	started := speakNow()
	for attempt := 0; ; attempt++ {
		raw, err := json.Marshal(upstream)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}
		resp, err = d.ec.Speech(r.Context(), base, raw)
		if err != nil {
			writeErr(w, http.StatusBadGateway, d.transportError(r.Context(), err).Error())
			return
		}
		if resp.StatusCode/100 == 2 {
			break
		}
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
		if !isRunaway(msg) {
			_ = resp.Body.Close()
			if ct := resp.Header.Get("Content-Type"); ct != "" {
				w.Header().Set("Content-Type", ct)
			}
			w.WriteHeader(resp.StatusCode)
			_, _ = w.Write(msg)
			return
		}
		_ = resp.Body.Close()
		d.noteRunaway("/v1/audio/speech", utf8.RuneCountInString(input))
		if pinned || attempt > 0 || !retryFits(r.Context(), started, speakNow()) {
			writeSynthErr(w, &runawayError{pinned: pinned, retried: attempt > 0})
			return
		}
		// A seed the daemon filled in (or none): the same text on another seed usually ends.
		upstream[fieldSeed] = randomSeed()
		d.log.Warn("tts runaway: retrying once on a fresh seed", slog.String("route", "/v1/audio/speech"))
	}
	defer resp.Body.Close()

	switch format {
	case "mp3", "opus":
		wav, err := readAllCap(resp.Body, 256<<20)
		if err != nil {
			writeErr(w, http.StatusBadGateway, d.transportError(r.Context(), err).Error())
			return
		}
		out, err := transcode(r.Context(), wav, format)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		w.Header().Set("Content-Type", map[string]string{"mp3": "audio/mpeg", "opus": "audio/ogg"}[format])
		_, _ = w.Write(out)
	default:
		if ct := resp.Header.Get("Content-Type"); ct != "" {
			w.Header().Set("Content-Type", ct)
		}
		if cl := resp.Header.Get("Content-Length"); cl != "" {
			w.Header().Set("Content-Length", cl)
		}
		w.WriteHeader(resp.StatusCode)
		src := &recordingReader{r: resp.Body}
		_, _ = io.Copy(w, src)
		if src.err != nil && r.Context().Err() == nil {
			// The engine failed after the 200 went out (a take that hit its
			// frame budget, or a crash): break the transfer, never let a cut
			// audio end like a finished one.
			d.streamAborts.Add(1)
			d.log.Warn("tts stream cut by the engine after it started", slog.Any("error", src.err), slog.Int("chars", utf8.RuneCountInString(input)))
			abortResponse(w)
		}
	}
}

// speechContentTypes are the buffered path's response types.
var speechContentTypes = map[string]string{
	"": "audio/wav", "wav": "audio/wav", "mp3": "audio/mpeg", "opus": "audio/ogg", "pcm": "audio/pcm",
}

// bufferedSpeech is a prepared speech request answered from a finished take.
type bufferedSpeech struct {
	body    map[string]any // already prepared: no defaults are applied again
	model   string
	format  string
	warning string
	lufs    *float64 // nil = leave the level alone
}

// handleSpeechBuffered renders the whole take first (voxcpm2, or any engine
// when a loudness target was asked for), normalises it, then encodes it. pcm
// stays OpenAI's 24 kHz s16le.
func (d *Daemon) handleSpeechBuffered(w http.ResponseWriter, r *http.Request, req bufferedSpeech) {
	format := req.format
	if format == "" && req.model == config.TTSModelQwen {
		// qwen's own default is raw pcm; asking for a level must not change
		// the format. (voxcpm2 has always answered wav.)
		format = "pcm"
	}
	out, err := d.synthesize(r.Context(), req.body, req.model)
	if err != nil {
		writeSynthErr(w, err)
		return
	}
	out.addWarning(req.warning)
	d.normalizeTake(r.Context(), out, req.lufs)
	audio := out.WAV
	if format != "" && format != "wav" {
		if audio, err = transcode(r.Context(), out.WAV, format); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	out.setHeaders(w.Header())
	w.Header().Set("Content-Type", speechContentTypes[format])
	if _, err := w.Write(audio); err != nil {
		d.log.Warn("speech response write failed", slog.Any("error", err))
	}
}

// pcmSampleRate is OpenAI's pcm response rate.
const pcmSampleRate = "24000"

// transcode converts wav bytes to mp3, ogg-opus or raw pcm via ffmpeg.
func transcode(ctx context.Context, wav []byte, format string) ([]byte, error) {
	args := []string{"-hide_banner", "-loglevel", "error", "-f", "wav", "-i", "pipe:0"}
	switch format {
	case "mp3":
		args = append(args, "-f", "mp3", "-c:a", "libmp3lame", "pipe:1")
	case "opus":
		args = append(args, "-f", "ogg", "-c:a", "libopus", "pipe:1")
	case "pcm":
		args = append(args, "-f", "s16le", "-ac", "1", "-ar", pcmSampleRate, "-c:a", "pcm_s16le", "pipe:1")
	default:
		return nil, fmt.Errorf("unsupported transcode format %q", format)
	}
	cmd := exec.CommandContext(ctx, "ffmpeg", args...)
	cmd.Stdin = bytes.NewReader(wav)
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("ffmpeg %s transcode: %w: %s", format, err, strings.TrimSpace(errb.String()))
	}
	return out.Bytes(), nil
}

// readAllCap reads up to limit bytes and fails instead of silently
// truncating when the body exceeds it.
func readAllCap(r io.Reader, limit int64) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, fmt.Errorf("body exceeds %d bytes", limit)
	}
	return b, nil
}

// maps returns a shallow copy of a JSON object.
func maps(m map[string]any) map[string]any {
	out := make(map[string]any, len(m)+1)
	for k, v := range m {
		out[k] = v
	}
	return out
}

type addVoiceRequest struct {
	Name      string `json:"name"`
	AudioPath string `json:"audio_path"`
	RefText   string `json:"ref_text"`
	// Engine, Style and DesignedFrom are optional. A client may set
	// designed_from, as the additions-only contract keeps accepting it. The
	// design save route (POST /v1/audio/voices/design/save) does not use it:
	// it records the description from the daemon's own note of the take.
	// A label sent here is not a trust boundary.
	Engine       string `json:"engine"`
	Style        string `json:"style"`
	DesignedFrom string `json:"designed_from"`
}

func (d *Daemon) handleAddVoice(w http.ResponseWriter, r *http.Request) {
	var req addVoiceRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.Name == "" || req.AudioPath == "" {
		writeErr(w, http.StatusBadRequest, `"name" and "audio_path" are required`)
		return
	}
	v, registered, err := d.AddVoiceMeta(r.Context(), req.Name, req.AudioPath, req.RefText,
		voices.Meta{Engine: req.Engine, Style: req.Style, DesignedFrom: req.DesignedFrom})
	if err != nil {
		// Bad name, relative path, unreadable/undecodable clip, bad metadata:
		// client input (400), not a daemon fault.
		writeErr(w, synthStatus(err), err.Error())
		return
	}
	resp := map[string]any{
		"name":                 v.Name,
		"status":               "registered",
		"registered_to_engine": registered,
	}
	if v.Notice != "" {
		resp["notice"] = v.Notice
	}
	writeJSON(w, http.StatusOK, resp)
}

type updateVoiceRequest struct {
	Engine *string `json:"engine"`
	Style  *string `json:"style"`
}

func (d *Daemon) handleUpdateVoice(w http.ResponseWriter, r *http.Request) {
	var req updateVoiceRequest
	// Strict: a field this route does not apply (designed_from, a typo) is a
	// 400, not a 200 that changed nothing (#141.3).
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body: only engine and style can be changed")
		return
	}
	v, err := d.UpdateVoice(r.PathValue("name"), req.Engine, req.Style)
	if err != nil {
		writeErr(w, synthStatus(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, v)
}

func (d *Daemon) handleListVoices(w http.ResponseWriter, _ *http.Request) {
	list, err := d.Store.List()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"voices": list})
}

func (d *Daemon) handleGetVoice(w http.ResponseWriter, r *http.Request) {
	v, err := d.Store.Get(r.PathValue("name"))
	if err != nil {
		writeErr(w, http.StatusNotFound, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, v)
}

func (d *Daemon) handleDeleteVoice(w http.ResponseWriter, r *http.Request) {
	err := d.RemoveVoice(r.Context(), r.PathValue("name"))
	if errors.Is(err, voices.ErrNotFound) {
		writeErr(w, http.StatusNotFound, err.Error())
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (d *Daemon) handleStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, d.Status())
}
