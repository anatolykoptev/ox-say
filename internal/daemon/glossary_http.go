package daemon

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/anatolykoptev/ox-say/internal/glossary"
	"github.com/anatolykoptev/ox-say/internal/stt"
)

func (d *Daemon) initGlossary() { d.Glossary = glossary.NewStore(d.Cfg.Home) }

// glossaryRoutes registers the glossary. None is interactive: filing a pair
// must not make the voiceover producer yield. There is no hard delete: a
// rejected pair stays as a tombstone so agents cannot file it back.
func (d *Daemon) glossaryRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/glossary", d.handleGlossaryList)
	mux.HandleFunc("POST /v1/glossary", d.handleGlossaryAdd)
	mux.HandleFunc("POST /v1/glossary/{id}/approve", d.handleGlossaryStatus(true))
	mux.HandleFunc("POST /v1/glossary/{id}/reject", d.handleGlossaryStatus(false))
}

func glossaryStatus(err error) int {
	switch {
	case errors.Is(err, glossary.ErrInvalid):
		return http.StatusBadRequest
	case errors.Is(err, glossary.ErrConflict):
		return http.StatusConflict
	case errors.Is(err, glossary.ErrNotFound):
		return http.StatusNotFound
	}
	return http.StatusInternalServerError
}

func (d *Daemon) handleGlossaryList(w http.ResponseWriter, r *http.Request) {
	pairs, err := d.Glossary.List()
	if err != nil {
		writeErr(w, glossaryStatus(err), err.Error())
		return
	}
	if pairs == nil {
		pairs = []glossary.Pair{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"pairs": pairs})
}

func (d *Daemon) handleGlossaryAdd(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Heard   string `json:"heard"`
		Meant   string `json:"meant"`
		Context string `json:"context"`
	}
	if err := decodeStrict(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	p, err := d.Glossary.Add(in.Heard, in.Meant, in.Context)
	if err != nil {
		writeErr(w, glossaryStatus(err), err.Error())
		return
	}
	d.log.Info("glossary pair filed", slog.String("id", p.ID), slog.String("status", string(p.Status)), slog.Int("seen", p.Seen))
	writeJSON(w, http.StatusOK, p)
}

func (d *Daemon) handleGlossaryStatus(approve bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		set := d.Glossary.Reject
		if approve {
			set = d.Glossary.Approve
		}
		p, err := set(r.PathValue("id"))
		if err != nil {
			writeErr(w, glossaryStatus(err), err.Error())
			return
		}
		d.log.Info("glossary pair set", slog.String("id", p.ID), slog.String("status", string(p.Status)))
		writeJSON(w, http.StatusOK, p)
	}
}

// glossaryPairs loads the active pairs; any problem means no corrections and
// one Warn line, never a failed recognition.
func (d *Daemon) glossaryPairs() []glossary.Pair {
	if d.Glossary == nil {
		return nil
	}
	pairs, err := d.Glossary.Active()
	if err != nil {
		d.log.Warn("glossary: not applied", slog.Any("error", err))
		return nil
	}
	return pairs
}

// corrector loads the pairs once and returns a text fixer for one job (a
// meeting's turns, a response's lines): a pair filed mid-job waits for the next.
func (d *Daemon) corrector() func(string) string {
	pairs := d.glossaryPairs()
	return func(s string) string {
		out, _ := glossary.Apply(s, pairs)
		return out
	}
}

// correctResult applies the active pairs to a recognised result in place.
func (d *Daemon) correctResult(res *stt.Result, route string) {
	if n := glossary.ApplyResult(res, d.glossaryPairs()); n > 0 {
		d.log.Info("glossary applied", slog.String("route", route), slog.Int("replacements", n))
	}
}

// correctSessionBody applies the active pairs to a streaming session
// response: its "text" and each segment's "text". Every other field is kept;
// the "words" array is left as the recogniser gave it (the app reads only
// "text"). The body passes through unchanged, byte for byte, when nothing was
// replaced or it does not parse.
func (d *Daemon) correctSessionBody(body []byte) []byte {
	pairs := d.glossaryPairs()
	if len(pairs) == 0 {
		return body
	}
	var top map[string]json.RawMessage
	if json.Unmarshal(body, &top) != nil {
		return body
	}
	n := 0
	fix := func(raw json.RawMessage) json.RawMessage {
		var s string
		if json.Unmarshal(raw, &s) != nil {
			return raw
		}
		out, k := glossary.Apply(s, pairs)
		if k == 0 {
			return raw
		}
		b, err := json.Marshal(out)
		if err != nil {
			return raw
		}
		n += k
		return b
	}
	if raw, ok := top["text"]; ok {
		top["text"] = fix(raw)
	}
	if raw, ok := top["segments"]; ok {
		var segs []map[string]json.RawMessage
		if json.Unmarshal(raw, &segs) == nil {
			for _, s := range segs {
				if t, ok := s["text"]; ok {
					s["text"] = fix(t)
				}
			}
			if b, err := json.Marshal(segs); err == nil {
				top["segments"] = b
			}
		}
	}
	if n == 0 {
		return body
	}
	out, err := json.Marshal(top)
	if err != nil {
		return body
	}
	d.log.Info("glossary applied", slog.String("route", "session"), slog.Int("replacements", n))
	return out
}
