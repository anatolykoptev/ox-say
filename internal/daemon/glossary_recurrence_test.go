package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/glossary"
	"github.com/anatolykoptev/ox-say/internal/meeting"
	"github.com/anatolykoptev/ox-say/internal/testutil"
)

// Synthetic data only: "zorbex" is a garbled form of the invented term "Zorbax".
const (
	recHeard = "zorbex"
	recMeant = "Zorbax"
	// recSecret is a phrase no log line or glossary byte may ever carry.
	recSecret = "quokkaphrase marmalade"
)

// lockedBuf is a bytes.Buffer the daemon's goroutines may write while the test reads.
type lockedBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuf) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuf) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// dictRig is a daemon whose recognizer is the fake ox-stt: a dictation is a real streaming session
// (create, audio, finish) through the daemon's own routes, and the recognizer says what the test wrote.
type dictRig struct {
	d     *Daemon
	srv   string
	texts string
	log   *lockedBuf
}

func newDictRig(t *testing.T) *dictRig {
	t.Helper()
	dir := t.TempDir()
	fakeEnv(t, dir)
	d := newTestDaemonSTT(t, dir, nil, nil, nil)
	sttSetupServer(t, d, dir)
	sttVADModel(t, d, dir)
	texts := filepath.Join(dir, "texts.json")
	t.Setenv("OXSAY_FAKE_STT_SESSION_TEXTS_FILE", texts)
	buf := &lockedBuf{}
	d.log = slog.New(slog.NewTextHandler(buf, &slog.HandlerOptions{Level: slog.LevelDebug}))
	return &dictRig{d: d, srv: sessBase(transcriptionServer(t, d)), texts: texts, log: buf}
}

// dictate runs one dictation whose recognizer output is the given chunks, and returns the text finish answers.
func (r *dictRig) dictate(t *testing.T, chunks ...string) string {
	t.Helper()
	raw, err := json.Marshal(chunks)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(r.texts, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	code, body := sessReq(t, http.MethodPost, r.srv, "application/json", []byte("{}"))
	if code != http.StatusOK {
		t.Fatalf("create: status %d body %s", code, body)
	}
	var created struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &created); err != nil {
		t.Fatalf("create body = %s", body)
	}
	for i := range chunks {
		if code, body = sessReq(t, http.MethodPost, r.srv+"/"+created.ID+"/audio", "application/octet-stream", bytes.Repeat([]byte{1}, 640)); code != http.StatusOK {
			t.Fatalf("audio %d: status %d body %s", i+1, code, body)
		}
	}
	code, body = sessReq(t, http.MethodPost, r.srv+"/"+created.ID+"/finish", "application/json", []byte("{}"))
	if code != http.StatusOK {
		t.Fatalf("finish: status %d body %s", code, body)
	}
	var fin struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(body, &fin); err != nil {
		t.Fatalf("finish body = %s", body)
	}
	return fin.Text
}

// pair returns the stored pair for a heard form.
func (r *dictRig) pair(t *testing.T, heard string) glossary.Pair {
	t.Helper()
	pairs, err := r.d.Glossary.List()
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range pairs {
		if p.ID == glossary.ID(heard) {
			return p
		}
	}
	t.Fatalf("no pair for %q in %+v", heard, pairs)
	return glossary.Pair{}
}

// candidate files a pair as an agent would, with no sentence: a candidate with Seen 1 and no sightings.
func (r *dictRig) candidate(t *testing.T, heard, meant string, vetted bool) {
	t.Helper()
	if _, _, err := r.d.Glossary.AddChecked(heard, meant, "", vetted); err != nil {
		t.Fatal(err)
	}
	r.d.invalidateGlossary()
}

func wantCounts(t *testing.T, p glossary.Pair, sightings, fromDictation int, status glossary.Status) {
	t.Helper()
	if len(p.Sightings) != sightings || p.SeenDictation != fromDictation || p.Status != status {
		t.Fatalf("pair = sightings %d, seen_dictation %d, status %s; want %d, %d, %s", len(p.Sightings), p.SeenDictation, p.Status, sightings, fromDictation, status)
	}
}

// A vetted candidate's heard form in a new dictation sentence is one sighting from dictation; the same
// sentence dictated again adds nothing; a second distinct sentence reaches needed (2) and the pair turns
// active; the dictation after that gets the correction.
// Mutation: glossary_recurrence.go finishRewrite, delete the d.noteDictation(raw) call -> RED (no sighting).
// Mutation: glossary/recurrence.go addDictation, drop slices.Contains(p.Sightings, h) -> RED (the
// repeated sentence counts again).
func TestDictationRecurrenceCountsAndActivates(t *testing.T) {
	r := newDictRig(t)
	r.candidate(t, recHeard, recMeant, true)

	if got := r.dictate(t, "please open zorbex now."); !strings.Contains(got, recHeard) {
		t.Fatalf("text = %q", got)
	}
	wantCounts(t, r.pair(t, recHeard), 1, 1, glossary.Candidate)

	r.dictate(t, "please open zorbex now.")
	wantCounts(t, r.pair(t, recHeard), 1, 1, glossary.Candidate)

	// The dictation that completes the evidence is answered with the pairs it started with; the next one
	// gets the correction.
	if got := r.dictate(t, "a different zorbex sentence."); !strings.Contains(got, recHeard) {
		t.Fatalf("the activating dictation was already corrected: %q", got)
	}
	wantCounts(t, r.pair(t, recHeard), 2, 2, glossary.Active)
	if got := r.dictate(t, "and zorbex again."); got != "and Zorbax again." {
		t.Fatalf("next dictation = %q, want the correction applied", got)
	}
}

// Two sentences of one dictation are two sightings.
func TestDictationRecurrenceCountsEachSentence(t *testing.T) {
	r := newDictRig(t)
	r.candidate(t, recHeard, recMeant, true)
	r.dictate(t, "first zorbex here. second zorbex there.")
	wantCounts(t, r.pair(t, recHeard), 2, 2, glossary.Active)
}

// A pair with no verdict, or whose heard form is an ordinary word, never gains a passive sighting.
// Mutation: glossary/recurrence.go NewRecurrence and RecordDictation, drop the Vetted conditions (both: the
// store re-checks the verdict) -> RED (the unvetted pair gains sightings and activates).
func TestDictationRecurrenceNeedsAVettedPair(t *testing.T) {
	r := newDictRig(t)
	r.candidate(t, recHeard, recMeant, false)
	// A real filing: the dictionary judges «давайте» an ordinary word, so the pair is not vetted.
	if _, _, err := r.d.glossaryAdd("давайте", "Дайвит", "давайте начнём"); err != nil {
		t.Fatal(err)
	}
	if r.pair(t, "давайте").Vetted {
		t.Fatal("the dictionary vetted an ordinary word; the fixture is wrong")
	}
	before := r.pair(t, "давайте")

	r.dictate(t, "open zorbex now. давайте посмотрим на это.")
	r.dictate(t, "another zorbex sentence. давайте продолжим работу.")
	wantCounts(t, r.pair(t, recHeard), 0, 0, glossary.Candidate)
	after := r.pair(t, "давайте")
	if len(after.Sightings) != len(before.Sightings) || after.SeenDictation != 0 || after.Status != glossary.Candidate {
		t.Fatalf("ordinary-word pair moved: %+v -> %+v", before, after)
	}
}

// A rejected pair is a tombstone: no sighting, still rejected. Only candidates count.
func TestDictationRecurrenceIgnoresRejected(t *testing.T) {
	r := newDictRig(t)
	r.candidate(t, recHeard, recMeant, true)
	if _, err := r.d.Glossary.Reject(glossary.ID(recHeard)); err != nil {
		t.Fatal(err)
	}
	r.d.invalidateGlossary()
	r.dictate(t, "open zorbex now.")
	r.dictate(t, "another zorbex sentence.")
	wantCounts(t, r.pair(t, recHeard), 0, 0, glossary.Rejected)
}

// An owner edit restarts the count: the sightings vouched for the old meant.
func TestDictationRecurrenceRestartsAfterAnEdit(t *testing.T) {
	r := newDictRig(t)
	r.candidate(t, recHeard, recMeant, true)
	r.dictate(t, "open zorbex now.")
	if _, err := r.d.Glossary.Edit(glossary.ID(recHeard), "Zorbix"); err != nil {
		t.Fatal(err)
	}
	r.d.invalidateGlossary()
	wantCounts(t, r.pair(t, recHeard), 0, 0, glossary.Candidate)
}

// A meeting transcript and a file transcription that say the heard form are not dictation. A dictation of
// the same form at the end proves the pair could have counted.
// Mutation: meetings.go initMeetings, call d.noteDictationText(s) in the Correct fixer -> RED (the meeting
// leg gains a sighting).
// Mutation: transcribe.go handleTranscribe, call d.noteDictationText(res.Text) before correctResult -> RED (the file
// leg gains a sighting).
func TestDictationRecurrenceIgnoresMeetingsAndFiles(t *testing.T) {
	r := newDictRig(t)
	r.candidate(t, recHeard, recMeant, true)

	// The meeting leg: a recorded meeting taken through the runner whose recognizer (meetingFixture) ends
	// "...about the next steps", with "steps" a vetted candidate in that daemon's glossary.
	// A subtest, so that daemon's child check closes before the dictation rig spawns its recognizer.
	t.Run("meeting", meetingLegDoesNotCount)

	// The file leg: /v1/audio/transcriptions answers a recognised file that says the heard form.
	payload := `{"engine":"parakeet","language":"en","duration_s":1.5,"elapsed_s":0.2,` +
		`"text":"open zorbex now.","segments":[{"s":0.0,"e":1.5,"text":"open zorbex now."}],` +
		`"words":[{"w":"open","s":0.0,"e":0.4,"p":0.99},{"w":"zorbex","s":0.4,"e":0.9,"p":0.98},{"w":"now.","s":0.9,"e":1.5,"p":0.98}]}`
	t.Setenv("OXSAY_FAKE_STT_JSON", payload)
	url := strings.TrimSuffix(r.srv, "/sessions")
	for range 2 {
		resp := postTranscription(t, url, testutil.TinyWAV(), nil)
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("file transcription status %d", resp.StatusCode)
		}
	}
	wantCounts(t, r.pair(t, recHeard), 0, 0, glossary.Candidate)

	r.dictate(t, "open zorbex now.")
	wantCounts(t, r.pair(t, recHeard), 1, 1, glossary.Candidate)
}

func meetingLegDoesNotCount(t *testing.T) {
	d, mux := meetingFixture(t, nil)
	if _, _, err := d.Glossary.AddChecked("steps", "Stepz", "", true); err != nil {
		t.Fatal(err)
	}
	rec := call(t, mux, http.MethodPost, "/v1/meetings", `{"title":"Plan"}`)
	var created createMeetingResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	writeTone(t, filepath.Join(created.Dir, meeting.MePCM), 30)
	if rec := call(t, mux, http.MethodPost, "/v1/meetings/"+created.ID+"/finish", ""); rec.Code != http.StatusAccepted {
		t.Fatalf("finish = %d %s", rec.Code, rec.Body)
	}
	if err := d.Meet.Process(context.Background(), created.ID); err != nil {
		t.Fatal(err)
	}
	pairs, err := d.Glossary.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(pairs) != 1 || len(pairs[0].Sightings) != 0 || pairs[0].SeenDictation != 0 {
		t.Fatalf("a meeting transcript counted: %+v", pairs)
	}
}

// The raw glossary file never holds a dictated sentence, and the daemon log never holds it or the heard form.
// Mutation: glossary/recurrence.go flush, use the sentence text as the sighting instead of hash8 -> RED.
func TestDictationRecurrenceKeepsNoSentence(t *testing.T) {
	r := newDictRig(t)
	r.candidate(t, recHeard, recMeant, true)
	r.dictate(t, "say "+recSecret+" and zorbex to everyone.")
	wantCounts(t, r.pair(t, recHeard), 1, 1, glossary.Candidate)

	raw, err := os.ReadFile(filepath.Join(r.d.Cfg.Home, glossary.FileName))
	if err != nil {
		t.Fatal(err)
	}
	for _, leak := range []string{"quokkaphrase", "marmalade", "to everyone"} {
		if bytes.Contains(raw, []byte(leak)) {
			t.Fatalf("glossary.json holds %q:\n%s", leak, raw)
		}
	}
	logs := r.log.String()
	if !strings.Contains(logs, "dictation") {
		t.Fatalf("the daemon logged nothing about the sighting:\n%s", logs)
	}
	for _, leak := range []string{"quokkaphrase", "marmalade", "to everyone", recHeard} {
		if strings.Contains(logs, leak) {
			t.Fatalf("the daemon log holds %q:\n%s", leak, logs)
		}
	}
}

// (The store-level mutation for this lives in glossary.TestRecordDictation.)
// Mutation: glossary/recurrence.go RecordDictation, save unconditionally -> RED (the mtime moves).
func TestDictationRecurrenceWritesNothingWithoutAMatch(t *testing.T) {
	r := newDictRig(t)
	r.candidate(t, recHeard, recMeant, true)
	path := filepath.Join(r.d.Cfg.Home, glossary.FileName)
	old := time.Now().Add(-time.Hour).Truncate(time.Second)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	r.dictate(t, "nothing of interest in this sentence.")
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !st.ModTime().Equal(old) || !bytes.Equal(before, after) {
		t.Fatalf("the file was rewritten without a match: mtime %v (want %v)", st.ModTime(), old)
	}
}

// The recognizer's raw output is what counts: an active pair that rewrites the words around the heard form
// does not hide it.
// Mutation: glossary_recurrence.go finishRewrite, call d.noteDictation(out) on the corrected body instead of the raw
// one -> RED (the active pair "zorbex quill" turns the form into "Zq" before it is counted).
func TestDictationRecurrenceCountsTheRawOutput(t *testing.T) {
	r := newDictRig(t)
	r.candidate(t, recHeard, recMeant, true)
	approvedPair(t, r.d, "zorbex quill", "Zq")
	if got := r.dictate(t, "say zorbex quill please."); got != "say Zq please." {
		t.Fatalf("text = %q", got)
	}
	wantCounts(t, r.pair(t, recHeard), 1, 1, glossary.Candidate)
}

// The list answers each pair with needed (the distinct sentences it activates on) and seen_dictation, and an
// empty glossary is an empty array.
func TestGlossaryListCarriesNeededAndSeenDictation(t *testing.T) {
	r := newDictRig(t)
	mux := http.NewServeMux()
	r.d.Routes(mux)
	rec := call(t, mux, http.MethodGet, "/v1/glossary", "")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"pairs":[]`) {
		t.Fatalf("empty list = %d %s", rec.Code, rec.Body)
	}
	r.candidate(t, recHeard, recMeant, true)
	r.candidate(t, "kat", "Cat-Tool", true)
	rec = call(t, mux, http.MethodGet, "/v1/glossary", "")
	var got struct {
		Pairs []struct {
			Heard         string `json:"heard"`
			Needed        int    `json:"needed"`
			SeenDictation *int   `json:"seen_dictation"`
		} `json:"pairs"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil || len(got.Pairs) != 2 {
		t.Fatalf("list = %s (%v)", rec.Body, err)
	}
	for _, p := range got.Pairs {
		want := map[string]int{recHeard: 2, "kat": 3}[p.Heard]
		if p.Needed != want || p.SeenDictation == nil || *p.SeenDictation != 0 {
			t.Fatalf("%s: needed %d seen_dictation %v, want %d and 0", p.Heard, p.Needed, p.SeenDictation, want)
		}
	}
}
