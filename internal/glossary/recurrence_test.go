package glossary

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func vettedCandidate(heard, meant string) Pair {
	return Pair{ID: ID(heard), Heard: heard, Meant: meant, Status: Candidate, Vetted: true}
}

// The hash a scan reports for a sentence is the one the store keeps for an agent's context, so one sentence
// is one sighting whoever reports it; sentences split on . ! ? and newlines but not inside node.js.
func TestRecurrenceScanSentences(t *testing.T) {
	r := NewRecurrence([]Pair{vettedCandidate("zorbex", "Zorbax")})
	got := r.Scan("Open Zorbex now. Then node.js and nothing! Zorbex, again?\nlast zorbex")
	id := ID("zorbex")
	want := []string{hash8(key("open zorbex now")), hash8(key("zorbex again")), hash8(key("last zorbex"))}
	if !slices.Equal(got[id], want) || len(got) != 1 {
		t.Fatalf("scan = %v, want %v for %s", got, want, id)
	}
	// An agent's filing of the same sentence lands on the same hash.
	s := NewStore(t.TempDir())
	p, err := s.Add("zorbex", "Zorbax", "Open Zorbex now.")
	if err != nil || p.Sightings[0] != want[0] {
		t.Fatalf("agent sighting = %v, %v; want %s", p.Sightings, err, want[0])
	}
}

// Only a vetted candidate is compiled; a form is matched whole-word and exact.
func TestRecurrenceCompilesOnlyVettedCandidates(t *testing.T) {
	pairs := []Pair{
		vettedCandidate("zorbex", "Zorbax"),
		{ID: ID("plain"), Heard: "plain", Meant: "Plane", Status: Candidate},
		{ID: ID("rejx"), Heard: "rejx", Meant: "Rej", Status: Rejected, Vetted: true},
		{ID: ID("actv"), Heard: "actv", Meant: "Act", Status: Active, Vetted: true},
	}
	got := NewRecurrence(pairs).Scan("zorbex plain rejx actv zorbexes")
	if len(got) != 1 || len(got[ID("zorbex")]) != 1 {
		t.Fatalf("scan = %v, want only zorbex", got)
	}
	var none *Recurrence
	if !NewRecurrence(nil).Empty() || !none.Empty() || none.Scan("zorbex") != nil {
		t.Fatal("an empty or nil matcher must find nothing")
	}
}

// RecordDictation adds one sighting per call, skips a pair that is no longer a vetted candidate, writes nothing when
// it changes nothing, and an old file without seen_dictation reads as 0.
func TestRecordDictation(t *testing.T) {
	home := t.TempDir()
	s := NewStore(home)
	old := `{"version":1,"pairs":[{"id":"` + ID("zorbex") + `","heard":"zorbex","meant":"Zorbax","status":"candidate","seen":1,"vetted":true,"added":"2026-11-01T00:00:00Z"}]}`
	path := filepath.Join(home, FileName)
	if err := os.WriteFile(path, []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	ps, err := s.List()
	if err != nil || ps[0].SeenDictation != 0 {
		t.Fatalf("old file: %+v, %v", ps, err)
	}
	// One dictation is one sighting, however many sentences it found.
	// Mutation: recurrence.go addDictation, delete the `break` -> RED (three sightings from one call).
	rec, err := s.RecordDictation(map[string][]string{ID("zorbex"): {"00000001", "00000002", "00000003"}})
	if err != nil || rec.Sightings != 1 || rec.Activated != 0 {
		t.Fatalf("rec = %+v, %v", rec, err)
	}
	// The next dictation skips what the pair already has and adds the first new hash: needed (2) is reached.
	rec, err = s.RecordDictation(map[string][]string{ID("zorbex"): {"00000001", "00000004", "00000005"}})
	if err != nil || rec.Sightings != 1 || rec.Activated != 1 {
		t.Fatalf("rec = %+v, %v", rec, err)
	}
	ps, _ = s.List()
	if want := []string{"00000001", "00000004"}; !slices.Equal(ps[0].Sightings, want) || ps[0].SeenDictation != 2 || ps[0].Status != Active {
		t.Fatalf("pair = %+v", ps[0])
	}
	// now active: a further call changes nothing and does not rewrite the file
	// Mutation: recurrence.go RecordDictation, delete the `if rec.Sightings == 0 { return }` -> RED (the mtime moves).
	past := time.Now().Add(-time.Hour).Truncate(time.Second)
	if err := os.Chtimes(path, past, past); err != nil {
		t.Fatal(err)
	}
	rec, err = s.RecordDictation(map[string][]string{ID("zorbex"): {"ffffffff"}})
	st, serr := os.Stat(path)
	if err != nil || serr != nil || rec.Sightings != 0 || !st.ModTime().Equal(past) {
		t.Fatalf("rec = %+v, %v; stat %v, %v: the file was rewritten for nothing", rec, err, st, serr)
	}
}

// BenchmarkRecurrenceScan is the cost added to every dictation with a glossary of 100 vetted candidates: a
// 200-word dictation in 20 sentences, 5 of them carrying a heard form.
func BenchmarkRecurrenceScan(b *testing.B) {
	pairs := make([]Pair, 100)
	for i := range pairs {
		pairs[i] = vettedCandidate(fmt.Sprintf("zorbex%dq", i), "Term")
	}
	r := NewRecurrence(pairs)
	text := ""
	for s := range 20 {
		text += "we went over the plan for the quarter and agreed on who sends which update"
		if s%4 == 0 {
			text += fmt.Sprintf(" with zorbex%dq", s)
		}
		text += ". "
	}
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		if len(r.Scan(text)) == 0 {
			b.Fatal("no match")
		}
	}
}

// An agent's filing and a dictation hash a sentence the same way: a context with an internal boundary
// ("Mr. ", «т.е. ») still yields the dictation's sentence hash, so one real sentence is one sighting.
// Mutation: store.go AddChecked, hash8(key(context)) instead of contextHashes -> RED.
func TestAgentFilingHashesLikeADictation(t *testing.T) {
	for _, c := range []struct{ heard, meant, context, sentence string }{
		{"zorbex", "Zorbax", "Mr. Zorbex called.", "Mr Zorbex called"},
		{"зорбекс", "Zorbax", "Это, т.е. зорбекс звонил.", "Это т.е зорбекс звонил"},
		{"zorbex", "Zorbax", "It rained. Then zorbex called! Fine.", "then zorbex called"},
	} {
		s := NewStore(t.TempDir())
		p, err := s.Add(c.heard, c.meant, c.context)
		if err != nil {
			t.Fatal(err)
		}
		r := NewRecurrence([]Pair{{ID: ID(c.heard), Heard: c.heard, Meant: c.meant, Status: Candidate, Vetted: true}})
		got := r.Scan(c.context)[ID(c.heard)]
		if len(p.Sightings) != 1 || !slices.Equal(got, p.Sightings) || got[0] != hash8(key(c.sentence)) {
			t.Fatalf("%q: filing %v, scan %v, want %s", c.context, p.Sightings, got, hash8(key(c.sentence)))
		}
	}
	// A heard form in two sentences of the context: one filing, one sighting.
	s := NewStore(t.TempDir())
	p, err := s.Add("zorbex", "Zorbax", "zorbex one. zorbex two.")
	if err != nil || len(p.Sightings) != 1 {
		t.Fatalf("sightings = %v, %v", p.Sightings, err)
	}
	// A form that spans a cut keeps the whole-context hash.
	p, err = NewStore(t.TempDir()).Add("pill versus", "PV", "x pill. versus y")
	if err != nil || len(p.Sightings) != 1 || p.Sightings[0] != hash8(key("x pill. versus y")) {
		t.Fatalf("spanning form: %v, %v; want the whole-context hash %s", p.Sightings, err, hash8(key("x pill. versus y")))
	}
}

func sentencesOf(text string) []string {
	ws, spans := sentenceSpans(tokenize(text))
	var out []string
	for _, sp := range spans {
		out = append(out, strings.Join(ws[sp[0]:sp[1]], " "))
	}
	return out
}

// A sentence is its words: a dot after an abbreviation, a "?" inside a URL and a missing final dot change no
// sentence, while a real terminator cuts.
// Mutation: recurrence.go isCut, return true as soon as the token holds a sentenceEnds character -> RED.
func TestSentenceCuts(t *testing.T) {
	for _, c := range []struct {
		text string
		want []string
	}{
		{"Mr. Zorbex called.", []string{"mr zorbex called"}},
		{"Mr Zorbex called", []string{"mr zorbex called"}},
		{"See e.g. this one. Next", []string{"see e.g this one", "next"}},
		{"Это т.е. так! Да?", []string{"это т.е так", "да"}},
		{"Open site.org/p?zorbex now. ok", []string{"open site.org p zorbex now", "ok"}},
		{"I use node.js. Then more", []string{"i use node.js", "then more"}},
		{"wait... ok", []string{"wait", "ok"}},
		{"line one\nline two", []string{"line one", "line two"}},
		{"Is it? Yes (see below.) Fine", []string{"is it", "yes see below", "fine"}},
		{"Plan A. Then B", []string{"plan a", "then b"}},
	} {
		if got := sentencesOf(c.text); !slices.Equal(got, c.want) {
			t.Errorf("%q: sentences %q, want %q", c.text, got, c.want)
		}
	}
}

// A stored whole-context hash vouches for a sentence its context carries, within maxContextWords; another
// context, or one that does not carry the sentence, does not.
// Mutation: recurrence.go legacyHash, start i at lo instead of hi-maxContextWords -> RED (the leading run is lost).
func TestLegacyHashMatchesTheContextThatCarriesTheSentence(t *testing.T) {
	ws := words("it rained all day. zorbex called me. then it stopped")
	whole := hashWords(ws)
	own := hashWords(ws[4:7]) // "zorbex called me"
	lead := hashWords(ws[:7]) // "it rained all day zorbex called me"
	for _, c := range []struct {
		name  string
		known []string
		want  string
	}{
		{"whole text", []string{whole}, whole},
		{"leading run", []string{"deadbeef", lead}, lead},
		{"its own hash", []string{own}, own},
		{"another context", []string{hashWords(words("zorbex called you"))}, ""},
		{"no sightings", nil, ""},
	} {
		got, ok := legacyHash(ws, 4, 7, c.known)
		if got != c.want || ok != (c.want != "") {
			t.Errorf("%s: got %q, %v; want %q", c.name, got, ok, c.want)
		}
	}
	long := make([]string, maxContextWords+10)
	for i := range long {
		long[i] = fmt.Sprintf("w%d", i)
	}
	if _, ok := legacyHash(long, len(long)-2, len(long), []string{hashWords(long)}); ok {
		t.Error("a run longer than maxContextWords must not match")
	}
}

// The miss path cuts and hashes nothing: a text without any heard form costs what tokenizing and folding it costs,
// however many sentences it has.
// Mutation: recurrence.go Scan, call sentenceSpans(s.toks) before the loop -> RED (allocations grow with sentences).
func TestScanMissAllocatesNoMoreThanTokenizing(t *testing.T) {
	r := NewRecurrence([]Pair{vettedCandidate("zorbex", "Zorbax")})
	text := strings.Repeat("we went over the plan. Then agreed on who sends what! ", 40)
	base := testing.AllocsPerRun(20, func() {
		for _, tk := range tokenize(text) {
			if tk.word {
				_ = r.first[fold(tk.s)]
			}
		}
	})
	got := testing.AllocsPerRun(20, func() {
		if r.Scan(text) != nil {
			t.Fatal("a miss found something")
		}
	})
	if got > base {
		t.Fatalf("Scan miss allocates %v, tokenize+fold baseline %v", got, base)
	}
}

// The hashes a scan reports per pair are bounded by what the store can take, however many sentences carry the form.
// Mutation: recurrence.go scan.flush, drop the `len(got) > maxSightings` test -> RED.
func TestScanBoundsHashesPerPair(t *testing.T) {
	r := NewRecurrence([]Pair{vettedCandidate("zorbex", "Zorbax")})
	text := ""
	for i := range 40 {
		text += fmt.Sprintf("zorbex number %d here. ", i)
	}
	if got := r.Scan(text)[ID("zorbex")]; len(got) != maxSightings+1 {
		t.Fatalf("hashes = %d, want %d", len(got), maxSightings+1)
	}
}
