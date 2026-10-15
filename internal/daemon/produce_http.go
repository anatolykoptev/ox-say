package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// Every produce GET is side-effect free: the guard (CrossOriginProtection)
// lets safe methods through by design, and a cross-site page cannot read the
// answers without CORS headers. Keep it that way.

const produceBodyLimit = 1 << 20

// produceRequest is POST /v1/produce. Tuning knobs are preset, seed and takes only.
type produceRequest struct {
	Script       string `json:"script"`
	Title        string `json:"title,omitempty"`
	Voice        string `json:"voice,omitempty"`
	Style        string `json:"style,omitempty"`
	Preset       string `json:"preset,omitempty"`
	Seed         *int64 `json:"seed,omitempty"`
	Takes        *int   `json:"takes,omitempty"`
	OutPath      string `json:"out_path,omitempty"`
	Overwrite    bool   `json:"overwrite,omitempty"`
	AllowBattery bool   `json:"allow_battery,omitempty"`
}

type resumeRequest struct {
	AllowBattery bool `json:"allow_battery,omitempty"`
}

type chunkRequest struct {
	Action string `json:"action"`
	Takes  int    `json:"takes,omitempty"`
	Take   string `json:"take,omitempty"`
	Text   string `json:"text,omitempty"`
}

func (d *Daemon) produceRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/produce", d.handleProduceCreate)
	mux.HandleFunc("GET /v1/produce", d.handleProduceList)
	mux.HandleFunc("GET /v1/produce/{id}", d.handleProduceStatus)
	mux.HandleFunc("GET /v1/produce/{id}/chunks/{n}", d.handleProduceChunkDetail)
	mux.HandleFunc("POST /v1/produce/{id}/resume", d.handleProduceResume)
	mux.HandleFunc("POST /v1/produce/{id}/cancel", d.handleProduceCancel)
	mux.HandleFunc("POST /v1/produce/{id}/chunks/{n}", d.handleProduceChunk)
	mux.HandleFunc("DELETE /v1/produce/{id}", d.handleProduceDelete)
}

// decodeStrict decodes a small JSON body, refusing unknown fields (#141.3).
func decodeStrict(r *http.Request, v any) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, produceBodyLimit))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		if errors.Is(err, io.EOF) {
			return nil // an empty body is {}
		}
		return &requestError{"invalid JSON body: " + err.Error()}
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return &requestError{"invalid JSON body: unexpected data after the JSON object"}
	}
	return nil
}

// produceStatusCode maps producer errors; the rest go through synthStatus.
func produceStatusCode(err error) int {
	var be *busyError
	var ce *cancellingError
	switch {
	case errors.As(err, &be), errors.As(err, &ce), errors.Is(err, errNotRunning):
		return http.StatusConflict
	case errors.Is(err, errNoProject):
		return http.StatusNotFound
	case errors.Is(err, errProducerStopped):
		return http.StatusServiceUnavailable
	}
	return synthStatus(err)
}

// writeProduceErr answers err in plain words with no internal path (#154.5);
// the detail goes to the log.
func (d *Daemon) writeProduceErr(w http.ResponseWriter, err error) {
	code := produceStatusCode(err)
	level := slog.LevelDebug
	if code >= http.StatusInternalServerError {
		level = slog.LevelWarn
	}
	d.log.Log(context.Background(), level, "produce request failed", slog.Int("status", code), slog.Any("error", err))
	var be *busyError
	if errors.As(err, &be) {
		writeJSON(w, http.StatusConflict, map[string]any{"error": map[string]any{"message": be.Error(), "type": "Conflict"}, "running_id": be.id})
		return
	}
	writeErr(w, code, d.prod.public(err))
}

func (d *Daemon) handleProduceCreate(w http.ResponseWriter, r *http.Request) {
	var in produceRequest
	if err := decodeStrict(r, &in); err != nil {
		d.writeProduceErr(w, err)
		return
	}
	takes, err := explicitTakes(in.Takes)
	if err != nil {
		d.writeProduceErr(w, err)
		return
	}
	s, err := d.prod.create(produceInput{Script: in.Script, Title: in.Title, Voice: in.Voice, Style: in.Style,
		Preset: in.Preset, OutPath: in.OutPath, Seed: in.Seed, Takes: takes, Overwrite: in.Overwrite, AllowBattery: in.AllowBattery})
	if err != nil {
		d.writeProduceErr(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, s)
}

func (d *Daemon) handleProduceList(w http.ResponseWriter, _ *http.Request) {
	list, err := d.prod.list()
	if err != nil {
		d.writeProduceErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"projects": list})
}

func (d *Daemon) handleProduceStatus(w http.ResponseWriter, r *http.Request) {
	s, err := d.prod.status(r.PathValue("id"))
	if err != nil {
		d.writeProduceErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, s)
}

// explicitTakes turns the optional takes field into the producer's value (0 =
// the preset's): a given 0 or negative number is refused, not read as "default".
func explicitTakes(p *int) (int, error) {
	if p == nil {
		return 0, nil
	}
	if *p < 1 || *p > maxTakesPerChunk {
		return 0, &requestError{fmt.Sprintf("takes must be 1..%d", maxTakesPerChunk)}
	}
	return *p, nil
}

func chunkIndex(r *http.Request) (int, error) {
	n, err := strconv.Atoi(r.PathValue("n"))
	if err != nil || n < 0 {
		return 0, &requestError{"the chunk number must be a whole number, 0 or more"}
	}
	return n, nil
}

func (d *Daemon) handleProduceChunkDetail(w http.ResponseWriter, r *http.Request) {
	n, err := chunkIndex(r)
	if err == nil {
		var out chunkDetailOut
		if out, err = d.prod.chunkDetail(r.PathValue("id"), n); err == nil {
			writeJSON(w, http.StatusOK, out)
			return
		}
	}
	d.writeProduceErr(w, err)
}

func (d *Daemon) handleProduceResume(w http.ResponseWriter, r *http.Request) {
	var in resumeRequest
	if !vproject.ValidID(r.PathValue("id")) {
		d.writeProduceErr(w, errNoProject)
		return
	}
	if err := decodeStrict(r, &in); err != nil {
		d.writeProduceErr(w, err)
		return
	}
	s, err := d.prod.resume(r.PathValue("id"), in.AllowBattery)
	if err != nil {
		d.writeProduceErr(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, s)
}

func (d *Daemon) handleProduceCancel(w http.ResponseWriter, r *http.Request) {
	if err := d.prod.cancel(r.PathValue("id")); err != nil {
		d.writeProduceErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "cancelling"})
}

func (d *Daemon) handleProduceChunk(w http.ResponseWriter, r *http.Request) {
	if !vproject.ValidID(r.PathValue("id")) {
		d.writeProduceErr(w, errNoProject)
		return
	}
	n, err := chunkIndex(r)
	var in chunkRequest
	if err == nil {
		err = decodeStrict(r, &in)
	}
	var s vproject.Summary
	if err == nil {
		s, err = d.prod.chunk(r.PathValue("id"), n, chunkOp(in))
	}
	if err != nil {
		d.writeProduceErr(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, s)
}

func (d *Daemon) handleProduceDelete(w http.ResponseWriter, r *http.Request) {
	if err := d.prod.remove(r.PathValue("id"), r.URL.Query().Get("delete_outputs") == "true"); err != nil {
		d.writeProduceErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "removed"})
}
