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

// A multi-word pair needs two different sentences, a single word of five letters or more two, a shorter one three;
// the same sentence twice counts once.
// Mutation: store.go needed, return 1 -> RED (a pair from one sentence becomes active). Mutation: store.go needed,
// `n >= 5` -> `n >= 99` -> RED (a 6-letter word needs three sentences).
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
	if p, _ = s.Add("Воксей", "Voksey", "про Воксей один"); p.Status != Candidate {
		t.Fatalf("6-letter word after 1 sentence = %+v; want candidate", p)
	}
	if p, _ = s.Add("Воксей", "Voksey", "про Воксей два"); p.Status != Active {
		t.Fatalf("6-letter word after 2 sentences = %+v; want active", p)
	}
	for i, ctx := range []string{"про вокс один", "про вокс два"} {
		if p, _ = s.Add("вокс", "Vox", ctx); p.Status != Candidate {
			t.Fatalf("4-letter word after %d sentences = %+v; want candidate", i+1, p)
		}
	}
	if p, _ = s.Add("вокс", "Vox", "про вокс три"); p.Status != Active {
		t.Fatalf("4-letter word after 3 sentences = %+v; want active", p)
	}
}

// The evidence for a pair is the distinct sentences any spelling of its meant form was heard in: a term the
// recogniser spells differently each time still activates, in any filing order, and each spelling applies its
// own length threshold. A sentence two spellings share counts once; a rejected spelling, a context-free filing
// and another meant form add nothing.
// Mutation: store.go promote, count only p's own Sightings (use `len(p.Sightings) >= needed(p.Heard)`) -> RED.
func TestActivationCountsPerMeantTerm(t *testing.T) {
	status := func(s *Store, heard string) Status {
		t.Helper()
		list, _ := s.List()
		for _, p := range list {
			if p.Heard == heard {
				return p.Status
			}
		}
		t.Fatalf("no pair for %q", heard)
		return ""
	}
	// Three spellings, one sentence each: the meant form has three sentences.
	forward := []struct{ heard, ctx string }{
		{"квантекс", "открой квантекс сегодня"}, {"кантекс", "запусти кантекс завтра"}, {"квантэкс", "закрой квантэкс вечером"},
	}
	for _, order := range [][]int{{0, 1, 2}, {2, 1, 0}, {1, 2, 0}} {
		s := newTestStore(t)
		for _, i := range order {
			if _, err := s.Add(forward[i].heard, "Quantex", forward[i].ctx); err != nil {
				t.Fatal(err)
			}
		}
		for _, f := range forward {
			if got := status(s, f.heard); got != Active {
				t.Errorf("order %v: %q is %s; want active (three sentences for the meant form)", order, f.heard, got)
			}
		}
	}

	s := newTestStore(t)
	s.Add("квантекс", "Quantex", "открой квантекс сегодня")
	if got := status(s, "квантекс"); got != Candidate {
		t.Fatalf("one sentence: %s", got)
	}
	s.Add("кантекс", "Quantex", "открой кантекс сегодня")
	if got := status(s, "кантекс"); got != Active {
		t.Errorf("a second spelling in a second sentence: %s; want active (6+ letters need two)", got)
	}
	if got := status(s, "квантекс"); got != Active {
		t.Errorf("the first spelling: %s; want active once the meant form has two sentences", got)
	}
	// Short spellings need three sentences for the meant form: two are not enough, the third activates all of them.
	s = newTestStore(t)
	s.Add("квх", "Qvx", "открой квх один")
	s.Add("квкс", "Qvx", "открой квкс два")
	if status(s, "квх") != Candidate || status(s, "квкс") != Candidate {
		t.Fatal("two sentences activated a short spelling")
	}
	s.Add("квэкс", "Qvx", "открой квэкс три")
	for _, h := range []string{"квх", "квкс", "квэкс"} {
		if got := status(s, h); got != Active {
			t.Errorf("%q after three sentences: %s; want active", h, got)
		}
	}

	// The same sentence heard as two spellings is one sentence.
	s = newTestStore(t)
	s.Add("квантекс", "Quantex", "открой квантекс или кантекс")
	s.Add("кантекс", "Quantex", "открой квантекс или кантекс")
	if got := status(s, "кантекс"); got != Candidate {
		t.Errorf("one sentence, two spellings: %s; want candidate", got)
	}

	// A rejected spelling is not evidence, a filing with no sentence activates nothing, another meant form is separate.
	s = newTestStore(t)
	rej, _ := s.Add("квантекс", "Quantex", "открой квантекс сегодня")
	s.Reject(rej.ID)
	s.Add("кантекс", "Quantex", "открой кантекс сегодня")
	if got := status(s, "кантекс"); got != Candidate {
		t.Errorf("after a rejected sibling: %s; want candidate", got)
	}
	s2 := newTestStore(t)
	s2.Add("квантекс", "Quantex", "открой квантекс сегодня")
	s2.Add("кантекс", "Quantix", "открой кантекс сегодня")
	if got := status(s2, "кантекс"); got != Candidate {
		t.Errorf("another meant form: %s; want candidate", got)
	}
	s3 := newTestStore(t)
	s3.Add("квантекс", "Quantex", "открой квантекс сегодня")
	s3.Add("кантекс", "Quantex", "открой кантекс сегодня")
	if p, _ := s3.Add("квантэкс", "Quantex", ""); p.Status != Candidate {
		t.Errorf("a context-free filing of a spelling: %s; want candidate", p.Status)
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

// Edit keeps id, heard and sightings, re-validates meant like Add, and turns a
// rejected pair back into a candidate.
// Mutation: store.go Edit, drop the `validate(...)` call -> RED (5-word meant accepted).
func TestEditRevalidatesAndKeepsStatus(t *testing.T) {
	s := newTestStore(t)
	p, _ := s.Add("окс сей", "OxSay", "сделай окс сей релиз")
	s.Add("окс сей", "OxSay", "открой окс сей план")
	if _, err := s.Approve(p.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Edit(p.ID, "one two three four five"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("5-word meant: err = %v, want ErrInvalid", err)
	}
	if _, err := s.Edit(p.ID, "окс сей рулит"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("meant containing heard: err = %v, want ErrInvalid", err)
	}
	if _, err := s.Edit("ffffffff", "x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown id: err = %v, want ErrNotFound", err)
	}
	got, err := s.Edit(p.ID, " OxPulse ")
	if err != nil || got.Meant != "OxPulse" || got.Status != Active || got.ID != p.ID || got.Heard != "окс сей" || len(got.Sightings) != 2 || got.Seen != 2 {
		t.Fatalf("edit active = %+v, %v", got, err)
	}
	if _, err := s.Reject(p.ID); err != nil {
		t.Fatal(err)
	}
	if got, err = s.Edit(p.ID, "OxSay"); err != nil || got.Status != Candidate {
		t.Fatalf("edit rejected = %+v, %v; want candidate", got, err)
	}
	c, _ := s.Add("гит хаб", "GitHub", "")
	if got, err = s.Edit(c.ID, "Git Hub"); err != nil || got.Status != Candidate {
		t.Fatalf("edit candidate = %+v, %v; want candidate", got, err)
	}
	if list, _ := s.List(); len(list) != 2 {
		t.Fatalf("list = %+v", list)
	}
}

// Purge removes the pair with no tombstone, so the same heard form can be
// filed again as a fresh candidate.
// Mutation: store.go Purge, set the status to Rejected instead of removing -> RED.
func TestPurgeRemovesWithoutTombstone(t *testing.T) {
	s := newTestStore(t)
	p, _ := s.Add("окс сей", "OxSay", "")
	keep, _ := s.Add("гит хаб", "GitHub", "")
	if err := s.Purge("ffffffff"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown id: err = %v", err)
	}
	if err := s.Purge(p.ID); err != nil {
		t.Fatal(err)
	}
	list, _ := s.List()
	if len(list) != 1 || list[0].ID != keep.ID {
		t.Fatalf("list after purge = %+v, want only %s", list, keep.ID)
	}
	if again, err := s.Add("окс сей", "Other", ""); err != nil || again.Status != Candidate || again.Seen != 1 {
		t.Fatalf("refile after purge = %+v, %v; want a fresh candidate", again, err)
	}
}

// An agent must never settle a pair: after the owner edits a rejected pair, the
// old sightings must not let one context-free agent filing activate it.
// Mutation: store.go Edit, drop the Sightings/Seen reset -> RED.
func TestEditOfARejectedPairNeedsFreshEvidence(t *testing.T) {
	s := newTestStore(t)
	p, _ := s.Add("гит хаб", "GitHub", "открой гит хаб один")
	s.Add("гит хаб", "GitHub", "открой гит хаб два")
	if _, err := s.Reject(p.ID); err != nil {
		t.Fatal(err)
	}
	got, err := s.Edit(p.ID, "GitLab")
	if err != nil || got.Status != Candidate || len(got.Sightings) != 0 || got.Seen != 0 {
		t.Fatalf("edit rejected = %+v, %v; want a candidate with no sightings", got, err)
	}
	if a, err := s.Add("гит хаб", "GitLab", ""); err != nil || a.Status != Candidate {
		t.Fatalf("one agent filing after the edit = %+v, %v; want still a candidate", a, err)
	}
	// An owner-edited active pair stays active and keeps its evidence.
	q, _ := s.Add("окс сей", "OxSay", "сделай окс сей релиз")
	s.Add("окс сей", "OxSay", "открой окс сей план")
	if q, _ = s.Approve(q.ID); q.Status != Active {
		t.Fatal(q)
	}
	if e, _ := s.Edit(q.ID, "OxPulse"); e.Status != Active || len(e.Sightings) != 2 {
		t.Fatalf("edit active = %+v", e)
	}
}
