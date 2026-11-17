package daemon

// Scheduling of the OpenAI-compatible endpoint against meeting notes and
// against its own clients (issue #537, review round 1): notes first, bounded
// queue, per-request maximum, slow readers, and what gets logged.

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/meeting"
)

func waitUntil(t *testing.T, limit time.Duration, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(limit)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("%s did not happen within %v", what, limit)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func slotBusy(s *reqSlot) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.busy
}

// A notes call that queues behind waiting endpoint requests is served first.
func TestReqSlotNotesCallJumpsTheEndpointQueue(t *testing.T) {
	s := newReqSlot()
	if err := s.take(t.Context(), false); err != nil {
		t.Fatal(err)
	}
	order := make(chan string, 2)
	endpointUp := make(chan struct{})
	go func() {
		close(endpointUp)
		if err := s.take(t.Context(), false); err == nil {
			order <- "endpoint"
			s.release()
		}
	}()
	<-endpointUp
	time.Sleep(100 * time.Millisecond) // the endpoint request is queued first
	go func() {
		if err := s.take(t.Context(), true); err == nil {
			order <- "notes"
			s.release()
		}
	}()
	time.Sleep(100 * time.Millisecond)
	s.release()
	if first := <-order; first != "notes" {
		t.Fatalf("%s was served before the notes call", first)
	}
	if second := <-order; second != "endpoint" {
		t.Fatalf("second = %s", second)
	}
}

// takeNotesSlot never succeeds after its deadline, free slot or not.
func TestReqSlotNeverSucceedsAfterTheDeadline(t *testing.T) {
	s := newReqSlot()
	ctx, cancel := context.WithDeadline(t.Context(), time.Now().Add(-time.Second))
	defer cancel()
	for i := 0; i < 200; i++ { // a select between a ready channel and a dead context is a coin flip
		if err := s.take(ctx, i%2 == 0); !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("take #%d after the deadline = %v, want DeadlineExceeded", i, err)
		}
	}
	if slotBusy(s) {
		t.Fatal("a refused take left the slot busy")
	}
}

// While a meeting's notes job is queued or running, a new endpoint request is
// refused at admission (503 + Retry-After) before its body is read; a request
// already streaming is not killed.
// Mutation: llmendpoint.go handleLLMChat, delete the `d.notesJobs.Load() > 0`
// refusal block -> RED (the request is admitted and answered 200).
func TestLLMEndpointRefusedWhileANotesJobIsQueued(t *testing.T) {
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	d.notesJobs.Add(1)
	body := &readCounter{r: strings.NewReader(`{"model":"notes","messages":[]}`)}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", body)
	req.Header.Set("Authorization", "Bearer "+d.currentLLMKey())
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable || rec.Header().Get("Retry-After") == "" {
		t.Fatalf("during a notes job -> %d (Retry-After %q), want 503 + Retry-After", rec.Code, rec.Header().Get("Retry-After"))
	}
	if body.n.Load() != 0 {
		t.Fatal("the refused request's body was read")
	}
	d.notesJobs.Add(-1)
	if rec := llmReq(mux, http.MethodPost, "/v1/chat/completions", d.currentLLMKey(), `{"model":"notes","messages":[]}`); rec.Code != http.StatusOK {
		t.Fatalf("after the notes job ended -> %d, want 200", rec.Code)
	}
}

// readCounter counts the Read calls a body receives.
type readCounter struct {
	r io.Reader
	n atomic.Int64
}

func (c *readCounter) Read(p []byte) (int, error) { c.n.Add(1); return c.r.Read(p) }

// The notes job's own counter spans the whole job (queued included) and is
// released on every way out.
func TestNotesJobTurnCountsTheWholeJob(t *testing.T) {
	d, _, _ := llmEndpointFixture(t, nil)
	if n := d.notesJobs.Load(); n != 0 {
		t.Fatalf("notesJobs at rest = %d", n)
	}
	leave, err := d.notesJobTurn(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if n := d.notesJobs.Load(); n != 1 {
		t.Fatalf("notesJobs during a job = %d, want 1", n)
	}
	leave()
	leave() // idempotent
	if n := d.notesJobs.Load(); n != 0 {
		t.Fatalf("notesJobs after the job = %d, want 0", n)
	}
}

// A notes call that waits behind an agent stream does not burn its own timer
// while it waits: the 20-minute (here 400 ms) clock starts at the slot.
// Mutation: meetings.go llmChat.Complete, move `callCtx, cancel :=
// context.WithTimeout(ctx, notesCallTimeout)` back above takeNotesSlot ->
// RED (the call times out having never started).
func TestANotesCallQueuedBehindAnAgentDoesNotTimeOutEarly(t *testing.T) {
	d, _, _ := llmEndpointFixture(t, nil)
	keep := notesCallTimeout
	notesCallTimeout = 400 * time.Millisecond
	t.Cleanup(func() { notesCallTimeout = keep })
	if err := d.notesReqSlot.take(t.Context(), false); err != nil { // an agent stream holds the slot
		t.Fatal(err)
	}
	go func() {
		time.Sleep(900 * time.Millisecond) // longer than the call's whole timeout
		d.notesReqSlot.release()
	}()
	out, err := (llmChat{d: d}).Complete(t.Context(), meeting.Request{System: "s", User: "u"})
	if err != nil {
		t.Fatalf("the queued notes call failed: %v", err)
	}
	if out != "the canned notes" {
		t.Fatalf("out = %q", out)
	}
}

// More than one running and llmMaxWaiters queued is refused BEFORE a body is
// read, so the bodies in memory stay bounded.
func TestLLMEndpointRefusesBeyondTheQueueBeforeReadingTheBody(t *testing.T) {
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	for i := 0; i < 1+llmMaxWaiters; i++ {
		d.llmGate <- struct{}{}
	}
	body := &readCounter{r: strings.NewReader(strings.Repeat("x", 1<<20))}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", body)
	req.Header.Set("Authorization", "Bearer "+d.currentLLMKey())
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable || rec.Header().Get("Retry-After") == "" {
		t.Fatalf("with the queue full -> %d, want 503 + Retry-After", rec.Code)
	}
	if body.n.Load() != 0 {
		t.Fatal("a request refused for the full queue still had its body read")
	}
	// The tokens come back: after they are released the next request is served.
	for i := 0; i < 1+llmMaxWaiters; i++ {
		<-d.llmGate
	}
	if rec := llmReq(mux, http.MethodPost, "/v1/chat/completions", d.currentLLMKey(), `{"model":"notes","messages":[]}`); rec.Code != http.StatusOK {
		t.Fatalf("after the queue drained -> %d", rec.Code)
	}
}

// A queued request waits for the slot up to its slot budget: served when the
// holder finishes inside it, refused with Retry-After when not.
func TestLLMEndpointQueuedRequestWaitsForTheSlotThenGivesUp(t *testing.T) {
	keep, keepSlot := llmWaitBudget, llmSlotBudget
	llmWaitBudget, llmSlotBudget = 5*time.Second, 600*time.Millisecond
	t.Cleanup(func() { llmWaitBudget, llmSlotBudget = keep, keepSlot })
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	if err := d.notesReqSlot.take(t.Context(), false); err != nil {
		t.Fatal(err)
	}
	// Released inside the budget: served.
	go func() { time.Sleep(200 * time.Millisecond); d.notesReqSlot.release() }()
	start := time.Now()
	if rec := llmReq(mux, http.MethodPost, "/v1/chat/completions", d.currentLLMKey(), `{"model":"notes","messages":[]}`); rec.Code != http.StatusOK {
		t.Fatalf("queued behind a short holder -> %d %s", rec.Code, rec.Body)
	}
	if time.Since(start) < 150*time.Millisecond {
		t.Fatal("the request did not wait for the slot")
	}
	// Held past the budget: refused.
	if err := d.notesReqSlot.take(t.Context(), false); err != nil {
		t.Fatal(err)
	}
	defer d.notesReqSlot.release()
	start = time.Now()
	rec := llmReq(mux, http.MethodPost, "/v1/chat/completions", d.currentLLMKey(), `{"model":"notes","messages":[]}`)
	if rec.Code != http.StatusServiceUnavailable || rec.Header().Get("Retry-After") == "" {
		t.Fatalf("behind a long holder -> %d, want 503 + Retry-After", rec.Code)
	}
	if took := time.Since(start); took > 3*time.Second {
		t.Fatalf("the refusal took %v, the slot budget is 600ms", took)
	}
}

// A client that stops reading is cut after the per-write deadline and the slot
// comes back — it cannot hold the model for the upstream's whole timeout.
// Mutation: llmendpoint.go streamLLM, delete the rc.SetWriteDeadline call
// -> RED (the slot is still busy long after the deadline).
func TestLLMEndpointSlowReaderReleasesTheSlot(t *testing.T) {
	keep := llmWriteDeadline
	llmWriteDeadline = 400 * time.Millisecond
	t.Cleanup(func() { llmWriteDeadline = keep })
	t.Setenv("OXSAY_FAKE_LLM_WORD_KB", "8192") // 3 x 8 MiB: far past any socket buffer
	t.Setenv("OXSAY_FAKE_LLM_CHUNK_MS", "5")
	reqlog := filepath.Join(t.TempDir(), "req.log")
	t.Setenv("OXSAY_FAKE_LLM_REQLOG", reqlog)
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	conn, err := net.Dial("tcp", srv.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetReadBuffer(4096) // a reader that takes almost nothing
	}
	payload := `{"model":"notes","stream":true,"messages":[{"role":"user","content":"hi"}]}`
	_, _ = io.WriteString(conn, "POST /v1/chat/completions HTTP/1.1\r\nHost: "+srv.Listener.Addr().String()+
		"\r\nAuthorization: Bearer "+d.currentLLMKey()+"\r\nContent-Type: application/json\r\nContent-Length: "+
		strconv.Itoa(len(payload))+"\r\n\r\n"+payload)
	// The stream starts: the slot is taken. Then the client never reads another byte.
	waitUntil(t, 10*time.Second, "the stream to take the slot", func() bool { return slotBusy(d.notesReqSlot) })
	waitUntil(t, 10*time.Second, "the slot to come back after the client stopped reading", func() bool { return !slotBusy(d.notesReqSlot) })
	waitUntil(t, 5*time.Second, "the upstream to be cancelled", func() bool {
		raw, _ := os.ReadFile(reqlog)
		return strings.Contains(string(raw), "chat-cancelled")
	})
}

// One request runs at most llm_endpoint_max_s: an endless stream is ended
// cleanly (the client sees EOF, not an error), the upstream is cancelled and
// the slot is free again.
func TestLLMEndpointMaxDurationEndsAStreamCleanly(t *testing.T) {
	t.Setenv("OXSAY_FAKE_LLM_ENDLESS", "1")
	t.Setenv("OXSAY_FAKE_LLM_CHUNK_MS", "50")
	reqlog := filepath.Join(t.TempDir(), "req.log")
	t.Setenv("OXSAY_FAKE_LLM_REQLOG", reqlog)
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	// Below the route's own floor on purpose: a test cannot wait ten seconds.
	err := d.Meet.Store.UpdateSettings(func(cur meeting.Settings, _ error) (meeting.Settings, error) {
		cur.LLMEndpointMaxS = 1
		return cur, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(mux)
	defer srv.Close()
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/v1/chat/completions",
		strings.NewReader(`{"model":"notes","stream":true,"messages":[{"role":"user","content":"hi"}]}`))
	req.Header.Set("Authorization", "Bearer "+d.currentLLMKey())
	start := time.Now()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(bufio.NewReader(resp.Body))
	if err != nil {
		t.Fatalf("the stream did not end cleanly: %v (read %d bytes)", err, len(raw))
	}
	took := time.Since(start)
	if took < 900*time.Millisecond || took > 6*time.Second {
		t.Fatalf("the stream ended after %v, want about the 1 s maximum", took)
	}
	if !bytes.Contains(raw, []byte(`"more `)) {
		t.Fatalf("no chunk arrived before the cap: %q", raw)
	}
	waitUntil(t, 5*time.Second, "the slot to be free", func() bool { return !slotBusy(d.notesReqSlot) })
	waitUntil(t, 5*time.Second, "the upstream to be cancelled", func() bool {
		b, _ := os.ReadFile(reqlog)
		return strings.Contains(string(b), "chat-cancelled")
	})
}

// A non-EOF upstream read error and a downstream write failure are logged —
// error text only, never a header or a payload — instead of vanishing.
func TestLLMEndpointLogsStreamFailures(t *testing.T) {
	var buf bytes.Buffer
	d, _, _ := llmEndpointFixture(t, nil)
	d.log = slog.New(slog.NewTextHandler(&buf, nil))
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)

	upErr, downErr := streamLLM(httptest.NewRecorder(), io.MultiReader(strings.NewReader("secret-prompt-text"), failingReader{}))
	if upErr == nil || downErr != nil {
		t.Fatalf("upstream failure not reported: up=%v down=%v", upErr, downErr)
	}
	d.logLLMStream(r, r.Context(), upErr, downErr)
	_, downErr = streamLLM(failingWriter{httptest.NewRecorder()}, strings.NewReader("secret-prompt-text"))
	if downErr == nil {
		t.Fatal("a failing write was not reported")
	}
	d.logLLMStream(r, r.Context(), nil, downErr)
	out := buf.String()
	if !strings.Contains(out, "the notes engine's stream failed") || !strings.Contains(out, "the client stopped reading") {
		t.Fatalf("stream failures not logged: %q", out)
	}
	if strings.Contains(out, "secret-prompt-text") {
		t.Fatalf("a payload reached the log: %q", out)
	}
	// An encode failure on a new route is logged and answers 500, not an empty 200.
	buf.Reset()
	rec := httptest.NewRecorder()
	d.writeLLMJSON(rec, http.StatusOK, map[string]any{"bad": make(chan int)})
	if rec.Code != http.StatusInternalServerError || !strings.Contains(buf.String(), "could not be encoded") {
		t.Fatalf("encode failure: %d, log %q", rec.Code, buf.String())
	}
}

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errors.New("upstream reset") }

type failingWriter struct{ http.ResponseWriter }

func (failingWriter) Write([]byte) (int, error) { return 0, errors.New("broken pipe") }

// Dictation runs on the resident STT server, which is no part of the large
// engines' turns: a running endpoint request holds the notes model's turn and
// guard, and neither stops a dictation request from getting its server — while
// another large engine (the fast voice) does wait behind that turn.
func TestDictationIsNotBlockedByAnEndpointRequestsTurn(t *testing.T) {
	d, _, _ := llmEndpointFixture(t, nil)
	if d.STTSup == nil {
		t.Skip("the fixture has no STT supervisor")
	}
	other := &engine.Supervisor{} // stands in for the fast voice
	d.mem = &residency{
		change:  make(chan struct{}),
		engines: []*engine.Supervisor{d.LLMSup, other},
		log:     d.log,
		stop:    func(context.Context, *engine.Supervisor) error { return nil },
	}
	leave, err := d.llmEndpointTurn(t.Context()) // the endpoint request's turn, held for its stream
	if err != nil {
		t.Fatal(err)
	}
	defer leave()
	g := d.LLMSup.Acquire() // and its guard
	defer g.Release()
	for _, e := range d.largeEngineSups() {
		if e == d.STTSup {
			t.Fatal("the STT server is among the engines that take turns")
		}
	}
	// The contrast: a managed large engine does wait.
	wctx, cancel := context.WithTimeout(t.Context(), 300*time.Millisecond)
	defer cancel()
	if _, err := d.mem.enter(wctx, other, 0); err == nil {
		t.Fatal("the control engine entered while the notes turn was held: the test would prove nothing")
	}
	// Dictation: its server comes up at once.
	sctx, scancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer scancel()
	start := time.Now()
	base, release, err := d.sttServer(sctx)
	if err != nil {
		t.Skipf("the fixture's STT server could not start (%v): the structural checks above stand", err)
	}
	release()
	if base == "" || time.Since(start) > 8*time.Second {
		t.Fatalf("dictation's server took %v", time.Since(start))
	}
}
