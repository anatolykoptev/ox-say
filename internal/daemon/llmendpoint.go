package daemon

// The opt-in OpenAI-compatible surface that serves the already-resident notes
// model to other local apps (issue #537). Two routes ride the daemon's
// loopback listener: GET /v1/models (shared with the app's internal catalog —
// a request carrying an Authorization header is an OpenAI client's and is
// dispatched here) and POST /v1/chat/completions (a raw passthrough to the
// notes child's own OpenAI surface).
//
// Access: a per-install bearer, separate from owner.token and from the notes
// child's own per-spawn notes.key, stored 0600 under the run dir and compared
// in constant time. The daemon writes it itself, so the file — not the app —
// is the source of truth (no Keychain; the daemon must read it with no app
// running, and the app reads the same file for display).
//
// Scheduling: a request runs the same admission a meeting's notes call runs —
// the dictation yield (waitQuiet), the own-model trial wait and the residency
// turn, the stale-child recycle, makeNotesRoom, the guard and EnsureReady —
// but every wait is bounded, and the refusal is a 503 with Retry-After, never
// a hang: dictation and a running meeting always keep priority. Once admitted
// it takes notesReqSlot, the daemon's stand-in for the child's -np 1 single
// decode slot, which meeting notes calls also take: one request at a time
// reaches the model, whichever side asked.

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/vproject"
)

const (
	// llmEndpointKeyFile is the per-install bearer file under cfg.RunDir(),
	// written 0600. Not notes.key: that one is rewritten per spawn, while
	// this key must survive child restarts and daemon restarts unchanged
	// until the user regenerates it.
	llmEndpointKeyFile = "llm-endpoint.key"
	// llmMaxBodyBytes caps one chat-completions request body. Agent prompts
	// are large; 64 MiB keeps a misbehaving client from filling memory while
	// passing anything a coding agent sends.
	llmMaxBodyBytes = 64 << 20
	// llmEndpointPath is the URL path both endpoint routes share.
	llmEndpointPath = "/v1/chat/completions"
)

var (
	// llmWaitBudget bounds the queue-side waits of an endpoint request:
	// the dictation yield, the own-model trial's hold and the notes engine's
	// residency turn. A request that cannot be admitted inside it is refused
	// (503 + Retry-After) rather than queued behind voice work — a var so
	// tests can shorten it.
	llmWaitBudget = 30 * time.Second
	// llmSlotBudget bounds the wait for the notes child's single request
	// slot while a meeting's notes call or another endpoint request is in
	// flight.
	llmSlotBudget = 15 * time.Second
	// llmRetryAfterS is the Retry-After value every bounded refusal carries.
	llmRetryAfterS = "30"
)

// llmRoutes registers the OpenAI surface and the key management route.
// /v1/models is NOT registered here: it already exists (modelRoutes) and
// dispatches on the Authorization header.
func (d *Daemon) llmRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST "+llmEndpointPath, d.handleLLMChat)
	mux.HandleFunc("POST /v1/meetings/llm-endpoint/key", d.handleLLMKeyRegenerate)
}

// llmEndpointOn is the effective llm_endpoint setting. A settings file that
// cannot be read answers the default — off — so the feature fails closed.
func (d *Daemon) llmEndpointOn() bool {
	if d.Meet == nil || d.Meet.Store == nil {
		return false
	}
	return d.Meet.Store.Settings().LLMEndpointEnabled()
}

// llmEndpointURL is the base URL the app and /status report: the daemon's own
// loopback address plus the OpenAI surface's prefix.
func (d *Daemon) llmEndpointURL() string {
	return "http://" + d.Cfg.Addr + "/v1"
}

// llmKey returns the per-install endpoint bearer, creating the file on first
// use — loaded once at daemon start into d.llmKey.
func llmEndpointKey(home string, log *slog.Logger) string {
	path := filepath.Join(home, llmEndpointKeyFile)
	if raw, err := os.ReadFile(path); err == nil {
		key := strings.TrimSuffix(string(raw), "\n")
		if validOwnerToken(key) {
			if st, err := os.Stat(path); err != nil || st.Mode().Perm()&0o077 != 0 {
				if err := os.Chmod(path, 0o600); err != nil {
					log.Warn("llm endpoint: the key file mode could not be tightened; a new one is generated", slog.Any("error", err))
					return writeLLMKey(path, log)
				}
			}
			return key
		}
		log.Warn("llm endpoint: the key file is not valid; a new one is generated")
	}
	return writeLLMKey(path, log)
}

// writeLLMKey stores a fresh endpoint bearer atomically at mode 0600. Any
// failure returns "": empty fails closed in llmKeyOK.
func writeLLMKey(path string, log *slog.Logger) string {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		log.Warn("llm endpoint: the key could not be generated; the endpoint stays closed", slog.Any("error", err))
		return ""
	}
	key := hex.EncodeToString(b[:])
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		log.Warn("llm endpoint: the key could not be written; the endpoint stays closed", slog.Any("error", err))
		return ""
	}
	if err := vproject.WriteAtomic(path, []byte(key+"\n"), 0o600); err != nil {
		log.Warn("llm endpoint: the key could not be written; the endpoint stays closed", slog.Any("error", err))
		return ""
	}
	return key
}

// llmKeyOK reports whether the request carries the endpoint bearer, compared
// in constant time. It never logs the presented value.
func (d *Daemon) llmKeyOK(r *http.Request) bool {
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	return ok && d.llmKey != "" && subtle.ConstantTimeCompare([]byte(tok), []byte(d.llmKey)) == 1
}

// llmAbsent answers as an unregistered route would: the feature off is the
// feature absent — no 401 to hint it exists.
func llmAbsent(w http.ResponseWriter, r *http.Request) {
	http.NotFound(w, r)
}

// handleLLMModels answers the OpenAI GET /v1/models: exactly one model whose
// id is the selected notes model's id. It is reached only for requests that
// carry an Authorization header — bearer-less calls keep the app's internal
// catalog (see handleModelsList).
func (d *Daemon) handleLLMModels(w http.ResponseWriter, r *http.Request) {
	if !d.llmEndpointOn() {
		llmAbsent(w, r)
		return
	}
	if !d.llmKeyOK(r) {
		writeErr(w, http.StatusUnauthorized, "a valid bearer key is required")
		return
	}
	id := d.notesSelectedID()
	writeJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"data": []map[string]any{{
			"id": id, "object": "model", "created": 0, "owned_by": "ox-say",
		}},
	})
}

// notesSelectedID is the id external clients name the notes model by: the
// catalog id of the resolved model, or "custom" for an own GGUF.
func (d *Daemon) notesSelectedID() string {
	res := d.notesResolve()
	if res.Entry != nil {
		return res.Entry.ID
	}
	return config.NotesCustomID
}

// handleLLMChat is POST /v1/chat/completions: the request body is proxied to
// the notes child unchanged (tools, tool_choice, chat_template_kwargs,
// reasoning_effort, sampling fields all reach llama-server), the answer is
// streamed back as it arrives, and a client cancel cancels the upstream
// request through the request context. Bodies are never logged.
func (d *Daemon) handleLLMChat(w http.ResponseWriter, r *http.Request) {
	if !d.llmEndpointOn() {
		llmAbsent(w, r)
		return
	}
	if !d.llmKeyOK(r) {
		writeErr(w, http.StatusUnauthorized, "a valid bearer key is required")
		return
	}
	body, err := readAllCap(r.Body, llmMaxBodyBytes)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	base, release, err := d.llmAdmit(r.Context())
	if err != nil {
		d.writeLLMRefusal(w, err)
		return
	}
	defer release()
	d.llmProxy(w, r, base, body)
}

// llmAdmit runs the endpoint request through the notes call's own admission:
// the dictation yield, the trial hold and the residency turn under the wait
// budget, the stale-child recycle and room check, the guard, EnsureReady (a
// cold start may take the whole startup timeout), and finally the single
// request slot under its own budget. The release unwinds slot + guard + turn.
func (d *Daemon) llmAdmit(ctx context.Context) (string, func(), error) {
	if d.LLMSup == nil {
		return "", nil, errors.New("the notes engine is not configured")
	}
	wctx, cancel := context.WithTimeout(ctx, llmWaitBudget)
	defer cancel()
	if err := d.waitQuiet(wctx, func() {}); err != nil {
		return "", nil, err
	}
	leave, err := d.llmEndpointTurn(wctx)
	if err != nil {
		return "", nil, err
	}
	release := func() { leave() }
	if err := d.notesStaleChild(wctx); err != nil {
		release()
		return "", nil, err
	}
	d.makeNotesRoom(ctx)
	g := d.LLMSup.Acquire()
	base, err := d.llmEnsureReady(ctx)
	if err != nil {
		g.Release()
		release()
		return "", nil, err
	}
	if err := d.takeNotesSlot(wctx); err != nil {
		g.Release()
		release()
		return "", nil, err
	}
	return base, func() { <-d.notesReqSlot; g.Release(); leave() }, nil
}

// llmEndpointTurn is notesEngineTurn for the endpoint: the same own-model
// trial hold and residency turn, bounded so a busy Mac answers 503 instead
// of queueing an external client behind voice work.
func (d *Daemon) llmEndpointTurn(ctx context.Context) (func(), error) {
	if err := d.waitNotesTrial(ctx); err != nil {
		return nil, err
	}
	return d.mem.enter(ctx, d.LLMSup, llmWaitBudget)
}

// llmEnsureReady is EnsureReady plus the OOM ladder llmChat.Complete climbs:
// a start that left an out-of-memory line retries with a raised fit margin.
func (d *Daemon) llmEnsureReady(ctx context.Context) (string, error) {
	mark := notesLogMark(d.Cfg.EngineLogDir)
	base, err := d.LLMSup.EnsureReady(ctx)
	for err != nil && ctx.Err() == nil && d.notesStartOOMed(mark) && d.notesEscalate() {
		mark = notesLogMark(d.Cfg.EngineLogDir)
		base, err = d.LLMSup.EnsureReady(ctx)
	}
	if err == nil {
		d.recordNotesOffload(mark)
	}
	return base, err
}

// takeNotesSlot claims the notes child's single decode slot (-np 1), held by
// a meeting's notes call or another endpoint request; the wait is bounded.
func (d *Daemon) takeNotesSlot(ctx context.Context) error {
	select {
	case d.notesReqSlot <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// writeLLMRefusal answers an admission failure: bounded-wait expiries are 503
// with Retry-After (dictation has priority; nothing failed), everything else
// is an honest 503 — the client retries either way.
func (d *Daemon) writeLLMRefusal(w http.ResponseWriter, err error) {
	var busy *engineBusyError
	switch {
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &busy):
		w.Header().Set("Retry-After", llmRetryAfterS)
		writeErr(w, http.StatusServiceUnavailable, "the notes model is busy with voice work; retry shortly")
	case errors.Is(err, context.Canceled):
		writeErr(w, http.StatusServiceUnavailable, "the request was canceled while waiting for the notes engine")
	default:
		d.log.Warn("llm endpoint: the notes engine could not be started", slog.Any("error", err))
		w.Header().Set("Retry-After", llmRetryAfterS)
		writeErr(w, http.StatusServiceUnavailable, "the notes model could not be started; retry shortly")
	}
}

// llmProxy forwards body to the notes child's own /v1/chat/completions under
// the child's per-spawn key (never the endpoint key) and streams the answer
// back. A whole stream is never buffered; every chunk is flushed as it
// arrives. The upstream request rides r.Context(), so a client disconnect
// cancels it.
func (d *Daemon) llmProxy(w http.ResponseWriter, r *http.Request, base string, body []byte) {
	uctx, cancel := context.WithTimeout(r.Context(), notesCallTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(uctx, http.MethodPost, base+llmEndpointPath, bytes.NewReader(body))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "cannot build the upstream request")
		return
	}
	if ct := r.Header.Get("Content-Type"); ct != "" {
		req.Header.Set("Content-Type", ct)
	} else {
		req.Header.Set("Content-Type", "application/json")
	}
	key, err := d.notesKey()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "the notes engine key is unreadable")
		return
	}
	req.Header.Set("Authorization", "Bearer "+key)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		if r.Context().Err() == nil {
			d.log.Warn("llm endpoint: the notes engine request failed", slog.Any("error", err))
			writeErr(w, http.StatusBadGateway, "the notes engine could not be reached")
		}
		return
	}
	defer resp.Body.Close()
	for _, h := range []string{"Content-Type", "Cache-Control", "X-Accel-Buffering"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	d.streamLLM(w, resp.Body)
}

// streamLLM copies the upstream body through, flushing after every read so an
// SSE chunk reaches the client as the model emits it rather than at EOF.
func (d *Daemon) streamLLM(w http.ResponseWriter, src io.Reader) {
	fl, _ := w.(http.Flusher)
	buf := make([]byte, 16<<10)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return // the client is gone; the request context ends upstream
			}
			if fl != nil {
				fl.Flush()
			}
		}
		if err != nil {
			return
		}
	}
}

// handleLLMKeyRegenerate is POST /v1/meetings/llm-endpoint/key: writes a fresh
// per-install bearer and answers it once, for the app's Settings pane. The
// old key stops working the moment the file is replaced.
func (d *Daemon) handleLLMKeyRegenerate(w http.ResponseWriter, r *http.Request) {
	key := writeLLMKey(filepath.Join(d.Cfg.RunDir(), llmEndpointKeyFile), d.log)
	if key == "" {
		writeErr(w, http.StatusInternalServerError, "the key could not be written")
		return
	}
	d.llmKey = key
	writeJSON(w, http.StatusOK, map[string]any{"llm_endpoint_key": key})
}

// llmStatus is the /status view of the endpoint: on/off, its URL and the
// context the notes child is actually running with — or the one the next
// spawn would get — for the Settings pane's "shared with meeting notes" line.
type llmStatus struct {
	Enabled bool   `json:"enabled"`
	URL     string `json:"url"`
	Context int    `json:"context"`
}

func (d *Daemon) llmStatus() llmStatus {
	st := llmStatus{Enabled: d.llmEndpointOn(), URL: d.llmEndpointURL()}
	st.Context = d.notesCtxEffective()
	return st
}
