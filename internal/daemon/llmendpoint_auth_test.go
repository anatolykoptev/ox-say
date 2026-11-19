package daemon

// The endpoint's credential handling (issue #537, review round 1): the key is
// served only to the owner, rotation is one atomic step, a loose key file is
// replaced, and the settings route validates what it stores.

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/meeting"
)

// The settings answer, a successful PUT answer and every unauthenticated key
// request carry no key; the key and its rotation need the owner bearer, and so
// does turning the endpoint on. Mutation: meetings_http.go settingsAnswer,
// add `LLMEndpointKey: d.currentLLMKey()` back (with its json:"llm_endpoint_key"
// field) -> RED (the unauthenticated GET carries the key).
func TestLLMEndpointKeyIsOwnerOnly(t *testing.T) {
	d, mux, _ := llmEndpointFixture(t, nil)
	key := d.currentLLMKey()
	noKey := func(what string, rec *httptest.ResponseRecorder) {
		t.Helper()
		if strings.Contains(rec.Body.String(), key) || strings.Contains(rec.Body.String(), "llm_endpoint_key") {
			t.Fatalf("%s leaks the key: %s", what, rec.Body)
		}
	}

	// Unauthenticated: the settings GET has no key field, whether the endpoint is off or on.
	rec := llmReq(mux, http.MethodGet, "/v1/meetings/settings", "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET settings -> %d", rec.Code)
	}
	noKey("the settings GET", rec)

	// Turning it on without the owner bearer is refused and changes nothing.
	for _, tc := range []struct{ name, bearer string }{
		{"no bearer", ""},
		{"the endpoint key is not the owner token", key},
		{"a wrong bearer", strings.Repeat("cd", 32)},
	} {
		rec := llmReq(mux, http.MethodPut, "/v1/meetings/settings", tc.bearer, `{"llm_endpoint":"on"}`)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("PUT on with %s -> %d, want 401", tc.name, rec.Code)
		}
		noKey("a refused PUT", rec)
	}
	if d.llmEndpointOn() {
		t.Fatal("an unauthenticated PUT turned the endpoint on")
	}
	// Sizing what the endpoint may take is the owner's too.
	for _, body := range []string{`{"llm_endpoint_ctx":65536}`, `{"llm_endpoint_max_s":30}`} {
		if rec := llmReq(mux, http.MethodPut, "/v1/meetings/settings", "", body); rec.Code != http.StatusUnauthorized {
			t.Fatalf("PUT %s without owner -> %d, want 401", body, rec.Code)
		}
	}

	// The key routes.
	for _, method := range []string{http.MethodGet, http.MethodPost} {
		for _, bearer := range []string{"", key, strings.Repeat("cd", 32)} {
			rec := llmReq(mux, method, "/v1/meetings/llm-endpoint/key", bearer, "")
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("%s key with bearer %q -> %d, want 401", method, bearer, rec.Code)
			}
			noKey(method+" key refusal", rec)
		}
	}
	if d.currentLLMKey() != key {
		t.Fatal("an unauthenticated POST rotated the key")
	}

	// With the owner bearer all three succeed, and nothing carrying the key is cacheable.
	rec = llmReq(mux, http.MethodPut, "/v1/meetings/settings", d.ownerToken, `{"llm_endpoint":"on"}`)
	if rec.Code != http.StatusOK || !d.llmEndpointOn() {
		t.Fatalf("owner PUT on -> %d %s", rec.Code, rec.Body)
	}
	noKey("the owner's PUT answer", rec)
	rec = llmReq(mux, http.MethodGet, "/v1/meetings/llm-endpoint/key", d.ownerToken, "")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), key) {
		t.Fatalf("owner GET key -> %d %s", rec.Code, rec.Body)
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
		t.Fatalf("GET key Cache-Control = %q, want no-store", cc)
	}
	rec = llmReq(mux, http.MethodPost, "/v1/meetings/llm-endpoint/key", d.ownerToken, "")
	if rec.Code != http.StatusOK || strings.Contains(rec.Body.String(), key) || !strings.Contains(rec.Body.String(), d.currentLLMKey()) {
		t.Fatalf("owner POST key -> %d %s (want the new key)", rec.Code, rec.Body)
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
		t.Fatalf("POST key Cache-Control = %q, want no-store", cc)
	}
	// A client that echoes the whole GET answer back changes nothing, so it is not refused...
	echo := llmReq(mux, http.MethodGet, "/v1/meetings/settings", "", "").Body.String()
	if rec := llmReq(mux, http.MethodPut, "/v1/meetings/settings", "", echo); rec.Code != http.StatusOK {
		t.Fatalf("an unauthenticated echo of the settings answer -> %d %s, want 200", rec.Code, rec.Body)
	}
	// ...but the same echo with the context raised does.
	raised := strings.Replace(echo, `"llm_endpoint_ctx":131072`, `"llm_endpoint_ctx":262144`, 1)
	if raised == echo {
		t.Fatal("the test's echo has no llm_endpoint_ctx to raise")
	}
	if rec := llmReq(mux, http.MethodPut, "/v1/meetings/settings", "", raised); rec.Code != http.StatusUnauthorized {
		t.Fatalf("an unauthenticated echo that raises the context -> %d, want 401", rec.Code)
	}
	if got := d.Meet.Store.Settings().LLMEndpointCtx; got == 262144 {
		t.Fatal("the refused echo changed the context")
	}
	// Turning it off needs nobody: that only closes a door.
	if rec := llmReq(mux, http.MethodPut, "/v1/meetings/settings", "", `{"llm_endpoint":"off"}`); rec.Code != http.StatusOK || d.llmEndpointOn() {
		t.Fatalf("PUT off -> %d, on=%v", rec.Code, d.llmEndpointOn())
	}
}

// Concurrent rotations leave the file and the daemon agreeing on one key, and a
// reader never sees a torn string. Run under -race.
// Mutation: llmendpoint.go rotateLLMKey, delete the d.llmMu.Lock() /
// defer d.llmMu.Unlock() pair -> RED (the race detector flags the concurrent
// d.llmKey writes, and the file and memory can disagree).
func TestLLMEndpointConcurrentRotationKeepsFileAndMemoryAligned(t *testing.T) {
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	const rotations = 24
	var wg sync.WaitGroup
	for i := 0; i < rotations; i++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			if _, err := d.rotateLLMKey(); err != nil {
				t.Error(err)
			}
		}()
		go func() { // a reader racing the writers
			defer wg.Done()
			req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
			req.Header.Set("Authorization", "Bearer "+strings.Repeat("0", 64))
			_ = d.llmKeyOK(req)
			_ = d.currentLLMKey()
		}()
	}
	wg.Wait()
	raw, err := os.ReadFile(filepath.Join(d.Cfg.RunDir(), llmEndpointKeyFile))
	if err != nil {
		t.Fatal(err)
	}
	onDisk := strings.TrimSpace(string(raw))
	if onDisk != d.currentLLMKey() {
		t.Fatalf("the file holds %s... but the daemon accepts %s...", onDisk[:8], d.currentLLMKey()[:8])
	}
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer "+onDisk)
	if !d.llmKeyOK(req) {
		t.Fatal("the key on disk is not accepted")
	}
}

// A key file readable by group or others is not tightened but replaced: a copy
// may already have leaked. A private file's key is kept.
func TestLLMEndpointLooseKeyFileIsReplaced(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	home := t.TempDir()
	path := filepath.Join(home, llmEndpointKeyFile)
	leaked := strings.Repeat("ab", 32)
	if err := os.WriteFile(path, []byte(leaked+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	got := llmEndpointKey(home, log)
	if got == "" || got == leaked {
		t.Fatalf("a loose key file's key survived: %q", got)
	}
	st, err := os.Stat(path)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("the replaced key file: %v, %v (want 0600)", err, st)
	}
	if again := llmEndpointKey(home, log); again != got {
		t.Fatal("a private key file's key must be kept across starts")
	}
}

// An Authorization header that is present but empty or blank is an OpenAI
// client's attempt: the app's internal catalog is for requests with no header.
func TestLLMEndpointEmptyAuthorizationIsNotTheCatalog(t *testing.T) {
	d, mux, _ := llmEndpointFixture(t, nil)
	get := func(v string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
		req.Header["Authorization"] = []string{v}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec
	}
	for _, v := range []string{"", "   ", "Bearer"} {
		if rec := get(v); rec.Code != http.StatusNotFound || strings.Contains(rec.Body.String(), `"models"`) {
			t.Fatalf("off, Authorization %q -> %d %s, want the endpoint's 404", v, rec.Code, rec.Body)
		}
	}
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	for _, v := range []string{"", "   ", "Bearer"} {
		if rec := get(v); rec.Code != http.StatusUnauthorized || strings.Contains(rec.Body.String(), `"models"`) {
			t.Fatalf("on, Authorization %q -> %d %s, want 401, never the catalog", v, rec.Code, rec.Body)
		}
	}
	if rec := llmReq(mux, http.MethodGet, "/v1/models", "", ""); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"models"`) {
		t.Fatalf("the headerless request lost the catalog: %d", rec.Code)
	}
}

// llm_endpoint_ctx is accepted only inside [the notes context, 1 Mi tokens] and
// stored rounded down to a multiple of 4096; everything else is a 400 and
// changes nothing.
// Mutation: meetings_http.go meetingSettingsIn.validate, delete the
// `*c < meeting.NotesContextTokens() || *c > meeting.LLMEndpointMaxCtx` block
// -> RED (0, 1 and 2 Mi tokens are stored).
func TestLLMEndpointCtxIsValidated(t *testing.T) {
	d, mux, _ := llmEndpointFixture(t, nil)
	put := func(body string) *httptest.ResponseRecorder {
		return llmReq(mux, http.MethodPut, "/v1/meetings/settings", d.ownerToken, body)
	}
	floor := meeting.NotesContextTokens()
	for _, v := range []string{"0", "1", "-4096", strconv.Itoa(floor - 1), "1048577", "2097152", "9223372036854775807"} {
		if rec := put(`{"llm_endpoint_ctx":` + v + `}`); rec.Code != http.StatusBadRequest {
			t.Fatalf("llm_endpoint_ctx %s -> %d, want 400", v, rec.Code)
		}
	}
	if got := d.Meet.Store.Settings().LLMEndpointCtx; got != 0 {
		t.Fatalf("a refused ctx was stored: %d", got)
	}
	for _, tc := range []struct{ in, want int }{
		{floor, floor},
		{floor + 1, floor}, // rounds below the floor: the floor is the lowest ask
		{131073, 131072},
		{131072, 131072},
		{40000, 36864},
		{1 << 20, 1 << 20},
	} {
		rec := put(`{"llm_endpoint_ctx":` + strconv.Itoa(tc.in) + `}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("ctx %d -> %d %s", tc.in, rec.Code, rec.Body)
		}
		if got := d.Meet.Store.Settings().LLMEndpointCtx; got != tc.want {
			t.Fatalf("ctx %d stored as %d, want %d", tc.in, got, tc.want)
		}
	}
	for _, v := range []string{"0", "9", "1201"} {
		if rec := put(`{"llm_endpoint_max_s":` + v + `}`); rec.Code != http.StatusBadRequest {
			t.Fatalf("llm_endpoint_max_s %s -> %d, want 400", v, rec.Code)
		}
	}
}

// The settings GET answers the stored request as llm_endpoint_ctx and what the
// child runs with as llm_endpoint_ctx_effective — two numbers, not one.
func TestLLMEndpointSettingsSeparateRequestedFromEffective(t *testing.T) {
	d, mux, _ := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"off","llm_endpoint_ctx":65536}`)
	rec := llmReq(mux, http.MethodGet, "/v1/meetings/settings", "", "")
	body := rec.Body.String()
	if !strings.Contains(body, `"llm_endpoint_ctx":65536`) {
		t.Fatalf("the request was not reported as asked: %s", body)
	}
	if want := `"llm_endpoint_ctx_effective":` + strconv.Itoa(meeting.NotesContextTokens()); !strings.Contains(body, want) {
		t.Fatalf("off: the effective context is the notes context (%s): %s", want, body)
	}
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	if body := llmReq(mux, http.MethodGet, "/v1/meetings/settings", "", "").Body.String(); !strings.Contains(body, `"llm_endpoint_ctx_effective":65536`) {
		t.Fatalf("on: the effective context follows the ask: %s", body)
	}
	// A client that sends the whole answer back is not refused.
	llmPutSettings(t, d, mux, llmReq(mux, http.MethodGet, "/v1/meetings/settings", "", "").Body.String())
}

// Turning the endpoint off ends a resident child that still holds the large
// context, at the next safe point — and leaves it alone while a notes job is
// queued or running.
func TestLLMEndpointOffRecyclesTheLargeContextChild(t *testing.T) {
	d, mux, dir := llmEndpointFixture(t, nil)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on","llm_endpoint_ctx":65536}`)
	if _, err := d.LLMSup.EnsureReady(t.Context()); err != nil {
		t.Fatal(err)
	}
	if got := len(spawnStamps(t, dir)); got != 1 {
		t.Fatalf("spawns = %d, want 1", got)
	}
	// A notes job is running: off is stored, the child stays.
	d.notesJobs.Add(1)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"off"}`)
	time.Sleep(400 * time.Millisecond)
	if _, live := d.LLMSup.LiveURL(); !live {
		t.Fatal("the child was stopped under a running notes job")
	}
	d.notesJobs.Add(-1)
	// No job: the next off ends it, well before the idle stop.
	llmPutSettings(t, d, mux, `{"llm_endpoint":"on"}`)
	llmPutSettings(t, d, mux, `{"llm_endpoint":"off"}`)
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, live := d.LLMSup.LiveURL(); !live {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("the large-context child stayed resident after the endpoint was turned off")
		}
		time.Sleep(50 * time.Millisecond)
	}
}
