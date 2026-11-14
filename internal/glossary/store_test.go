package glossary

import (
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	s := NewStore(t.TempDir())
	s.Now = func() time.Time { return time.Date(2026, 11, 13, 12, 0, 0, 0, time.UTC) }
	return s
}

// A multi-word pair needs two different sentences, a single word three; the same sentence twice counts once.
// Mutation: store.go needed, return 1 -> RED (a pair from one sentence becomes active).
func TestAddActivatesOnDistinctSentences(t *testing.T) {
	s := newTestStore(t)
	p, err := s.Add("окс сей", "OxSay", "сделай окс сей релиз")
	if err != nil || p.Status != Candidate || p.Seen != 1 {
		t.Fatalf("first add = %+v, %v", p, err)
	}
	p, _ = s.Add("Окс Сей", "OxSay", "сделай окс сей релиз")
	if p.Status != Candidate || p.Seen != 2 || len(p.Sightings) != 1 {
		t.Fatalf("same sentence again = %+v", p)
	}
	if p, _ = s.Add("окс сей", "OxSay", "открой окс сей план"); p.Status != Active {
		t.Fatalf("second sentence = %+v; want active", p)
	}
	for i, ctx := range []string{"про Воксей один", "про Воксей два"} {
		if p, _ = s.Add("Воксей", "OxSay", ctx); p.Status != Candidate {
			t.Fatalf("single word after %d sentences = %+v; want candidate", i+1, p)
		}
	}
	if p, _ = s.Add("Воксей", "OxSay", "про Воксей три"); p.Status != Active {
		t.Fatalf("single word after 3 sentences = %+v; want active", p)
	}
}

// The sentence must contain the heard form, and is stored only as a hash.
// Mutation: store.go Add, append ctx instead of hashCtx(ctx) to Sightings -> RED (the sentence is on disk).
func TestAddStoresNoSentence(t *testing.T) {
	s := newTestStore(t)
	if _, err := s.Add("Воксей", "OxSay", "тут нет этого слова"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("context without the heard form: err = %v, want ErrInvalid", err)
	}
	if _, err := s.Add("Воксей", "OxSay", "секретная фраза про Воксей"); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(s.path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "секретная") {
		t.Fatalf("the dictated sentence was written to disk: %s", raw)
	}
	if info, err := os.Stat(s.path); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v, %v", info.Mode(), err)
	}
}

// A rejected pair stays rejected however often agents file it; only Approve brings it back.
// Mutation: store.go Add, drop the `p.Status != Rejected` guard -> RED (the pair reactivates).
func TestRejectIsSticky(t *testing.T) {
	s := newTestStore(t)
	p, _ := s.Add("окс сей", "OxSay", "про окс сей раз")
	if _, err := s.Reject(p.ID); err != nil {
		t.Fatal(err)
	}
	for _, ctx := range []string{"про окс сей два", "про окс сей три", "про окс сей четыре"} {
		if p, _ = s.Add("окс сей", "OxSay", ctx); p.Status != Rejected {
			t.Fatalf("after reject, add = %+v; want rejected", p)
		}
	}
	if p, _ = s.Approve(p.ID); p.Status != Active {
		t.Fatalf("approve = %+v", p)
	}
	if _, err := s.Reject("ffffffff"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("reject unknown: %v", err)
	}
	if act, _ := s.Active(); len(act) != 1 {
		t.Fatalf("Active() = %d", len(act))
	}
}

// Mutation: store.go Add, delete the `pairs[i].Meant != meant` branch -> RED (the second meaning is accepted).
func TestAddRefusesASecondMeaning(t *testing.T) {
	s := newTestStore(t)
	if _, err := s.Add("окс сей", "OxSay", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Add("Окс  Сей", "OxPulse", ""); !errors.Is(err, ErrConflict) {
		t.Fatalf("err = %v, want ErrConflict", err)
	}
}

// meant lands verbatim in transcripts and subtitles: it is a short term,
// not text — at most four words and sixty characters of letters, digits,
// spaces and . - + _ ' #; anything else is refused.
// Mutation: store.go validate, delete the meant rune check -> RED ("a;b" is filed).
func TestAddValidatesMeantIsATerm(t *testing.T) {
	s := newTestStore(t)
	for i, m := range []string{"a\nb", "a\tb", "a;b", "a=b", "a(b)", "a/b", "a🙂b", "one two three four five"} {
		if _, err := s.Add("voksei", m, ""); !errors.Is(err, ErrInvalid) {
			t.Errorf("meant %q (%d): err = %v, want ErrInvalid", m, i, err)
		}
	}
	for i, m := range []string{"C++", "C#", "it's", "a.b", "foo_bar", "a-b", "one two three four", "Москва"} {
		if _, err := s.Add("voksei"+string(rune('a'+i)), m, ""); err != nil {
			t.Errorf("meant %q: err = %v, want filed", m, err)
		}
	}
}

// The heard form is matched against recognised words, so only word
// characters and spaces are allowed — "node.js" would never match a
// tokenised word and files a dead pair.
// Mutation: store.go validate, delete the heard rune check -> RED ("node.js" is filed).
func TestAddValidatesHeardIsWords(t *testing.T) {
	s := newTestStore(t)
	for _, h := range []string{"node.js", "a+b", "C#", "a;b", "a\nb", "a🙂b"} {
		if _, err := s.Add(h, "term", ""); !errors.Is(err, ErrInvalid) {
			t.Errorf("heard %q: err = %v, want ErrInvalid", h, err)
		}
	}
	for _, h := range []string{"it's", "rock-n-roll", "naïve", "foo bar", "a_b"} {
		if _, err := s.Add(h, "OxSay", ""); err != nil {
			t.Errorf("heard %q: err = %v, want filed", h, err)
		}
	}
}

// Mutation: store.go validate, delete the containsSeq check -> RED ("сей" → "Окс Сей" would grow on every pass).
func TestAddValidates(t *testing.T) {
	s := newTestStore(t)
	for _, c := range []struct{ heard, meant string }{
		{"", "OxSay"}, {"Воксей", ""}, {"...", "OxSay"}, {"-", "—"}, {"раз два три четыре пять", "x"},
		{"сей", "Окс Сей"}, {"OxSay", "OxSay"},
	} {
		if _, err := s.Add(c.heard, c.meant, ""); !errors.Is(err, ErrInvalid) {
			t.Errorf("Add(%q, %q) err = %v, want ErrInvalid", c.heard, c.meant, err)
		}
	}
	if _, err := s.Add("github", "GitHub", ""); err != nil {
		t.Fatalf("case-only pair refused: %v", err)
	}
}

// A malformed file is reported and left as it is.
// Mutation: store.go load, return `nil, nil` on a JSON error -> RED (Add overwrites the file).
func TestMalformedFileIsNotOverwritten(t *testing.T) {
	s := newTestStore(t)
	if err := os.WriteFile(s.path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Add("Воксей", "OxSay", ""); err == nil {
		t.Fatal("Add on a malformed file succeeded")
	}
	if raw, _ := os.ReadFile(s.path); string(raw) != "{not json" {
		t.Fatalf("file changed to %q", raw)
	}
}
