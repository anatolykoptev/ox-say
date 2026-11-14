package daemon

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/glossary"
)

// msgLog counts records by message.
type msgLog struct {
	mu   sync.Mutex
	msgs []string
}

func (h *msgLog) Enabled(context.Context, slog.Level) bool { return true }
func (h *msgLog) Handle(_ context.Context, r slog.Record) error {
	h.mu.Lock()
	h.msgs = append(h.msgs, r.Message)
	h.mu.Unlock()
	return nil
}
func (h *msgLog) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h *msgLog) WithGroup(string) slog.Handler      { return h }
func (h *msgLog) count(m string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	n := 0
	for _, x := range h.msgs {
		if x == m {
			n++
		}
	}
	return n
}

// Mutation: http.go Routes, delete the `d.glossaryRoutes(mux)` line -> RED (404 on every call).
func TestGlossaryRoutes(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)

	rec := call(t, mux, http.MethodPost, "/v1/glossary", `{"heard":"Воксей","meant":"OxSay","context":"сделай Воксей релиз"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("add: %d %s", rec.Code, rec.Body)
	}
	var p glossary.Pair
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil || p.Status != glossary.Candidate {
		t.Fatalf("add body %s (%v)", rec.Body, err)
	}
	if rec := call(t, mux, http.MethodPost, "/v1/glossary/"+p.ID+"/approve", "{}"); rec.Code != http.StatusOK {
		t.Fatalf("approve: %d %s", rec.Code, rec.Body)
	}
	if got := d.corrector()("открой Воксей"); got != "открой OxSay" {
		t.Fatalf("corrector = %q", got)
	}
	if rec := call(t, mux, http.MethodPost, "/v1/glossary/"+p.ID+"/reject", "{}"); rec.Code != http.StatusOK {
		t.Fatalf("reject: %d", rec.Code)
	}
	rec = call(t, mux, http.MethodGet, "/v1/glossary", "")
	var list struct{ Pairs []glossary.Pair }
	if json.Unmarshal(rec.Body.Bytes(), &list) != nil || len(list.Pairs) != 1 || list.Pairs[0].Status != glossary.Rejected {
		t.Fatalf("list: %d %s", rec.Code, rec.Body)
	}
	for _, c := range []struct {
		method, path, body string
		code               int
	}{
		{http.MethodPost, "/v1/glossary", `{"heard":"","meant":"x"}`, http.StatusBadRequest},
		{http.MethodPost, "/v1/glossary", `{"heard":"a","meant":"b","source":"owner"}`, http.StatusBadRequest},
		{http.MethodPost, "/v1/glossary/ffffffff/approve", "{}", http.StatusNotFound},
	} {
		if rec := call(t, mux, c.method, c.path, c.body); rec.Code != c.code {
			t.Errorf("%s %s %s = %d, want %d", c.method, c.path, c.body, rec.Code, c.code)
		}
	}
	call(t, mux, http.MethodPost, "/v1/glossary", `{"heard":"окс сей","meant":"OxSay"}`)
	if rec := call(t, mux, http.MethodPost, "/v1/glossary", `{"heard":"окс сей","meant":"OxPulse"}`); rec.Code != http.StatusConflict {
		t.Fatalf("conflict = %d", rec.Code)
	}
}

// A broken glossary costs the corrections, never the text, and warns once per job, not once per line.
// Mutation: glossary_http.go corrector, call d.glossaryPairs() inside the returned closure -> RED (3 warnings).
func TestCorrectorLoadsOnceAndFailsOpen(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	h := &msgLog{}
	d.log = slog.New(h)
	if err := os.WriteFile(filepath.Join(d.Cfg.Home, glossary.FileName), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	fix := d.corrector()
	for _, s := range []string{"открой Воксей", "два", "три"} {
		if got := fix(s); got != s {
			t.Fatalf("fix(%q) = %q", s, got)
		}
	}
	if n := h.count("glossary: not applied"); n != 1 {
		t.Fatalf("warnings = %d, want 1", n)
	}
}
