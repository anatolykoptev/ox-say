package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// stubUpstreamHEAD replaces the probe's one network call for the test; the
// default answer is the reason it exists: no test may touch the network.
func stubUpstreamHEAD(t *testing.T, head func(ctx context.Context, url string) (int, error)) {
	t.Helper()
	old := upstreamHEAD
	upstreamHEAD = head
	t.Cleanup(func() { upstreamHEAD = old })
}

// modelsUpstream decodes GET /v1/models into id → upstream field presence.
func modelsUpstream(t *testing.T, mux http.Handler) map[string]string {
	t.Helper()
	rec := call(t, mux, http.MethodGet, "/v1/models", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /v1/models: %d %s", rec.Code, bodyText(rec))
	}
	var list struct {
		Models []struct {
			ID       string `json:"id"`
			Upstream string `json:"upstream"`
		}
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, m := range list.Models {
		out[m.ID] = m.Upstream
	}
	return out
}

// The uncensored row's upstream probe: a taken-down repo reads "gone" while
// the file is not installed — F1's journey. The probe runs in the background
// off the first read, so the test waits for it to land and reads again.
// Mutation: internal/daemon/upstream.go probeNotesUpstream, map 404 to
// "unknown" -> RED (the row never says gone).
func TestNotesUpstreamReportsGoneForATakenDownRepo(t *testing.T) {
	stubUpstreamHEAD(t, func(context.Context, string) (int, error) { return http.StatusNotFound, nil })
	d, mux := meetingFixture(t, nil)
	e := config.NotesModelByID(config.NotesCatalog, "qwen3.8-27b-uncensored")
	if e == nil {
		t.Fatal("the uncensored catalog entry is gone")
	}
	_ = modelsUpstream(t, mux) // the first read kicks the background probe
	testutil.WaitFor(t, 10*time.Second, d.upstream.probed, "the background probe to land")
	up := modelsUpstream(t, mux)
	if up["notes:qwen3.8-27b-uncensored"] != notesUpstreamGone {
		t.Fatalf("uncensored row upstream = %q, want %q", up["notes:qwen3.8-27b-uncensored"], notesUpstreamGone)
	}
	// The same verdict rides the notes-model choices.
	rec := call(t, mux, http.MethodGet, "/v1/meetings/notes-model", "")
	var get struct {
		Choices []struct {
			ID       string `json:"id"`
			Upstream string `json:"upstream"`
		}
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &get); err != nil {
		t.Fatal(err)
	}
	var choiceUp string
	for _, c := range get.Choices {
		if c.ID == "qwen3.8-27b-uncensored" {
			choiceUp = c.Upstream
		} else if c.Upstream != "" {
			t.Fatalf("row %s carries upstream %q — only the uncensored entry probes", c.ID, c.Upstream)
		}
	}
	if choiceUp != notesUpstreamGone {
		t.Fatalf("choice upstream = %q, want %q", choiceUp, notesUpstreamGone)
	}
}

// A network error can never read as "gone" — F2's guarantee: an unreachable
// host is "unknown", because the file may well still be there.
// Mutation: internal/daemon/upstream.go probeNotesUpstream, let `err != nil`
// land in the "gone" bucket -> RED.
func TestNotesUpstreamNeverReadsATransportErrorAsGone(t *testing.T) {
	stubUpstreamHEAD(t, func(context.Context, string) (int, error) {
		return 0, errors.New("dial tcp: no such host")
	})
	d, mux := meetingFixture(t, nil)
	_ = modelsUpstream(t, mux)
	testutil.WaitFor(t, 10*time.Second, d.upstream.probed, "the background probe to land")
	up := modelsUpstream(t, mux)
	got := up["notes:qwen3.8-27b-uncensored"]
	if got == notesUpstreamGone {
		t.Fatal("a transport error read as gone")
	}
	if got != notesUpstreamUnknown {
		t.Fatalf("upstream = %q, want %q", got, notesUpstreamUnknown)
	}
}

// The verdict words for every answer the HEAD can give: only a clear no is
// "gone", only a clear yes is "available", everything else is "unknown".
func TestNotesUpstreamClassifiesTheHeadAnswer(t *testing.T) {
	for _, tc := range []struct {
		code int
		err  error
		want string
	}{
		{http.StatusOK, nil, notesUpstreamAvailable},
		{http.StatusNoContent, nil, notesUpstreamAvailable},
		{http.StatusNotFound, nil, notesUpstreamGone},
		{http.StatusGone, nil, notesUpstreamGone},
		{http.StatusUnauthorized, nil, notesUpstreamGone}, // gated is the same to us as removed
		{http.StatusForbidden, nil, notesUpstreamGone},
		{http.StatusInternalServerError, nil, notesUpstreamUnknown},
		{http.StatusBadGateway, nil, notesUpstreamUnknown},
		{http.StatusFound, nil, notesUpstreamUnknown}, // a redirect that resolved nowhere in 5 hops
		{0, context.DeadlineExceeded, notesUpstreamUnknown},
	} {
		d := &Daemon{}
		d.probeNotesUpstream("https://example.invalid/x.gguf", func(context.Context, string) (int, error) {
			return tc.code, tc.err
		})
		if d.upstream.state != tc.want {
			t.Fatalf("code %d err %v: upstream = %q, want %q", tc.code, tc.err, d.upstream.state, tc.want)
		}
	}
}

// Once the file is on disk the question is moot: no field, and no probe at
// all — the installed model cannot disappear from its host.
func TestNotesUpstreamIsNotProbedOnceInstalled(t *testing.T) {
	var calls atomic.Int64
	stubUpstreamHEAD(t, func(context.Context, string) (int, error) {
		calls.Add(1)
		return http.StatusNotFound, nil
	})
	d := notesDaemon(t, "Huihui-Qwen3.8-27B-abliterated-UD-Q5_K_XL.gguf")
	mux := http.NewServeMux()
	d.Routes(mux)
	up := modelsUpstream(t, mux)
	if got := up["notes:qwen3.8-27b-uncensored"]; got != "" {
		t.Fatalf("an installed uncensored model still reports upstream %q", got)
	}
	// The choices endpoint must not probe for it either.
	rec := call(t, mux, http.MethodGet, "/v1/meetings/notes-model", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET notes-model: %d", rec.Code)
	}
	time.Sleep(50 * time.Millisecond) // a wrongly-fired probe would land here
	if calls.Load() != 0 {
		t.Fatalf("upstream HEAD ran %d times for an installed model", calls.Load())
	}
}

// Concurrent readers share one probe, the verdict is cached for the TTL, and
// a stale cache probes again — the single-flight cache contract.
func TestNotesUpstreamIsSingleFlightAndCached(t *testing.T) {
	release := make(chan struct{})
	var calls atomic.Int64
	stubUpstreamHEAD(t, func(ctx context.Context, url string) (int, error) {
		calls.Add(1)
		select {
		case <-release:
			return http.StatusOK, nil
		case <-ctx.Done():
			return 0, ctx.Err()
		}
	})
	d, _ := meetingFixture(t, nil)
	e := config.NotesModelByID(config.NotesCatalog, "qwen3.8-27b-uncensored")
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if up := d.notesUpstream(e, false); up == "" {
				t.Error("a not-installed uncensored entry reports no upstream field")
			}
		}()
	}
	wg.Wait()
	close(release)
	testutil.WaitFor(t, 10*time.Second, d.upstream.probed, "the probe to land")
	if calls.Load() != 1 {
		t.Fatalf("concurrent reads ran %d probes, want the shared one", calls.Load())
	}
	// Inside the TTL no new probe fires; the clock is injectable.
	now := time.Now()
	d.upstream.now = func() time.Time { return now }
	if got := d.notesUpstream(e, false); got != notesUpstreamAvailable {
		t.Fatalf("cached upstream = %q", got)
	}
	if calls.Load() != 1 {
		t.Fatal("a fresh cache re-probed")
	}
	now = now.Add(notesUpstreamTTL + time.Second)
	_ = d.notesUpstream(e, false)
	testutil.WaitFor(t, 10*time.Second, func() bool { return calls.Load() == 2 }, "a stale cache to re-probe")
}

// The first read before any probe landed is "unknown", not a block on the
// network: the handler's request path never waits for the HEAD.
func TestNotesUpstreamFirstReadIsUnknownNotBlocked(t *testing.T) {
	release := make(chan struct{})
	defer close(release)
	stubUpstreamHEAD(t, func(context.Context, string) (int, error) {
		<-release
		return http.StatusOK, nil
	})
	_, mux := meetingFixture(t, nil)
	up := modelsUpstream(t, mux) // must return while the HEAD is parked
	if got := up["notes:qwen3.8-27b-uncensored"]; got != notesUpstreamUnknown {
		t.Fatalf("unprobed upstream = %q, want %q", got, notesUpstreamUnknown)
	}
}

// compile-time guard: the choices' upstream field is read through the same
// probe state, so a verdict never disagrees between the two surfaces.
func TestNotesUpstreamSurfacesAgree(t *testing.T) {
	stubUpstreamHEAD(t, func(context.Context, string) (int, error) { return http.StatusForbidden, nil })
	d, mux := meetingFixture(t, nil)
	_ = modelsUpstream(t, mux)
	testutil.WaitFor(t, 10*time.Second, d.upstream.probed, "the probe to land")
	row := modelsUpstream(t, mux)["notes:qwen3.8-27b-uncensored"]
	rec := call(t, mux, http.MethodGet, "/v1/meetings/notes-model", "")
	var get struct {
		Choices []struct {
			ID       string `json:"id"`
			Upstream string `json:"upstream"`
		}
	}
	if err := json.NewDecoder(strings.NewReader(rec.Body.String())).Decode(&get); err != nil {
		t.Fatal(err)
	}
	for _, c := range get.Choices {
		if c.ID == "qwen3.8-27b-uncensored" && c.Upstream != row {
			t.Fatalf("row %q vs choice %q disagree", row, c.Upstream)
		}
	}
}
