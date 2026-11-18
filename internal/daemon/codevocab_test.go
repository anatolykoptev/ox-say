package daemon

import (
	"context"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"fmt"
	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/glossary"
	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/anatolykoptev/ox-say/internal/stt"
	"github.com/anatolykoptev/ox-say/internal/testutil"
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
	if st := d.Status().CodeVocabulary; strings.Join(st.Packs, ",") != "python,rust" || st.BoostCap != glossary.MaxBoostTerms {
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
	if out, want := fix()(in), "pass kwargs to the pie test, the TypeError and the go routine in the dataclass"; out != want {
		t.Fatalf("packs on: %q, want %q", out, want)
	}
	for _, prose := range []string{
		"the chords of the song", "a trip to Tokyo", "the salary and the celery", "a bull and a gill",
		"it is rough", "the tray and the knit", "Jason is optional", "a union and a generator", "a box",
		"a sync point", "all pointer types", "this error is fine", "a unit test", "the class method",
		"the context manager", "air group", "это обычная речь про соль и сахар", "Can you trace back the payment?",
		"That was a beautiful soup.", "Please go routine by routine.", "Мне нравится beautiful soup.",
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

// Packs off is main: the decoder lines are exactly the owner's lines and the post-pass pairs are exactly the owner's
// pairs, in order. The packs only ever ADD after the owner.
// Mutation: boost.go withPackTerms, drop the `len(packs) == 0` early return AND append unconditionally -> RED.
func TestPacksOffIsMain(t *testing.T) {
	d, _ := boostDaemon(t, map[string]string{"оксей": "OxSay", "дэвин": "Devin", "томл": "TOML"})
	owner, _ := d.glossaryPairsGen()
	if got, want := d.sttBoost().Terms, d.boostTermsFor(owner); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("packs off: boost lines %q differ from the owner-only derivation %q", got, want)
	}
	if got := d.glossaryPairs(); len(got) != len(owner) {
		t.Fatalf("packs off: %d post-pass pairs, the owner has %d", len(got), len(owner))
	}
	for i, p := range d.glossaryPairs() {
		if !reflect.DeepEqual(p, owner[i]) {
			t.Fatalf("pair %d differs from the owner's", i)
		}
	}
}

// Owner lines are untouchable: with packs on they are a byte-identical prefix of the list, a pack never joins an
// owner's group (the owner's TOML keeps its own aliases), and a pack line naming an owner's written form is dropped.
// Mutation: boost.go sttBoost/deriveBoost, derive from owner+pack pairs together (the old merge) -> RED.
func TestOwnerLinesAreAPrefixAndPacksNeverJoinThem(t *testing.T) {
	d, _ := boostDaemon(t, map[string]string{"оксей": "OxSay", "томл": "TOML", "дэвин": "Devin"})
	mux := http.NewServeMux()
	d.Routes(mux)
	off := append([]string{}, d.sttBoost().Terms...)
	if code := putPacks(t, mux, `{"code_vocabulary":["python","go","rust"]}`); code != http.StatusOK {
		t.Fatalf("PUT = %d", code)
	}
	on := d.sttBoost().Terms
	if len(on) <= len(off) {
		t.Fatalf("packs added nothing: %d vs %d", len(on), len(off))
	}
	for i, l := range off {
		if on[i] != l {
			t.Fatalf("owner line %d changed: %q -> %q", i, l, on[i])
		}
	}
	for _, l := range on[len(off):] {
		if strings.HasPrefix(l, "TOML\t") || strings.HasPrefix(l, "OxSay\t") {
			t.Fatalf("a pack line %q repeats an owner's written form", l)
		}
	}
}

// With an owner-sized glossary (~95 pairs, ~1.7 KB of term lines) and every pack on, no owner line is trimmed by
// the wire budget and pack lines fill what is left.
// Mutation: stt boost.go Fit, ranging over the list tail-first -> RED in internal/stt; here, the owner lines are first.
func TestOwnerGlossaryFitsBeforeThePacks(t *testing.T) {
	pairs := map[string]string{}
	for i := 0; i < 95; i++ {
		pairs[fmt.Sprintf("оксей%02d", i)] = fmt.Sprintf("Name%02d", i)
	}
	d, _ := boostDaemon(t, pairs)
	mux := http.NewServeMux()
	d.Routes(mux)
	owner := len(d.sttBoost().Terms)
	if code := putPacks(t, mux, `{"code_vocabulary":["python","go","rust"]}`); code != http.StatusOK {
		t.Fatalf("PUT = %d", code)
	}
	b := d.sttBoost()
	fit := b.Fit(stt.MaxWireJSON)
	if fit < owner {
		t.Fatalf("the wire fits %d lines, the owner has %d: an owner term is trimmed", fit, owner)
	}
	if fit == owner || len(b.JSON(stt.MaxWireJSON)) > stt.MaxWireJSON {
		t.Fatalf("no pack line fits after %d owner lines (fit %d)", owner, fit)
	}
}

// An owner pair beats a pack pair in the post-pass even when the pack phrase is longer.
// Mutation: glossary_http.go glossaryPairs, `d.packFixPairs(pairs)` -> `d.packFixPairs(nil)` -> RED.
func TestOwnerPairBeatsLongerPackPair(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	t.Cleanup(d.Shutdown)
	approvedPair(t, d, "dunder", "Dunder")
	if code := putPacks(t, mux, `{"code_vocabulary":["python"]}`); code != http.StatusOK {
		t.Fatalf("PUT = %d", code)
	}
	if out := d.corrector()("call dunder init now"); out != "call Dunder init now" {
		t.Fatalf("got %q, the owner's pair must win over the longer pack pair", out)
	}
}

// A daemon started with packs already saved boosts them on the FIRST decode, with no settings PUT: the boost list was
// first derived before the settings store existed, and the key now includes the packs.
// Mutation: service.go, drop the `d.refreshBoost()` after initMeetings, and boost.go key without packs -> RED.
func TestSavedPacksBoostAfterRestart(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d1 := newTestDaemonSTT(t, dir, func(c *config.Config) { c.STTBoostAlpha = 2 }, nil, nil)
	mux := http.NewServeMux()
	d1.Routes(mux)
	if code := putPacks(t, mux, `{"code_vocabulary":["python"]}`); code != http.StatusOK {
		t.Fatalf("PUT = %d", code)
	}
	d1.Shutdown()
	d2 := newTestDaemonSTT(t, dir, func(c *config.Config) { c.STTBoostAlpha = 2 }, nil, nil)
	log := sttSetupServer(t, d2, dir)
	sttVADModel(t, d2, dir)
	src := testutil.WriteTinyWAV(t, t.TempDir(), "in.wav")
	if _, err := d2.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	_, terms := decodeWire(t, lastField(t, sttLogLines(t, log), "terms "))
	if !strings.Contains(strings.Join(terms, "|"), "kwargs\t") {
		t.Fatalf("saved packs were not boosted on the first decode: %d terms", len(terms))
	}
}

// The boost cache key includes the enabled packs: a settings change that does not go through the PUT handler (a
// settings file edited, a store that was not ready at start) is still seen by the next request.
// Mutation: boost.go sttBoost, `d.tbCurKey = d.tbGlKey + "|" + strings.Join(packs, ",")` -> `d.tbCurKey = d.tbGlKey`
// -> RED (the pack never reaches the list).
func TestPackChangeWithoutRefreshIsSeen(t *testing.T) {
	d, _ := boostDaemon(t, map[string]string{"оксей": "OxSay"})
	if err := d.Meet.Store.UpdateSettings(func(cur meeting.Settings, _ error) (meeting.Settings, error) {
		cur.CodeVocabulary = []string{"python"}
		return cur, nil
	}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 100; i++ {
		for _, l := range d.sttBoost().Terms {
			if strings.HasPrefix(l, "kwargs\t") {
				return
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("a pack enabled behind the handler's back never reached the boost list")
}

// An owner correction is not swallowed in the decoder: the engine tries the longest spoken form first, so a pack line
// whose spoken form CONTAINS an owner's form ("dunder init" vs the owner's "dunder") is not sent at all, and the
// post-pass keeps the owner's rewrite.
// Mutation: codevocab.go withPackTerms, drop the `containsOwnerForm` check -> RED (the __init__ line is on the wire).
func TestPackLineContainingAnOwnerFormIsNotSent(t *testing.T) {
	d, _ := boostDaemon(t, map[string]string{"dunder": "Dundar"})
	mux := http.NewServeMux()
	d.Routes(mux)
	if code := putPacks(t, mux, `{"code_vocabulary":["python"]}`); code != http.StatusOK {
		t.Fatalf("PUT = %d", code)
	}
	for _, l := range d.sttBoost().Terms {
		if strings.HasPrefix(l, "__init__\t") || strings.Contains(l, "\tdunder init") {
			t.Fatalf("a pack line that contains the owner's form reached the wire: %q", l)
		}
	}
	if out := d.corrector()("call dunder init now"); out != "call Dundar init now" {
		t.Fatalf("post-pass = %q, want the owner's rewrite", out)
	}
}

// Packs disabled behind the handler's back (the settings file edited) between two requests: the second request
// carries no pack lines, never the old list. And the rebuild it does is cheap; the time is logged.
// Mutation: boost.go sttBoost, return the cached list on a key change (drop the `d.tbPacks != packKey` branch) -> RED.
func TestDisabledPacksAreGoneOnTheNextRequest(t *testing.T) {
	d, _ := boostDaemon(t, map[string]string{"оксей": "OxSay"})
	m := http.NewServeMux()
	d.Routes(m)
	hasPack := func() bool {
		for _, l := range d.sttBoost().Terms {
			if strings.HasPrefix(l, "kwargs\t") {
				return true
			}
		}
		return false
	}
	if code := putPacks(t, m, `{"code_vocabulary":["python"]}`); code != http.StatusOK || !hasPack() {
		t.Fatalf("packs on: PUT %d, pack line present %v", code, hasPack())
	}
	set := func(packs []string) {
		if err := d.Meet.Store.UpdateSettings(func(cur meeting.Settings, _ error) (meeting.Settings, error) {
			cur.CodeVocabulary = packs
			return cur, nil
		}); err != nil {
			t.Fatal(err)
		}
	}
	set(nil) // the settings file changes behind the handler's back
	start := time.Now()
	if hasPack() {
		t.Fatal("the request after the change still carried the old pack lines")
	}
	t.Logf("rebuild on the request after a pack change: %v", time.Since(start))
	set([]string{"python"})
	start = time.Now()
	if !hasPack() {
		t.Fatal("the request after enabling carried no pack lines")
	}
	t.Logf("rebuild with packs on: %v", time.Since(start))
}
