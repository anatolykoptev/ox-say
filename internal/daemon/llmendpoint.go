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
// Access to the key itself is owner-only: the settings answer never carries
// it, and reading it, rotating it and turning the endpoint on all need the
// owner bearer (owner.token) the glossary routes already use.
//
// Scheduling: at most llmMaxWaiters+1 endpoint requests are in the daemon at
// once, counted BEFORE a body is read. A request runs the same admission a
// meeting's notes call runs — the dictation yield (waitQuiet), the own-model
// trial wait and the residency turn, the stale-child recycle, makeNotesRoom,
// the guard and EnsureReady — under ONE deadline (llmWaitBudget; a cold
// start's model load is exempt from it, bounded by the engine's startup
// timeout, and the time it takes is added back), and the refusal is a 503
// with Retry-After, never a hang: dictation and a running meeting always keep
// priority. While a meeting notes job is queued or running, a new request is
// refused at once. Once admitted it takes notesReqSlot, the daemon's stand-in
// for the child's -np 1 single decode slot, which meeting notes calls also
// take, ahead of any queued endpoint request: one request at a time reaches
// the model, whichever side asked. One request runs at most
// llm_endpoint_max_s, and a client that stops reading is cut after
// llmWriteDeadline.

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
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
	// passing anything a coding agent sends. With llmMaxWaiters+1 requests
	// admitted at once the bodies in memory stay under 3 x 64 MiB.
	llmMaxBodyBytes = 64 << 20
	// llmEndpointPath is the URL path both endpoint routes share.
	llmEndpointPath = "/v1/chat/completions"
	// llmMaxWaiters is how many requests may queue behind the one running.
	llmMaxWaiters = 2
	// llmStreamBufBytes is the copy buffer of the proxy: one read is one
	// flush, so an SSE chunk reaches the client as the model emits it.
	llmStreamBufBytes = 16 << 10
)

var (
	// llmWaitBudget is the one deadline over the whole admission of an
	// endpoint request: the dictation yield, the own-model trial's hold, the
	// notes engine's residency turn, the stale-child recycle and the slot
	// wait. A request that cannot be admitted inside it is refused (503 +
	// Retry-After) rather than queued behind voice work. The cold start's
	// model load is the one exemption (bounded by the engine's startup
	// timeout; the time it takes is added to the deadline). A var so tests
	// can shorten it.
	llmWaitBudget = 30 * time.Second
	// llmSlotBudget bounds how long a queued request waits for the notes
	// child's single decode slot while a notes call or another endpoint
	// request holds it.
	llmSlotBudget = 20 * time.Second
	// llmWriteDeadline is the per-chunk deadline on writing the answer to the
	// client: a client that stops reading is cut after it, so it cannot hold
	// the decode slot.
	llmWriteDeadline = 30 * time.Second
	// llmBodyReadBudget bounds reading a request body, so a client that
	// trickles its upload cannot hold one of the admission tokens forever.
	llmBodyReadBudget = 2 * time.Minute
	// llmRetryAfterS is the Retry-After value every bounded refusal carries.
	llmRetryAfterS = "30"
)

// llmRoutes registers the OpenAI surface and the key management routes.
// /v1/models is NOT registered here: it already exists (modelRoutes) and
// dispatches on the Authorization header.
func (d *Daemon) llmRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST "+llmEndpointPath, d.handleLLMChat)
	mux.HandleFunc("GET /v1/meetings/llm-endpoint/key", d.handleLLMKeyGet)
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

// llmEndpointKey loads the per-install endpoint bearer, creating the file on
// first use — read once at daemon start into d.llmKey. A file whose mode let
// group or others read it is replaced by a fresh key, not just tightened: a
// copy may already have left.
func llmEndpointKey(home string, log *slog.Logger) string {
	path := filepath.Join(home, llmEndpointKeyFile)
	if raw, err := os.ReadFile(path); err == nil {
		key := strings.TrimSuffix(string(raw), "\n")
		switch st, serr := os.Stat(path); {
		case !validOwnerToken(key):
			log.Warn("llm endpoint: the key file is not valid; a new one is generated")
		case serr != nil || st.Mode().Perm()&0o077 != 0:
			log.Warn("llm endpoint: the key file was readable by other users; its key is replaced")
		default:
			return key
		}
	}
	key, err := writeLLMKey(path)
	if err != nil {
		log.Warn("llm endpoint: the key could not be written; the endpoint stays closed", slog.Any("error", err))
		return ""
	}
	return key
}

// writeLLMKey stores a fresh endpoint bearer atomically at mode 0600 (a new
// inode, so a loose old file's mode never carries over) and returns it.
func writeLLMKey(path string) (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("generate: %w", err)
	}
	key := hex.EncodeToString(b[:])
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	if err := vproject.WriteAtomic(path, []byte(key+"\n"), 0o600); err != nil {
		return "", err
	}
	return key, nil
}

// currentLLMKey is a consistent snapshot of the key the daemon accepts.
func (d *Daemon) currentLLMKey() string {
	d.llmMu.RLock()
	defer d.llmMu.RUnlock()
	return d.llmKey
}

// rotateLLMKey replaces the key. One lock covers the file write and the
// in-memory publish, so two rotations cannot leave the file holding one key
// and the daemon accepting the other; a failed write keeps the old key.
func (d *Daemon) rotateLLMKey() (string, error) {
	d.llmMu.Lock()
	defer d.llmMu.Unlock()
	key, err := writeLLMKey(filepath.Join(d.Cfg.RunDir(), llmEndpointKeyFile))
	if err != nil {
		return "", err
	}
	d.llmKey = key
	return key, nil
}

// llmKeyOK reports whether the request carries the endpoint bearer, compared
// in constant time. It never logs the presented value.
func (d *Daemon) llmKeyOK(r *http.Request) bool {
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	key := d.currentLLMKey()
	return ok && key != "" && subtle.ConstantTimeCompare([]byte(tok), []byte(key)) == 1
}

// requireOwner answers 401 unless the request carries the owner bearer
// (owner.token) — the check the glossary routes use. The endpoint key, its
// rotation and turning the endpoint on sit behind it: a process that can only
// reach the loopback port, not the owner's files, gets nothing.
func (d *Daemon) requireOwner(w http.ResponseWriter, r *http.Request) bool {
	if d.ownerOK(r) {
		return true
	}
	w.Header().Set("WWW-Authenticate", `Bearer realm="ox-say owner"`)
	writeErr(w, http.StatusUnauthorized, "the owner token is required")
	return false
}

// llmAbsent answers as an unregistered route would: the feature off is the
// feature absent — no 401 to hint it exists.
func llmAbsent(w http.ResponseWriter, r *http.Request) {
	http.NotFound(w, r)
}

// writeLLMJSON is writeJSON for the endpoint's routes: an encode or write
// failure is logged (the error only, never the payload, which may hold the
// key) instead of vanishing.
func (d *Daemon) writeLLMJSON(w http.ResponseWriter, status int, v any) {
	raw, err := json.Marshal(v)
	if err != nil {
		d.log.Warn("llm endpoint: the answer could not be encoded", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "the answer could not be encoded")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if _, err := w.Write(append(raw, '\n')); err != nil {
		d.log.Warn("llm endpoint: the answer could not be written", slog.Any("error", err))
	}
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
	d.writeLLMJSON(w, http.StatusOK, map[string]any{
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

// llmEnter takes one of the llmMaxWaiters+1 admission tokens without
// waiting; false means the daemon already holds that many endpoint requests.
// It runs before the body is read, so what is buffered stays bounded.
func (d *Daemon) llmEnter() (leave func(), ok bool) {
	select {
	case d.llmGate <- struct{}{}:
		return func() { <-d.llmGate }, true
	default:
		return nil, false
	}
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
	// Meeting notes come first: while a notes job is queued or running the
	// endpoint takes no new request. A stream already running is left alone.
	if d.notesJobs.Load() > 0 {
		writeLLMBusy(w, "the notes model is writing a meeting's notes; retry shortly")
		return
	}
	leave, ok := d.llmEnter()
	if !ok {
		writeLLMBusy(w, "the notes model already has requests waiting; retry shortly")
		return
	}
	defer leave()
	body, err := d.llmReadBody(w, r)
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

// llmReadBody reads the request body under the size cap and a read deadline.
func (d *Daemon) llmReadBody(w http.ResponseWriter, r *http.Request) ([]byte, error) {
	rc := http.NewResponseController(w)
	if err := rc.SetReadDeadline(time.Now().Add(llmBodyReadBudget)); err == nil {
		defer func() { _ = rc.SetReadDeadline(time.Time{}) }()
	}
	return readAllCap(r.Body, llmMaxBodyBytes)
}

// llmAdmit runs the endpoint request through the notes call's own admission
// under one deadline (llmWaitBudget): the dictation yield, the trial hold and
// the residency turn, the stale-child recycle and room check, the guard,
// EnsureReady (a cold start's model load is exempt: it runs on ctx and its
// duration is added to the deadline), and finally the single request slot.
// The release unwinds slot + guard + turn.
func (d *Daemon) llmAdmit(ctx context.Context) (string, func(), error) {
	if d.LLMSup == nil {
		return "", nil, errors.New("the notes engine is not configured")
	}
	deadline := time.Now().Add(llmWaitBudget)
	wctx, cancel := context.WithDeadline(ctx, deadline)
	defer cancel()
	if err := d.waitQuiet(wctx, func() {}); err != nil {
		return "", nil, err
	}
	leave, err := d.llmEndpointTurn(wctx)
	if err != nil {
		return "", nil, err
	}
	if err := d.notesStaleChild(wctx); err != nil {
		leave()
		return "", nil, err
	}
	d.makeNotesRoom(wctx)
	g := d.LLMSup.Acquire()
	loadStart := time.Now()
	base, err := d.llmEnsureReady(ctx)
	if err != nil {
		g.Release()
		leave()
		return "", nil, err
	}
	deadline = deadline.Add(time.Since(loadStart))
	sctx, scancel := context.WithDeadline(ctx, minTime(deadline, time.Now().Add(llmSlotBudget)))
	defer scancel()
	if err := d.takeNotesSlot(sctx, false); err != nil {
		g.Release()
		leave()
		return "", nil, err
	}
	// A notes job that started while this request waited owns the model: the slot is free between two of its
	// calls, and an agent stream that slipped in there would hold it for llm_endpoint_max_s. Checked with the
	// slot in hand, so a job that begins from here on queues as the priority waiter instead.
	if d.notesJobs.Load() > 0 {
		d.notesReqSlot.release()
		g.Release()
		leave()
		return "", nil, errLLMNotesFirst
	}
	return base, func() {
		d.notesReqSlot.release()
		g.Release()
		leave()
		d.recycleLargeCtxSoon()
	}, nil
}

// errLLMNotesFirst refuses a request that reached the slot after a meeting's notes job began.
var errLLMNotesFirst = errors.New("a meeting's notes are being written")

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
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

// reqSlot is the notes child's single decode slot (-np 1) with a priority:
// a meeting's notes call is served before any waiting endpoint request, so a
// notes job that arrives behind a queue of agents does not wait for the queue.
type reqSlot struct {
	mu         sync.Mutex
	busy       bool
	notesQueue int           // notes calls waiting
	change     chan struct{} // closed and replaced on every release / dequeue
}

func newReqSlot() *reqSlot { return &reqSlot{change: make(chan struct{})} }

// take waits for the slot until ctx ends. It never succeeds once ctx is done,
// so an expired deadline cannot win a free slot by a coin flip.
func (s *reqSlot) take(ctx context.Context, notes bool) error {
	if notes {
		s.mu.Lock()
		s.notesQueue++
		s.mu.Unlock()
		defer func() {
			s.mu.Lock()
			s.notesQueue--
			s.wakeLocked()
			s.mu.Unlock()
		}()
	}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		s.mu.Lock()
		if !s.busy && (notes || s.notesQueue == 0) {
			s.busy = true
			s.mu.Unlock()
			return nil
		}
		ch := s.change
		s.mu.Unlock()
		select {
		case <-ch:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

// release frees the slot and wakes the waiters; a notes call among them wins.
func (s *reqSlot) release() {
	s.mu.Lock()
	s.busy = false
	s.wakeLocked()
	s.mu.Unlock()
}

func (s *reqSlot) wakeLocked() {
	close(s.change)
	s.change = make(chan struct{})
}

// takeNotesSlot claims the notes child's single decode slot (-np 1) for a
// meeting's notes call (notes true) or an endpoint request; the wait ends
// with ctx.
func (d *Daemon) takeNotesSlot(ctx context.Context, notes bool) error {
	return d.notesReqSlot.take(ctx, notes)
}

// writeLLMBusy is the bounded refusal: 503 with Retry-After.
func writeLLMBusy(w http.ResponseWriter, msg string) {
	w.Header().Set("Retry-After", llmRetryAfterS)
	writeErr(w, http.StatusServiceUnavailable, msg)
}

// writeLLMRefusal answers an admission failure: bounded-wait expiries are 503
// with Retry-After (dictation, a meeting's notes or another request has
// priority; nothing failed), everything else is an honest 503 — the client
// retries either way.
func (d *Daemon) writeLLMRefusal(w http.ResponseWriter, err error) {
	var busy *engineBusyError
	switch {
	case errors.Is(err, errLLMNotesFirst):
		writeLLMBusy(w, "the notes model is writing a meeting's notes; retry shortly")
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &busy):
		writeLLMBusy(w, "the notes model is busy; retry shortly")
	case errors.Is(err, context.Canceled):
		writeErr(w, http.StatusServiceUnavailable, "the request was canceled while waiting for the notes engine")
	default:
		d.log.Warn("llm endpoint: the notes engine could not be started", slog.Any("error", err))
		writeLLMBusy(w, "the notes model could not be started; retry shortly")
	}
}

// llmMaxDuration is the longest one endpoint request may run: the stored
// llm_endpoint_max_s, never beyond the notes call's own bound.
func (d *Daemon) llmMaxDuration() time.Duration {
	secs := 600
	if d.Meet != nil && d.Meet.Store != nil {
		secs = d.Meet.Store.Settings().LLMEndpointMaxSeconds()
	}
	return min(time.Duration(secs)*time.Second, notesCallTimeout)
}

// llmProxy forwards body to the notes child's own /v1/chat/completions under
// the child's per-spawn key (never the endpoint key) and streams the answer
// back. A whole stream is never buffered; every chunk is flushed as it
// arrives. The upstream request rides r.Context() bounded by the maximum
// duration, so a client disconnect or the cap cancels it.
func (d *Daemon) llmProxy(w http.ResponseWriter, r *http.Request, base string, body []byte) {
	uctx, cancel := context.WithTimeout(r.Context(), d.llmMaxDuration())
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
		switch {
		case r.Context().Err() != nil: // the client is gone
		case errors.Is(uctx.Err(), context.DeadlineExceeded):
			d.log.Info("llm endpoint: a request reached its maximum duration before the model answered")
			writeErr(w, http.StatusGatewayTimeout, "the request reached its maximum duration")
		default:
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
	upErr, downErr := streamLLM(w, resp.Body)
	d.logLLMStream(r, uctx, upErr, downErr)
}

// logLLMStream records how a proxied stream ended when it did not end at the
// model's own EOF: headers and payloads are never logged. A client that went
// away is routine and stays quiet; the cap, a slow reader and an upstream
// failure are not.
func (d *Daemon) logLLMStream(r *http.Request, uctx context.Context, upErr, downErr error) {
	switch {
	case downErr != nil:
		d.log.Warn("llm endpoint: the client stopped reading; the stream was cut", slog.Any("error", downErr))
	case upErr != nil && r.Context().Err() == nil && errors.Is(uctx.Err(), context.DeadlineExceeded):
		d.log.Info("llm endpoint: a stream reached its maximum duration and was ended")
	case upErr != nil && r.Context().Err() == nil:
		d.log.Warn("llm endpoint: the notes engine's stream failed", slog.Any("error", upErr))
	}
}

// streamLLM copies the upstream body through, flushing after every read so an
// SSE chunk reaches the client as the model emits it rather than at EOF. Each
// write has its own deadline (llmWriteDeadline): a client that stops reading
// is cut instead of holding the decode slot. It returns the upstream read
// error (nil at EOF) and the downstream write error, whichever ended it.
func streamLLM(w http.ResponseWriter, src io.Reader) (upErr, downErr error) {
	rc := http.NewResponseController(w)
	buf := make([]byte, llmStreamBufBytes)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			_ = rc.SetWriteDeadline(time.Now().Add(llmWriteDeadline)) // unsupported writers just have none
			if _, werr := w.Write(buf[:n]); werr != nil {
				return nil, werr
			}
			if ferr := rc.Flush(); ferr != nil && !errors.Is(ferr, http.ErrNotSupported) {
				return nil, ferr
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil, nil
			}
			return err, nil
		}
	}
}

// handleLLMKeyGet is GET /v1/meetings/llm-endpoint/key: the per-install
// bearer, for the owner's Settings pane only (owner token), never cached.
func (d *Daemon) handleLLMKeyGet(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !d.requireOwner(w, r) {
		return
	}
	d.writeLLMJSON(w, http.StatusOK, map[string]any{"llm_endpoint_key": d.currentLLMKey()})
}

// handleLLMKeyRegenerate is POST /v1/meetings/llm-endpoint/key: writes a fresh
// per-install bearer and answers it once, for the owner's Settings pane. The
// old key stops working the moment the new one is published.
func (d *Daemon) handleLLMKeyRegenerate(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !d.requireOwner(w, r) {
		return
	}
	key, err := d.rotateLLMKey()
	if err != nil {
		d.log.Warn("llm endpoint: the key could not be rotated", slog.Any("error", err))
		writeErr(w, http.StatusInternalServerError, "the key could not be written")
		return
	}
	d.writeLLMJSON(w, http.StatusOK, map[string]any{"llm_endpoint_key": key})
}

// llmCtxLeftover reports a resident notes child still running a context the
// current settings no longer ask for — the endpoint's large one after the
// endpoint was turned off.
func (d *Daemon) llmCtxLeftover() bool {
	if d.LLMSup == nil || d.llmEndpointOn() {
		return false
	}
	if _, live := d.LLMSup.LiveURL(); !live {
		return false
	}
	args := d.LLMSup.SpawnArgs()
	c, model := notesFlagValue(args, "-c"), notesFlagValue(args, "-m")
	return c != "" && model != "" && c != strconv.Itoa(d.notesCtxWantFor(model))
}

// recycleLargeCtxSoon re-arms llmEndpointOffRecycle from the places a safe
// point appears — an endpoint request's release and a notes job's end — so a
// child that could not be stopped when the endpoint was turned off (a stream
// was in flight, or a notes job ran) is stopped at the next one. Cheap when
// there is nothing to recycle.
func (d *Daemon) recycleLargeCtxSoon() {
	if d.llmCtxLeftover() {
		go d.llmEndpointOffRecycle()
	}
}

// llmEndpointOffRecycle stops a resident notes child that still runs the
// endpoint's large context once the endpoint is off, at a safe point: never
// while a notes job is queued or running, and Supervisor.Stop itself waits for
// the guard of a request in flight. One attempt is bounded by llmWaitBudget;
// the next safe point (recycleLargeCtxSoon) tries again. It does nothing, and
// takes no turn, unless a child with the wrong context is resident.
func (d *Daemon) llmEndpointOffRecycle() {
	if !d.llmCtxLeftover() || d.notesJobs.Load() > 0 {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), llmWaitBudget)
	defer cancel()
	leave, err := d.llmEndpointTurn(ctx)
	if err != nil {
		return // busy with voice work: the next safe point tries again
	}
	defer leave()
	if !d.llmCtxLeftover() || d.notesJobs.Load() > 0 {
		return
	}
	if err := d.notesStaleChild(ctx); err != nil {
		d.log.Warn("llm endpoint: the notes engine could not be recycled after the endpoint was turned off", slog.Any("error", err))
	}
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
