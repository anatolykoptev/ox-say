package daemon

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/anatolykoptev/ox-say/internal/glossary"
	"github.com/anatolykoptev/ox-say/internal/stt"
)

func putPacks(t *testing.T, mux http.Handler, body string) int {
	t.Helper()
	return call(t, mux, "PUT", "/v1/meetings/settings", body).Code
}

// The setting round-trips through GET/PUT, is normalised to the canonical pack order, refuses an unknown pack
// and is shown in /status.
// Mutation: codevocab.go Enabled, return stored unchanged -> RED (order / unknown pack survive).
func TestCodeVocabularySettingRoundTrip(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	if got := settingsOf(t, mux).CodeVocabulary; got == nil || len(got) != 0 {
		t.Fatalf("default = %#v, want an empty list", got)
	}
	if code := putPacks(t, mux, `{"code_vocabulary":["python","cobol"]}`); code != http.StatusBadRequest {
		t.Fatalf("unknown pack: %d, want 400", code)
	}
	if code := putPacks(t, mux, `{"code_vocabulary":["rust","python","rust"]}`); code != http.StatusOK {
		t.Fatalf("PUT = %d", code)
	}
	if got := settingsOf(t, mux).CodeVocabulary; strings.Join(got, ",") != "python,rust" {
		t.Fatalf("GET = %v, want [python rust]", got)
	}
	if st := d.Status().CodeVocabulary; strings.Join(st.Packs, ",") != "python,rust" || st.BoostCap != stt.LegacyTerms {
		t.Fatalf("status = %+v", st)
	}
	if code := putPacks(t, mux, `{"retention_days":7}`); code != http.StatusOK || len(settingsOf(t, mux).CodeVocabulary) != 2 {
		t.Fatal("a PUT that does not name code_vocabulary must leave it alone")
	}
	if code := putPacks(t, mux, `{"code_vocabulary":[]}`); code != http.StatusOK || len(settingsOf(t, mux).CodeVocabulary) != 0 {
		t.Fatal("an empty list must switch the packs off")
	}
}

// Toggling a pack rebuilds the boost list in place, no restart: the glossary term stays first, the pack terms
// follow, and switching off removes them.
// Mutation: meetings_http.go handleMeetingSettingsSet, drop the d.refreshBoost() after a code_vocabulary change
// -> RED (the list still lacks kwargs right after the PUT).
// Mutation: codevocab.go terms, ignore `enabled` (always return every pack) -> RED (kwargs is boosted with the
// setting off).
func TestPackToggleRebuildsBoostGlossaryFirst(t *testing.T) {
	d, _ := boostDaemon(t, map[string]string{"оксей": "OxSay"})
	mux := http.NewServeMux()
	d.Routes(mux)
	has := func(prefix string) bool {
		for _, l := range d.sttBoost().Terms {
			if strings.HasPrefix(l, prefix) {
				return true
			}
		}
		return false
	}
	if has("kwargs\t") || has("Goroutine\t") {
		t.Fatal("packs are off by default: no pack term may be boosted")
	}
	if code := putPacks(t, mux, `{"code_vocabulary":["python","go"]}`); code != http.StatusOK {
		t.Fatalf("PUT = %d", code)
	}
	terms := d.sttBoost().Terms
	if !has("kwargs\t") || !has("sync.WaitGroup\t") {
		t.Fatalf("pack terms missing right after the toggle: %d terms", len(terms))
	}
	if !strings.HasPrefix(terms[0], "OxSay\t") {
		t.Fatalf("the glossary term must lead, got %q", terms[0])
	}
	if code := putPacks(t, mux, `{"code_vocabulary":[]}`); code != http.StatusOK || has("kwargs\t") {
		t.Fatalf("switching the packs off must drop their terms (PUT %d)", code)
	}
}

// The wire an engine gets: the legacy 4 KB / 200-term wire until ox-stt reports the large header; glossary terms
// first either way, so a cap drops pack terms and never a glossary one.
// Mutation: boost.go sttBoost, always `Wide: true` -> RED (the legacy header exceeds 4 KB).
func TestWireIsLegacyUntilTheEngineReportsTheLargeHeader(t *testing.T) {
	dd, _ := boostDaemon(t, map[string]string{"оксей": "OxSay", "дэвин": "Devin"})
	m := http.NewServeMux()
	dd.Routes(m)
	if code := putPacks(t, m, `{"code_vocabulary":["python","go","rust"]}`); code != http.StatusOK {
		t.Fatalf("PUT = %d", code)
	}
	b := dd.sttBoost()
	if b.Wide {
		t.Fatal("an engine that never reported max_terms_header must get the legacy wire")
	}
	legacy := b.Header()
	if len(legacy) == 0 || len(legacy) > stt.LegacyHeaderBytes {
		t.Fatalf("legacy header = %d bytes, want 1..%d", len(legacy), stt.LegacyHeaderBytes)
	}
	_, terms := decodeWire(t, legacy)
	if len(terms) > stt.LegacyTerms || !strings.HasPrefix(terms[0], "Devin\t") || !strings.HasPrefix(terms[1], "OxSay\t") {
		t.Fatalf("legacy wire: %d terms, the glossary (newest first) must lead: %q %q", len(terms), terms[0], terms[1])
	}
	dd.sttWide.Store(true)
	wide := dd.sttBoost()
	if !wide.Wide || len(wide.Header()) <= stt.LegacyHeaderBytes {
		t.Fatalf("a wide engine must get more than the legacy header: %d bytes", len(wide.Header()))
	}
	if st := dd.Status().CodeVocabulary; !st.WideWire || st.BoostCap != stt.MaxTerms || st.BoostTerms <= len(terms) {
		t.Fatalf("status = %+v", st)
	}
}

func fakeHealth(t *testing.T, body string, code int) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(code)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

// The capability probe: only a /health that reports max_terms_header >= the large header makes the wire wide;
// an old engine (no field), garbage, an error status or a dead port all keep it legacy, and none fails the start.
// Mutation: codevocab.go probeSTTCaps, `wide = true` unconditionally -> RED on the old-engine case.
func TestProbeSTTCaps(t *testing.T) {
	d, _ := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	for _, tc := range []struct {
		name, body string
		code       int
		want       bool
	}{
		{"new engine", `{"status":"ok","max_terms_header":16384}`, 200, true},
		{"old engine", `{"status":"ok"}`, 200, false},
		{"smaller than the large header", `{"status":"ok","max_terms_header":4096}`, 200, false},
		{"garbage", `<html>`, 200, false},
		{"error status", `{"max_terms_header":16384}`, 500, false},
	} {
		d.sttWide.Store(!tc.want) // the probe must overwrite whatever an earlier engine said
		if err := d.probeSTTCaps(context.Background(), fakeHealth(t, tc.body, tc.code)); err != nil {
			t.Fatalf("%s: the probe must never fail the engine start: %v", tc.name, err)
		}
		if d.sttWide.Load() != tc.want {
			t.Errorf("%s: wide = %v, want %v", tc.name, d.sttWide.Load(), tc.want)
		}
	}
	d.sttWide.Store(true)
	if err := d.probeSTTCaps(context.Background(), "http://127.0.0.1:1"); err != nil || d.sttWide.Load() {
		t.Errorf("a dead engine: err %v wide %v, want nil and legacy", err, d.sttWide.Load())
	}
}

// The post-pass with the packs on: safe heard forms rewrite, a fused identifier joins on its exact spoken form,
// and no ordinary word or phrase is ever rewritten. With the packs off nothing changes.
// Mutation: codevocab.go RewritePairs, drop the `fused(a, t.Written)` guard -> RED (the unsafe single words
// chords / Tokyo / salary rewrite).
// Mutation: glossary_http.go glossaryPairs, return pairs without the packs' rewrite pairs -> RED.
func TestPackPostPass(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	fix := func() func(string) string { return d.corrector() }
	in := "pass Quargs to the pie test, the type error and the go routine in the data class"
	if out := fix()(in); out != in {
		t.Fatalf("packs off: %q changed to %q", in, out)
	}
	if code := putPacks(t, mux, `{"code_vocabulary":["python","go","rust"]}`); code != http.StatusOK {
		t.Fatalf("PUT = %d", code)
	}
	if out, want := fix()(in), "pass kwargs to the pie test, the TypeError and the goroutine in the dataclass"; out != want {
		t.Fatalf("packs on: %q, want %q", out, want)
	}
	for _, prose := range []string{
		"the chords of the song", "a trip to Tokyo", "the salary and the celery", "a bull and a gill",
		"it is rough", "the tray and the knit", "Jason is optional", "a union and a generator", "a box",
		"a sync point", "all pointer types", "this error is fine", "a unit test", "the class method",
		"the context manager", "air group", "это обычная речь про соль и сахар",
	} {
		if out := fix()(prose); out != prose {
			t.Errorf("ordinary prose %q rewritten to %q", prose, out)
		}
	}
	if code := putPacks(t, mux, `{"code_vocabulary":[]}`); code != http.StatusOK || fix()(in) != in {
		t.Fatal("switching the packs off must stop the rewrites")
	}
}

// A glossary pair and a pack pair for the same heard form: the owner's pair wins in the post-pass.
func TestGlossaryPairBeatsPackPair(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	approvedPair(t, d, "Quargs", "KWARGS-OWNER")
	if code := putPacks(t, mux, `{"code_vocabulary":["python"]}`); code != http.StatusOK {
		t.Fatalf("PUT = %d", code)
	}
	if out, _ := glossary.Apply("Quargs", d.glossaryPairs()); out != "KWARGS-OWNER" {
		t.Fatalf("got %q, the owner's glossary pair must win over the pack", out)
	}
}
