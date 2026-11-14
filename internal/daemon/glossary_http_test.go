package daemon

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
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

// callWith is call plus request headers.
func callWith(t *testing.T, mux http.Handler, method, path, body string, hdr map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

// ownerAuth reads the bearer the daemon wrote at $OX_SAY_HOME/owner.token —
// the file, not the field, so the test checks what a real client sends.
func ownerAuth(t *testing.T, d *Daemon) map[string]string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(d.Cfg.Home, OwnerTokenFile))
	if err != nil {
		t.Fatal(err)
	}
	return map[string]string{"Authorization": "Bearer " + strings.TrimSpace(string(raw))}
}

// Mutation: http.go Routes, delete the `d.glossaryRoutes(mux)` line -> RED (404 on every call).
func TestGlossaryRoutes(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	auth := ownerAuth(t, d)

	rec := call(t, mux, http.MethodPost, "/v1/glossary", `{"heard":"Воксей","meant":"OxSay","context":"сделай Воксей релиз"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("add: %d %s", rec.Code, rec.Body)
	}
	var p glossary.Pair
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil || p.Status != glossary.Candidate {
		t.Fatalf("add body %s (%v)", rec.Body, err)
	}
	if rec := callWith(t, mux, http.MethodPost, "/v1/glossary/"+p.ID+"/approve", "{}", auth); rec.Code != http.StatusOK {
		t.Fatalf("approve: %d %s", rec.Code, rec.Body)
	}
	if got := d.corrector()("открой Воксей"); got != "открой OxSay" {
		t.Fatalf("corrector = %q", got)
	}
	if rec := callWith(t, mux, http.MethodPost, "/v1/glossary/"+p.ID+"/reject", "{}", auth); rec.Code != http.StatusOK {
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
		{http.MethodPost, "/v1/glossary", `{"heard":"x","meant":"a\nb"}`, http.StatusBadRequest},
		{http.MethodPost, "/v1/glossary", `{"heard":"x","meant":"a;b"}`, http.StatusBadRequest},
		{http.MethodPost, "/v1/glossary", `{"heard":"x","meant":"one two three four five"}`, http.StatusBadRequest},
		{http.MethodPost, "/v1/glossary", `{"heard":"node.js","meant":"Node.js"}`, http.StatusBadRequest},
	} {
		if rec := call(t, mux, c.method, c.path, c.body); rec.Code != c.code {
			t.Errorf("%s %s %s = %d, want %d", c.method, c.path, c.body, rec.Code, c.code)
		}
	}
	if rec := callWith(t, mux, http.MethodPost, "/v1/glossary/ffffffff/approve", "{}", auth); rec.Code != http.StatusNotFound {
		t.Errorf("approve unknown id = %d, want 404", rec.Code)
	}
	call(t, mux, http.MethodPost, "/v1/glossary", `{"heard":"окс сей","meant":"OxSay"}`)
	if rec := call(t, mux, http.MethodPost, "/v1/glossary", `{"heard":"окс сей","meant":"OxPulse"}`); rec.Code != http.StatusConflict {
		t.Fatalf("conflict = %d", rec.Code)
	}
}

// Approving or rejecting is the owner's call, made at a terminal: the routes
// answer 403 without the bearer the daemon wrote at $OX_SAY_HOME/owner.token
// (created once, 32 bytes hex, mode 0600), while list and add stay open —
// an agent files candidates, it never settles them.
// Mutation: glossary_http.go handleGlossaryStatus, delete the ownerOK check -> RED.
func TestGlossaryStatusIsOwnerOnly(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)

	st, err := os.Stat(filepath.Join(d.Cfg.Home, OwnerTokenFile))
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("owner.token: stat %v err %v; want mode 0600", st, err)
	}
	raw, err := os.ReadFile(filepath.Join(d.Cfg.Home, OwnerTokenFile))
	if err != nil || len(strings.TrimSpace(string(raw))) != 64 {
		t.Fatalf("owner.token = %q, want 64 hex chars", raw)
	}

	rec := call(t, mux, http.MethodPost, "/v1/glossary", `{"heard":"Воксей","meant":"OxSay"}`)
	var p glossary.Pair
	if rec.Code != http.StatusOK || json.Unmarshal(rec.Body.Bytes(), &p) != nil {
		t.Fatalf("add stays open to agents: %d %s", rec.Code, rec.Body)
	}

	for _, bad := range []map[string]string{
		nil,
		{"Authorization": "Bearer 0000000000000000000000000000000000000000000000000000000000000000"},
		{"Authorization": "Basic dGVzdA=="},
	} {
		for _, verb := range []string{"approve", "reject"} {
			if rec := callWith(t, mux, http.MethodPost, "/v1/glossary/"+p.ID+"/"+verb, "{}", bad); rec.Code != http.StatusForbidden {
				t.Fatalf("%s with Authorization %q: %d, want 403", verb, bad["Authorization"], rec.Code)
			}
		}
	}
	if got, _ := d.Glossary.List(); len(got) != 1 || got[0].Status != glossary.Candidate {
		t.Fatalf("a refused call changed the pair: %+v", got)
	}

	auth := ownerAuth(t, d)
	if rec := callWith(t, mux, http.MethodPost, "/v1/glossary/"+p.ID+"/approve", "{}", auth); rec.Code != http.StatusOK {
		t.Fatalf("owner approve: %d %s", rec.Code, rec.Body)
	}
	if rec := callWith(t, mux, http.MethodPost, "/v1/glossary/"+p.ID+"/reject", "{}", auth); rec.Code != http.StatusOK {
		t.Fatalf("owner reject: %d %s", rec.Code, rec.Body)
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

// glossaryPairs caches the active pairs by the file's mtime+size: the
// per-chunk path stats one small file instead of parsing it, and a change is
// picked up the next call.
// Mutation: glossary_http.go glossaryPairs, drop the `k == d.glKey` return -> RED (two loads).
func TestGlossaryPairsCachesByFileState(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)

	loads := 0
	inner := d.Glossary.Active
	d.activePairs = func() ([]glossary.Pair, error) { loads++; return inner() }

	d.glossaryPairs()
	d.glossaryPairs()
	if loads != 1 {
		t.Fatalf("loads = %d, want 1 for an unchanged file", loads)
	}
	p, err := d.Glossary.Add("sentinel", "guardian", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Glossary.Approve(p.ID); err != nil {
		t.Fatal(err)
	}
	got := d.glossaryPairs()
	if loads != 2 || len(got) != 1 || got[0].Meant != "guardian" {
		t.Fatalf("after a change: loads = %d pairs = %+v", loads, got)
	}
}

// A malformed glossary warns once per distinct file state — the state is the
// mtime+size pair — then stays quiet until the file changes; corrections
// still fail open.
func TestGlossaryPairsWarnsOncePerState(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	h := &msgLog{}
	d.log = slog.New(h)
	path := filepath.Join(d.Cfg.Home, glossary.FileName)
	if err := os.WriteFile(path, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	d.glossaryPairs()
	d.glossaryPairs()
	if n := h.count("glossary: not applied"); n != 1 {
		t.Fatalf("warnings = %d, want 1 per state", n)
	}
	if err := os.WriteFile(path, []byte("{ still broken"), 0o600); err != nil {
		t.Fatal(err)
	}
	d.glossaryPairs()
	if n := h.count("glossary: not applied"); n != 2 {
		t.Fatalf("warnings = %d, want 2 for a new state", n)
	}
	if err := os.WriteFile(path, []byte(`{"version":1,"pairs":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	d.glossaryPairs()
	if n := h.count("glossary: not applied"); n != 2 {
		t.Fatalf("warnings = %d, want 2 after the fix", n)
	}
}
