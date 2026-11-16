package daemon

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/config"
	"github.com/anatolykoptev/ox-say/internal/glossary"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// boostDaemon is a daemon with a fake resident ox-stt (sessions on), boosting at alpha 2, and an
// active glossary; the boost list is derived synchronously so a request does not race the build.
func boostDaemon(t *testing.T, pairs map[string]string) (*Daemon, string) {
	t.Helper()
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, func(c *config.Config) { c.STTBoostAlpha = 2 }, nil, nil)
	log := sttSetupServer(t, d, dir)
	sttVADModel(t, d, dir)
	for heard, meant := range pairs {
		approvedPair(t, d, heard, meant)
	}
	d.refreshBoost()
	return d, log
}

// decodeWire reads what the fake logged: the base64url JSON of a header / body.
func decodeWire(t *testing.T, b64 string) (alpha float64, terms []string) {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(b64)
	if err != nil {
		t.Fatalf("not base64url: %v", err)
	}
	var w struct {
		Alpha float64  `json:"alpha"`
		Terms []string `json:"terms"`
	}
	if err := json.Unmarshal(raw, &w); err != nil {
		t.Fatalf("not the wire JSON: %v (%s)", err, raw)
	}
	return w.Alpha, w.Terms
}

func lastField(t *testing.T, lines []string, prefix string) string {
	t.Helper()
	ls := linesWith(lines, prefix)
	if len(ls) == 0 {
		t.Fatalf("no %q line in %v", prefix, lines)
	}
	f := strings.Fields(ls[len(ls)-1])
	return f[len(f)-1]
}

// POST /sessions: the proxied body is replaced by the glossary's boost list — whatever the client sent.
// Mutation: sessions.go handleSTTSessionCreate, pass the client's body through (reqBody nil) -> RED
// (the fake logs the client's {"evil":1} instead of the terms).
func TestSessionCreateCarriesGlossaryTerms(t *testing.T) {
	d, log := boostDaemon(t, map[string]string{"оксей": "OxSay", "дэвин": "Devin"})
	srv := transcriptionServer(t, d)
	code, body := sessReq(t, http.MethodPost, sessBase(srv), "application/json", []byte(`{"evil":1}`))
	if code != http.StatusOK {
		t.Fatalf("create: %d %s", code, body)
	}
	alpha, terms := decodeWire(t, lastField(t, sttLogLines(t, log), "sess-create-body"))
	if alpha != 2 {
		t.Fatalf("alpha = %v, want the configured 2", alpha)
	}
	joined := strings.Join(terms, "|")
	for _, want := range []string{"OxSay\t1\tоксей", "Devin\t1\tдэвин"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("terms %q missing %q", terms, want)
		}
	}
	if strings.Contains(joined, "evil") {
		t.Fatal("the client's body reached ox-stt")
	}
}

// With nothing to boost (empty glossary or alpha 0) the session body is empty — a client body is never
// forwarded.
func TestSessionCreateWithoutTermsSendsNoBody(t *testing.T) {
	for name, edit := range map[string]func(d *Daemon){
		"empty glossary": func(*Daemon) {},
		"alpha 0":        func(d *Daemon) { d.Cfg.STTBoostAlpha = 0 },
	} {
		t.Run(name, func(t *testing.T) {
			pairs := map[string]string{}
			if name == "alpha 0" {
				pairs["оксей"] = "OxSay"
			}
			d, log := boostDaemon(t, pairs)
			edit(d)
			srv := transcriptionServer(t, d)
			if code, body := sessReq(t, http.MethodPost, sessBase(srv), "application/json", []byte(`{"evil":1}`)); code != http.StatusOK {
				t.Fatalf("create: %d %s", code, body)
			}
			if ls := linesWith(sttLogLines(t, log), "sess-create-body"); len(ls) != 0 {
				t.Fatalf("a body reached ox-stt: %v", ls)
			}
		})
	}
}

// One-shot transcription: X-Ox-Terms rides on POST /transcribe, and the common-word filter keeps «кролик»
// out of the spoken forms while the post-pass pair stays.
// Mutation: stt.transcribeServer, drop the X-Ox-Terms header -> RED (no terms line).
// Mutation: glossary.BoostTerms, skip the common() check -> RED (кролик is in the list).
func TestTranscribeCarriesTermsAndFiltersCommonWords(t *testing.T) {
	d, log := boostDaemon(t, map[string]string{"оксей": "OxSay", "кролик": "krolik", "кролек": "krolik"})
	src := testutil.WriteTinyWAV(t, t.TempDir(), "in.wav")
	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	alpha, terms := decodeWire(t, lastField(t, sttLogLines(t, log), "terms "))
	joined := strings.Join(terms, "|")
	if alpha != 2 || !strings.Contains(joined, "OxSay\t1\tоксей") {
		t.Fatalf("alpha %v terms %q", alpha, terms)
	}
	if strings.Contains(joined, "кролик\t") || strings.Contains(joined, "\tкролик") {
		t.Fatalf("the ordinary word кролик is a spoken form: %q", terms)
	}
	if !strings.Contains(joined, "krolik\t1\tкролек") {
		t.Fatalf("the uncommon form of krolik is missing: %q", terms)
	}
}

// voice_add's reference transcript must follow the audio literally: the voice-repair caller never boosts.
// Mutation: voicerepair.go voiceWords, drop NoBoost -> RED (a terms line is logged).
func TestVoiceWordsNeverBoosted(t *testing.T) {
	d, log := boostDaemon(t, map[string]string{"оксей": "OxSay"})
	src := testutil.WriteTinyWAV(t, t.TempDir(), "in.wav")
	if _, err := d.voiceWords(context.Background(), src); err != nil {
		t.Fatal(err)
	}
	if ls := linesWith(sttLogLines(t, log), "terms "); len(ls) != 0 {
		t.Fatalf("voice-clone transcription carried terms: %v", ls)
	}
	if n := len(linesWith(sttLogLines(t, log), "req ")); n != 1 {
		t.Fatalf("server requests = %d, want 1", n)
	}
}

// A glossary edit changes the list for the next request (the generation moves), without a restart.
func TestBoostFollowsGlossaryEdits(t *testing.T) {
	d, log := boostDaemon(t, map[string]string{"оксей": "OxSay"})
	src := testutil.WriteTinyWAV(t, t.TempDir(), "in.wav")
	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	approvedPair(t, d, "дэвин", "Devin")
	d.invalidateGlossary()
	d.refreshBoost()
	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	_, terms := decodeWire(t, lastField(t, sttLogLines(t, log), "terms "))
	if !strings.Contains(strings.Join(terms, "|"), "Devin\t1\tдэвин") {
		t.Fatalf("the new pair is not in the list: %q", terms)
	}
}

// sttBoost never blocks and never fails a request: before the first derivation it returns no terms.
func TestSTTBoostBeforeFirstDerivation(t *testing.T) {
	dir := t.TempDir()
	d := newTestDaemonSTT(t, dir, func(c *config.Config) { c.STTBoostAlpha = 2 }, nil, nil)
	approvedPair(t, d, "оксей", "OxSay")
	b := d.sttBoost()
	if b.Active() {
		t.Fatalf("boost before the first derivation = %+v, want inactive", b)
	}
	// let the background derivation finish before the test's home goes away
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		d.tbMu.Lock()
		done := d.tbHave && !d.tbBuilding
		d.tbMu.Unlock()
		if done {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if b = d.sttBoost(); !b.Active() || !strings.Contains(strings.Join(b.Terms, "|"), "OxSay\t1\tоксей") {
		t.Fatalf("boost after the derivation = %+v", b)
	}
}

// ox-stt keeps ONE built graph (its cache key is the list text), so the session body and the /transcribe header
// must carry the same list, or alternating requests rebuild the graph every time. A glossary too big for the 4 KB
// header is trimmed for both.
// Mutation: sessions.go sessionBoostBody, JSON(stt.MaxBodyBytes) instead of the shared budget -> RED.
func TestSessionAndHeaderCarryTheSameList(t *testing.T) {
	pairs := map[string]string{}
	for i := 0; i < 120; i++ {
		pairs[fmt.Sprintf("форма%03dтест", i)] = fmt.Sprintf("Name%03dLong", i)
	}
	d, log := boostDaemon(t, pairs)
	srv := transcriptionServer(t, d)
	if code, body := sessReq(t, http.MethodPost, sessBase(srv), "application/json", []byte("{}")); code != http.StatusOK {
		t.Fatalf("create: %d %s", code, body)
	}
	src := testutil.WriteTinyWAV(t, t.TempDir(), "in.wav")
	if _, err := d.Transcribe(context.Background(), TranscribeInput{AudioPath: src}); err != nil {
		t.Fatal(err)
	}
	lines := sttLogLines(t, log)
	_, fromBody := decodeWire(t, lastField(t, lines, "sess-create-body"))
	_, fromHeader := decodeWire(t, lastField(t, lines, "terms "))
	if len(fromHeader) == 0 || len(fromHeader) >= 120 {
		t.Fatalf("the header list should be trimmed (got %d terms)", len(fromHeader))
	}
	if strings.Join(fromBody, "|") != strings.Join(fromHeader, "|") {
		t.Fatalf("session body has %d terms, header %d: the lists differ", len(fromBody), len(fromHeader))
	}
}

// A sighting of an existing pair rewrites glossary.json (Seen, Sightings) but changes no meant/heard form: the list
// is not derived again, so the dictionary is not reloaded mid-call for nothing.
// Mutation: boost.go sttBoost, key the list on the pair generation (glGen) -> RED.
func TestSightingDoesNotRederiveTheList(t *testing.T) {
	d, _ := boostDaemon(t, map[string]string{"оксей": "OxSay"})
	before := d.tbDerives.Load()
	if _, err := d.Glossary.Add("оксей", "OxSay", "я читал про оксей вчера"); err != nil {
		t.Fatal(err)
	}
	d.invalidateGlossary()
	for i := 0; i < 3; i++ {
		d.sttBoost()
	}
	time.Sleep(300 * time.Millisecond)
	if n := d.tbDerives.Load(); n != before {
		t.Fatalf("derivations after a sighting = %d, want %d (unchanged)", n, before)
	}
}

// A derivation judges only the forms it has not judged before: filing one more pair does not load a dictionary for
// the forms already in the memo.
// Mutation: boost.go boostTermsFor, ignore the verdict memo -> RED.
func TestVerdictMemoSparesTheDictionary(t *testing.T) {
	d, _ := boostDaemon(t, map[string]string{"оксей": "OxSay"})
	before := d.tbChecks.Load()
	approvedPair(t, d, "дэвин", "Devin")
	d.invalidateGlossary()
	d.refreshBoost()
	if n := d.tbChecks.Load() - before; n != 2 {
		t.Fatalf("forms judged for one new pair = %d, want 2 (its meant and its heard form)", n)
	}
}

// The first dictation after a start is boosted: the daemon derives the list once at start, not on the first request.
// Mutation: glossary_http.go initGlossary, drop the d.sttBoost() kick -> RED.
func TestListIsDerivedAtStart(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	st := glossary.NewStore(filepath.Join(dir, "home"))
	p, err := st.Add("оксей", "OxSay", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Approve(p.ID); err != nil {
		t.Fatal(err)
	}
	d := newTestDaemonSTT(t, dir, func(c *config.Config) { c.STTBoostAlpha = 2 }, nil, nil)
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		d.tbMu.Lock()
		done := d.tbHave && len(d.tbTerms) > 0
		d.tbMu.Unlock()
		if done {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("no boost list was derived at daemon start")
}

// A glossary whose list does not fit the wire budget loses its oldest terms; the daemon says how many (a count,
// never the terms) so a long glossary is not silently half-boosted.
// Mutation: boost.go deriveBoost, drop the Dropped() warning -> RED.
func TestOverBudgetListIsReportedByCount(t *testing.T) {
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, func(c *config.Config) { c.STTBoostAlpha = 2 }, nil, nil)
	var buf bytes.Buffer
	d.log = slog.New(slog.NewTextHandler(&buf, nil))
	letters := "абвгдежзиклмнопрстуф"
	for i := 0; i < 150; i++ {
		heard := "звучание" + string([]rune(letters)[i/20]) + string([]rune(letters)[i%20]) + "ааааааааааааааа"
		approvedPair(t, d, heard, fmt.Sprintf("Name%c%cxxxxxxxxxxxxxxxxxxxx", 'a'+rune(i/20), 'a'+rune(i%20)))
	}
	d.refreshBoost()
	b := d.sttBoost()
	n := b.Dropped()
	if n == 0 || len(b.Terms) != 150 {
		t.Fatalf("setup: %d terms, %d dropped; the list must exceed the budget", len(b.Terms), n)
	}
	got := buf.String()
	if !strings.Contains(got, fmt.Sprintf("dropped=%d", n)) {
		t.Fatalf("log = %q, want dropped=%d", got, n)
	}
	if strings.Contains(got, "Name") || strings.Contains(got, "звучание") {
		t.Fatalf("terms reached the log: %q", got)
	}
}
