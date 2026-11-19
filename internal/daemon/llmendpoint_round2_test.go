package daemon

// Review round 2 of the OpenAI-compatible endpoint (PR #643): each test is a
// journey through the production entry point the finding names, not a unit.

import (
	"bufio"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/meeting"
)

const llmRound2ChunkJSON = `{"summary":"A planning call.","points":[{"text":"Ship Friday","status":"open","quote":""}],"action_items":[],"numbers":[]}`

// A meeting's notes call that queued behind an agent's stream still gets its
// whole generation allowance: the composer's per-call timer must not be running
// while the call waits for the slot (it did: Composer.call wrapped the context
// before llmChat.Complete took the slot, and the wait was spent out of it).
// Journey: Composer.Compose over llmChat, the real notes child (fake), the slot
// held for 1 s, the composer's call timeout 1.5 s, the model needing 0.9 s.
// Mutation: internal/daemon/meetings.go, delete the llmChat.SelfTimed method
// -> RED (the call gets ~0.5 s of its 0.9 s and the chunk is lost: no notes).
func TestAQueuedNotesCallKeepsItsWholeGenerationAllowance(t *testing.T) {
	d, _ := startNotesFake(t)
	t.Setenv("OXSAY_FAKE_LLM_JSON", llmRound2ChunkJSON)
	t.Setenv("OXSAY_FAKE_LLM_HANG_MS", "900")
	if err := d.notesReqSlot.take(t.Context(), false); err != nil { // an agent stream holds the slot
		t.Fatal(err)
	}
	go func() {
		time.Sleep(time.Second)
		d.notesReqSlot.release()
	}()
	n, err := meeting.Composer{Chat: llmChat{d: d}, CallTimeout: 1500 * time.Millisecond}.
		Compose(t.Context(), "hello there everyone", meeting.Labels{}, "en")
	if err != nil || n.Summary == "" {
		t.Fatalf("notes = %+v, err = %v: the queued call lost generation time to the wait", n, err)
	}
}

// A cold start longer than the admission budget with a free slot is served,
// not refused: the slot wait gets its own budget after the load.
// Mutation: internal/daemon/llmendpoint.go llmAdmit, take the slot on `wctx`
// (the admission context) instead of `sctx` -> RED (503 after a 1.2 s load
// against a 0.4 s admission budget).
func TestLLMEndpointColdStartLongerThanTheBudgetIsServed(t *testing.T) {
	keep := llmWaitBudget
	llmWaitBudget = 400 * time.Millisecond
	t.Cleanup(func() { llmWaitBudget = keep })
	t.Setenv("OXSAY_FAKE_START_DELAY_MS", "1200")
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	rec := llmReq(mux, http.MethodPost, "/v1/chat/completions", d.currentLLMKey(), `{"model":"notes","messages":[{"role":"user","content":"hi"}]}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("a cold start of 1.2 s with a free slot -> %d %s, want 200", rec.Code, rec.Body)
	}
}

// An agent stream in flight keeps /status from reporting an idle daemon, so the
// app's version handshake defers its restart.
// Mutation: internal/daemon/service.go busy(), delete the `LLMChats:` line ->
// RED (Idle is true under a running stream).
func TestAnEndpointStreamMakesTheDaemonBusy(t *testing.T) {
	t.Setenv("OXSAY_FAKE_LLM_ENDLESS", "1")
	t.Setenv("OXSAY_FAKE_LLM_CHUNK_MS", "50")
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	if st := d.Status(); !st.Idle {
		t.Fatalf("an unused daemon is not idle: %+v", st.Busy)
	}
	srv := httptest.NewServer(mux)
	defer srv.Close()
	ctx, cancel := context.WithCancel(t.Context())
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, srv.URL+"/v1/chat/completions",
		strings.NewReader(`{"model":"notes","stream":true,"messages":[{"role":"user","content":"hi"}]}`))
	req.Header.Set("Authorization", "Bearer "+d.currentLLMKey())
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if _, err := bufio.NewReader(resp.Body).ReadString('\n'); err != nil { // the stream runs
		t.Fatal(err)
	}
	if st := d.Status(); st.Idle || st.Busy.LLMChats != 1 {
		t.Fatalf("under a running stream Idle = %v, busy = %+v, want busy with one chat", st.Idle, st.Busy)
	}
	cancel()
	waitUntil(t, 5*time.Second, "the daemon to be idle once the stream ended", func() bool { return d.Status().Idle })
}

// An installed model below its memory floor is never started for an agent, the
// way meeting notes refuse it: a 503 with the reason, and no child.
// Mutation: internal/daemon/llmendpoint.go llmAdmit, delete the notesBlock
// check -> RED (the request is answered 200 and a child was spawned).
func TestLLMEndpointRefusesAModelBelowItsMemoryFloor(t *testing.T) {
	d, mux, dir := llmEndpointFixture(t, func(c *config.Config) { c.HostMemoryBytes = 2 << 30 })
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	rec := llmReq(mux, http.MethodPost, "/v1/chat/completions", d.currentLLMKey(), `{"model":"notes","messages":[{"role":"user","content":"hi"}]}`)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("a Mac below the model's floor -> %d %s, want 503", rec.Code, rec.Body)
	}
	if !strings.Contains(rec.Body.String(), "GB of memory") {
		t.Fatalf("the refusal does not say why: %s", rec.Body)
	}
	if rec.Header().Get("Retry-After") != "" {
		t.Fatal("a refusal that no retry fixes carries Retry-After")
	}
	if n := len(spawnStamps(t, dir)); n != 0 {
		t.Fatalf("%d notes child spawned for a request refused for memory", n)
	}
}

// Two rotations through the route in flight at once leave the key on disk and
// the key the daemon accepts the same, and no superseded key authenticates.
// Run under -race.
// Mutation: internal/daemon/llmendpoint.go rotateLLMKey, delete the
// d.llmMu.Lock() / defer d.llmMu.Unlock() pair -> RED (a data race on d.llmKey,
// and the file and memory disagree).
func TestConcurrentKeyRotationsThroughTheRouteAgree(t *testing.T) {
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	const rotations = 16
	keys := make([]string, rotations)
	var wg sync.WaitGroup
	for i := range rotations {
		wg.Add(1)
		go func() {
			defer wg.Done()
			req := httptest.NewRequest(http.MethodPost, "/v1/meetings/llm-endpoint/key", nil)
			req.Header.Set("Authorization", "Bearer "+d.ownerToken)
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code != http.StatusOK {
				t.Errorf("rotation -> %d %s", rec.Code, rec.Body)
				return
			}
			keys[i] = strings.TrimSpace(strings.Split(rec.Body.String(), `"`)[3])
		}()
	}
	wg.Wait()
	raw, err := os.ReadFile(filepath.Join(d.Cfg.RunDir(), llmEndpointKeyFile))
	if err != nil {
		t.Fatal(err)
	}
	onDisk := strings.TrimSpace(string(raw))
	accepted := 0
	for _, k := range keys {
		req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
		req.Header.Set("Authorization", "Bearer "+k)
		if d.llmKeyOK(req) {
			accepted++
			if k != onDisk {
				t.Fatalf("the daemon accepts %s... but the file holds %s...", k[:8], onDisk[:8])
			}
		}
	}
	if accepted != 1 {
		t.Fatalf("%d of the %d answered keys are accepted, want exactly the one on disk", accepted, rotations)
	}
}
