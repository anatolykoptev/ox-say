package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"strings"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/voices"
)

// Routes registers the daemon's HTTP API on mux — mounted by go-mcpserver's
// Config.Routes next to /mcp and /health.
func (d *Daemon) Routes(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/audio/speech", d.handleSpeech)
	mux.HandleFunc("POST /v1/audio/transcriptions", d.handleTranscribe)
	// Streaming transcription sessions on the resident ox-stt server.
	mux.HandleFunc("POST /v1/audio/transcriptions/sessions", d.handleSTTSessionCreate)
	mux.HandleFunc("POST /v1/audio/transcriptions/sessions/{id}/audio", d.handleSTTSessionAudio)
	mux.HandleFunc("POST /v1/audio/transcriptions/sessions/{id}/finish", d.handleSTTSessionFinish)
	mux.HandleFunc("DELETE /v1/audio/transcriptions/sessions/{id}", d.handleSTTSessionDelete)
	mux.HandleFunc("GET /v1/audio/voices", d.handleListVoices)
	mux.HandleFunc("POST /v1/audio/voices", d.handleAddVoice)
	mux.HandleFunc("GET /v1/audio/voices/{name}", d.handleGetVoice)
	mux.HandleFunc("DELETE /v1/audio/voices/{name}", d.handleDeleteVoice)
	mux.HandleFunc("GET /status", d.handleStatus)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]any{"message": msg, "type": http.StatusText(status)},
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// handleSpeech is OpenAI-compatible /v1/audio/speech. wav and pcm stream
// straight through; mp3 and opus are transcoded from the child's wav via
// ffmpeg (opus in an OGG container — Telegram voice notes).
func (d *Daemon) handleSpeech(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	dec.UseNumber() // keep e.g. seed's int64 precision when proxying upstream
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
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
	d.applyLanguageDefault(body)

	base, g, err := d.engineBase(r.Context())
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, fmt.Sprintf("engine failed to start: %v", err))
		return
	}
	defer g.Release()

	upstream := body
	if format == "mp3" || format == "opus" {
		upstream = maps(body)
		upstream["response_format"] = "wav"
	}
	raw, err := json.Marshal(upstream)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	resp, err := d.ec.Speech(r.Context(), base, raw)
	if err != nil {
		writeErr(w, http.StatusBadGateway, fmt.Sprintf("engine speech: %v", err))
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
		if ct := resp.Header.Get("Content-Type"); ct != "" {
			w.Header().Set("Content-Type", ct)
		}
		w.WriteHeader(resp.StatusCode)
		_, _ = w.Write(msg)
		return
	}

	switch format {
	case "mp3", "opus":
		wav, err := readAllCap(resp.Body, 256<<20)
		if err != nil {
			writeErr(w, http.StatusBadGateway, fmt.Sprintf("engine speech: %v", err))
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
		_, _ = io.Copy(w, resp.Body)
	}
}

// transcode converts wav bytes to mp3 or ogg-opus via ffmpeg.
func transcode(ctx context.Context, wav []byte, format string) ([]byte, error) {
	args := []string{"-hide_banner", "-loglevel", "error", "-f", "wav", "-i", "pipe:0"}
	switch format {
	case "mp3":
		args = append(args, "-f", "mp3", "-c:a", "libmp3lame", "pipe:1")
	case "opus":
		args = append(args, "-f", "ogg", "-c:a", "libopus", "pipe:1")
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
	v, registered, err := d.AddVoice(r.Context(), req.Name, req.AudioPath, req.RefText)
	if err != nil {
		status := http.StatusInternalServerError
		var iErr *voices.InputError
		if errors.As(err, &iErr) {
			// Bad name, relative path, unreadable/undecodable clip:
			// client input, not a daemon fault.
			status = http.StatusBadRequest
		}
		writeErr(w, status, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"name":                 v.Name,
		"status":               "registered",
		"registered_to_engine": registered,
	})
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
