package daemon

// The OpenAI-compatible endpoint (issue #537) through the real mux, with the
// fake ox-llm child standing in for llama-server: auth, the off gate, the
// proxy's passthrough and cancellation, the dictation-first refusal, the
// model switch and the context the spawn argv carries.

import (
	"bufio"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/meeting"
)

// llmEndpointFixture is a meeting daemon whose ox-llm is the fake child and
// whose models dir holds the installed 4B (the automatic resolution's id is
// then the catalog's). dir stamps the spawn argv; reqlog records what the
// child was sent.
func llmEndpointFixture(t *testing.T, edit func(*config.Config)) (*Daemon, *http.ServeMux, string) {
	t.Helper()
	t.Setenv("OXSAY_FAKE_LLM", "1")
	dir := t.TempDir()
	t.Setenv("OXSAY_FAKE_DIR", dir)
	// The GPU-fit probe execs the notes binary; the fake child answers
	// nothing useful to it — unknown is the honest answer the code handles.
	oldProbe, oldWarm := notesGPUWired, notesGPUWarmup
	notesGPUWired = func(string) (uint64, uint64) { return 0, 0 }
	notesGPUWarmup = func(string) {}
	t.Cleanup(func() { notesGPUWired, notesGPUWarmup = oldProbe, oldWarm })
	d, mux := meetingFixture(t, func(c *config.Config) {
		c.NotesBin = os.Args[0]
		c.HostMemoryBytes = 32 << 30
		if edit != nil {
			edit(c)
		}
	})
	if err := os.MkdirAll(d.Cfg.ModelsDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d.Cfg.ModelsDir(), config.NotesModelFile), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	return d, mux, dir
}

// llmPutSettings changes the endpoint settings through the settings route as
// the owner (turning the endpoint on needs the owner bearer).
func llmPutSettings(t *testing.T, d *Daemon, mux http.Handler, body string) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPut, "/v1/meetings/settings", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+d.ownerToken)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT settings %s -> %d %s", body, rec.Code, rec.Body)
	}
}

func llmReq(mux http.Handler, method, path, key, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

// The endpoint off is the endpoint absent: both routes 404, bearer or not.
// Mutation: llmendpoint.go handleLLMChat, drop the `!d.llmEndpointOn()`
// early return -> RED (the off daemon answers 401/200, not 404).
func TestLLMEndpointOffAnswers404(t *testing.T) {
	_, mux, _ := llmEndpointFixture(t, nil)
	for _, tc := range []struct{ method, path string }{
		{http.MethodPost, "/v1/chat/completions"},
		{http.MethodGet, "/v1/models"},
	} {
		if rec := llmReq(mux, tc.method, tc.path, "anything", "{}"); rec.Code != http.StatusNotFound {
			t.Fatalf("%s %s off -> %d, want 404", tc.method, tc.path, rec.Code)
		}
	}
	// The app's own catalog keeps working bearer-less, endpoint or not.
	if rec := llmReq(mux, http.MethodGet, "/v1/models", "", ""); rec.Code != http.StatusOK {
		t.Fatalf("the internal catalog is broken by the endpoint: %d", rec.Code)
	}
}

// Every endpoint request carries the per-install key: none or a wrong one
// is 401. Mutation: llmendpoint.go handleLLMChat, delete the `!d.llmKeyOK`
// check -> RED (a bearer-less request reaches the child).
func TestLLMEndpointRequiresTheKey(t *testing.T) {
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	for _, tc := range []struct {
		name, key string
	}{
		{"no header", ""},
		{"a wrong key", strings.Repeat("ab", 32)},
		{"the owner token is not the endpoint key", d.ownerToken},
	} {
		if rec := llmReq(mux, http.MethodPost, "/v1/chat/completions", tc.key, "{}"); rec.Code != http.StatusUnauthorized {
			t.Fatalf("%s -> %d, want 401", tc.name, rec.Code)
		}
	}
	// /v1/models shares its route with the app's catalog: a bearer-less GET
	// is the app's, a wrong bearer is an endpoint client's and is refused.
	if rec := llmReq(mux, http.MethodGet, "/v1/models", "", ""); rec.Code != http.StatusOK {
		t.Fatalf("the bearer-less catalog -> %d, want 200", rec.Code)
	}
	for _, key := range []string{strings.Repeat("ab", 32), d.ownerToken} {
		if rec := llmReq(mux, http.MethodGet, "/v1/models", key, ""); rec.Code != http.StatusUnauthorized {
			t.Fatalf("a wrong bearer on /v1/models -> %d, want 401", rec.Code)
		}
	}
	if rec := llmReq(mux, http.MethodGet, "/v1/models", d.currentLLMKey(), ""); rec.Code != http.StatusOK {
		t.Fatalf("the install key -> %d, want 200", rec.Code)
	}
}

// /v1/models names the selected notes model and follows a choice switch.
func TestLLMEndpointModelsFollowsTheSelection(t *testing.T) {
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	modelID := func() string {
		rec := llmReq(mux, http.MethodGet, "/v1/models", d.currentLLMKey(), "")
		if rec.Code != http.StatusOK {
			t.Fatalf("/v1/models -> %d", rec.Code)
		}
		body := rec.Body.String()
		if strings.Count(body, `"id"`) != 1 {
			t.Fatalf("the endpoint must list exactly one model: %s", body)
		}
		return body
	}
	if body := modelID(); !strings.Contains(body, `"qwen3.5-4b"`) {
		t.Fatalf("want the installed 4B's id, got %s", body)
	}
	// Switch the selection to the 9B: install the file and save the choice.
	if err := os.WriteFile(filepath.Join(d.Cfg.ModelsDir(), "Qwen3.5-9B-Q4_K_M.gguf"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeNotesChoice(d.Cfg.Home, config.NotesChoice{ID: "qwen3.5-9b"}); err != nil {
		t.Fatal(err)
	}
	if body := modelID(); !strings.Contains(body, `"qwen3.5-9b"`) {
		t.Fatalf("after the switch want the 9B's id, got %s", body)
	}
}

// A streamed request passes chunks to the client as the child emits them —
// the first arrives long before the child's own paced stream could be done —
// and the request body reaches the child byte for byte (tools, template
// kwargs, every field an agent sends).
func TestLLMEndpointStreamsThrough(t *testing.T) {
	t.Setenv("OXSAY_FAKE_LLM_CHUNK_MS", "150")
	reqlog := filepath.Join(t.TempDir(), "req.log")
	t.Setenv("OXSAY_FAKE_LLM_REQLOG", reqlog)
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	body := `{"model":"notes","stream":true,"messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"f"}}],"tool_choice":"auto","reasoning_effort":"low"}`
	start := time.Now()
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+d.currentLLMKey())
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(resp.Body)
		t.Fatalf("stream -> %d %s", resp.StatusCode, raw)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.Contains(ct, "text/event-stream") {
		t.Fatalf("the upstream's SSE content type did not pass through: %q", ct)
	}
	rd := bufio.NewReader(resp.Body)
	first, err := rd.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	if took := time.Since(start); took >= 400*time.Millisecond {
		t.Fatalf("the first chunk took %v — the proxy buffered the whole stream", took)
	}
	if !strings.HasPrefix(first, "data: ") {
		t.Fatalf("not an SSE chunk: %q", first)
	}
	rest, err := io.ReadAll(rd)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(rest), "[DONE]") {
		t.Fatalf("the stream did not reach its end: %q", rest)
	}
	raw, err := os.ReadFile(reqlog)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), "body="+body) {
		t.Fatalf("the child saw a different body than the client sent: %s", raw)
	}
}

// A client that goes away cancels the upstream request: the child's request
// context ends mid-stream and it says so in its log.
func TestLLMEndpointCancelReachesUpstream(t *testing.T) {
	t.Setenv("OXSAY_FAKE_LLM_CHUNK_MS", "300")
	reqlog := filepath.Join(t.TempDir(), "req.log")
	t.Setenv("OXSAY_FAKE_LLM_REQLOG", reqlog)
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, srv.URL+"/v1/chat/completions",
		strings.NewReader(`{"model":"notes","stream":true,"messages":[{"role":"user","content":"hi"}]}`))
	req.Header.Set("Authorization", "Bearer "+d.currentLLMKey())
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	rd := bufio.NewReader(resp.Body)
	if _, err := rd.ReadString('\n'); err != nil { // one chunk arrived
		t.Fatal(err)
	}
	cancel()
	_ = resp.Body.Close()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		raw, _ := os.ReadFile(reqlog)
		if strings.Contains(string(raw), "chat-cancelled") {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	raw, _ := os.ReadFile(reqlog)
	t.Fatalf("the child never saw the cancellation: %s", raw)
}

// While a dictation request is in flight the endpoint refuses in bounded
// time with 503 + Retry-After rather than queueing behind voice work.
// Mutation: llmendpoint.go llmAdmit, drop the waitQuiet call -> RED (the
// request goes to the engine during dictation).
func TestLLMEndpointYieldsToDictation(t *testing.T) {
	keep := llmWaitBudget
	llmWaitBudget = 300 * time.Millisecond
	t.Cleanup(func() { llmWaitBudget = keep })
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	end := d.beginInteractive() // a dictation request is in flight
	defer end()
	rec := llmReq(mux, http.MethodPost, "/v1/chat/completions", d.currentLLMKey(), `{"model":"notes","messages":[]}`)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("during dictation -> %d, want 503", rec.Code)
	}
	if rec.Header().Get("Retry-After") == "" {
		t.Fatal("a bounded refusal carries Retry-After")
	}
}

// The notes child's single request slot (-np 1) serializes an endpoint
// request against another already streaming — the second queues for the slot
// and, when the stream outlasts its slot budget, is refused in bounded time
// rather than held behind a minutes-long stream.
func TestLLMEndpointTakesTheSingleSlot(t *testing.T) {
	keep, keepSlot := llmWaitBudget, llmSlotBudget
	llmWaitBudget, llmSlotBudget = 2*time.Second, 300*time.Millisecond
	t.Cleanup(func() { llmWaitBudget, llmSlotBudget = keep, keepSlot })
	t.Setenv("OXSAY_FAKE_LLM_CHUNK_MS", "800")
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	srv := httptest.NewServer(mux)
	defer srv.Close()
	chat := func() *http.Response {
		req, _ := http.NewRequest(http.MethodPost, srv.URL+"/v1/chat/completions",
			strings.NewReader(`{"model":"notes","stream":true,"messages":[{"role":"user","content":"hi"}]}`))
		req.Header.Set("Authorization", "Bearer "+d.currentLLMKey())
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}
	first := chat()
	defer first.Body.Close()
	rd := bufio.NewReader(first.Body)
	if _, err := rd.ReadString('\n'); err != nil { // the first stream owns the slot
		t.Fatal(err)
	}
	second := chat()
	defer second.Body.Close()
	if second.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("a second stream behind the first -> %d, want 503", second.StatusCode)
	}
	if second.Header.Get("Retry-After") == "" {
		t.Fatal("the slot refusal carries Retry-After")
	}
}

// The effective context reaches the spawn argv: the notes value while the
// endpoint is off, the configured llm_endpoint_ctx while on.
func TestLLMEndpointContextInArgv(t *testing.T) {
	d, mux, dir := llmEndpointFixture(t, nil)
	spawnCtx := func() int {
		pids := llmSpawnPids(dir)
		if len(pids) == 0 {
			t.Fatal("the fake child never spawned")
		}
		for _, a := range strings.Split(llmArgv(t, dir, pids[len(pids)-1]), "\n") {
			if n, err := strconv.Atoi(strings.TrimPrefix(a, "-c")); err == nil && strings.HasPrefix(a, "-c") {
				return n
			}
		}
		// -c and its value are separate argv entries: walk pairs.
		argv := strings.Split(llmArgv(t, dir, pids[len(pids)-1]), "\n")
		for i, a := range argv {
			if a == "-c" && i+1 < len(argv) {
				n, _ := strconv.Atoi(argv[i+1])
				return n
			}
		}
		return -1
	}
	// Off: the plain notes context.
	if _, err := d.LLMSup.EnsureReady(t.Context()); err != nil {
		t.Fatal(err)
	}
	if c := spawnCtx(); c != meeting.NotesContextTokens() {
		t.Fatalf("off: -c = %d, want the notes context %d", c, meeting.NotesContextTokens())
	}
	if err := d.LLMSup.Stop(t.Context()); err != nil {
		t.Fatal(err)
	}
	// On, custom ctx.
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on","llm_endpoint_ctx":65536}`)
	if _, err := d.LLMSup.EnsureReady(t.Context()); err != nil {
		t.Fatal(err)
	}
	if c := spawnCtx(); c != 65536 {
		t.Fatalf("on: -c = %d, want 65536", c)
	}
	// /status reports the effective figure.
	if st := d.Status(); !st.LLMEndpoint.Enabled || st.LLMEndpoint.Context != 65536 {
		t.Fatalf("/status llm_endpoint = %+v, want on at 65536", st.LLMEndpoint)
	}
}

// The default endpoint context is 131072 tokens, and the floor is the notes
// context: a stored value below it never reaches the argv.
func TestLLMEndpointContextBounds(t *testing.T) {
	st := meeting.Settings{LLMEndpoint: meeting.LLMEndpointOn}
	if got := st.LLMEndpointCtxTokens(); got != meeting.LLMEndpointDefaultCtx {
		t.Fatalf("unset ctx -> %d, want the default %d", got, meeting.LLMEndpointDefaultCtx)
	}
	st.LLMEndpointCtx = 1
	if got := st.LLMEndpointCtxTokens(); got != meeting.NotesContextTokens() {
		t.Fatalf("ctx below the floor -> %d, want %d", got, meeting.NotesContextTokens())
	}
}

// The key file is 0600 under the run dir and survives as the source of
// truth; regenerating rotates it through the (owner-only) route.
func TestLLMEndpointKeyFileAndRotation(t *testing.T) {
	d, mux, _ := llmEndpointFixture(t, nil)
	path := filepath.Join(d.Cfg.RunDir(), llmEndpointKeyFile)
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("the key file is %o, want 0600", st.Mode().Perm())
	}
	raw, _ := os.ReadFile(path)
	if strings.TrimSpace(string(raw)) != d.currentLLMKey() {
		t.Fatal("the daemon's key is not the file's")
	}
	old := d.currentLLMKey()
	rec := llmReq(mux, http.MethodPost, "/v1/meetings/llm-endpoint/key", d.ownerToken, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("regenerate -> %d %s", rec.Code, rec.Body)
	}
	if d.currentLLMKey() == "" || d.currentLLMKey() == old {
		t.Fatal("regeneration did not rotate the key")
	}
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	if rec := llmReq(mux, http.MethodGet, "/v1/models", old, ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("the rotated-out key still works: %d", rec.Code)
	}
	if rec := llmReq(mux, http.MethodGet, "/v1/models", d.currentLLMKey(), ""); rec.Code != http.StatusOK {
		t.Fatalf("the new key -> %d", rec.Code)
	}
}
