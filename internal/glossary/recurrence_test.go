package glossary

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
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

// RecordDictation caps at maxSightings, skips a pair that is no longer a vetted candidate, writes nothing when
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
	var hs []string
	for i := range maxSightings + 3 {
		hs = append(hs, fmt.Sprintf("%08x", i))
	}
	rec, err := s.RecordDictation(map[string][]string{ID("zorbex"): hs})
	if err != nil || rec.Sightings != maxSightings || rec.Activated != 1 {
		t.Fatalf("rec = %+v, %v", rec, err)
	}
	ps, _ = s.List()
	if len(ps[0].Sightings) != maxSightings || ps[0].SeenDictation != maxSightings || ps[0].Status != Active {
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
