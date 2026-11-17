package glossary

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

func activePair(heard, meant string, age int) Pair {
	return Pair{ID: ID(heard), Heard: heard, Meant: meant, Status: Active, Added: time.Unix(1_700_000_000, 0).Add(time.Duration(-age) * time.Hour)}
}

// Spoken forms are the HEARD spellings (what the recogniser wrote), written is the MEANT form.
func TestBoostTermsSpokenIsHeard(t *testing.T) {
	got := BoostTerms([]Pair{
		activePair("оксей", "OxSay", 1),
		activePair("аксей", "OxSay", 2),
		activePair("дэвин", "Devin", 3),
	}, nil)
	want := []string{"OxSay\t1\tоксей\tаксей", "Devin\t1\tдэвин"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("terms = %q, want %q", got, want)
	}
}

// An ordinary Russian word must stay out of the boost list (the decoder would insert it everywhere); the
// term itself and the other forms stay.
func TestBoostTermsDropsCommonSpokenForms(t *testing.T) {
	common := func(h string) bool { return h == "кролик" || h == "кролика" }
	got := BoostTerms([]Pair{
		activePair("кролик", "krolik", 1),
		activePair("кролика", "krolik", 2),
		activePair("кролек", "krolik", 3),
	}, common)
	if len(got) != 1 || got[0] != "krolik\t1\tкролек" {
		t.Fatalf("terms = %q, want only the uncommon form", got)
	}
	all := BoostTerms([]Pair{activePair("кролик", "krolik", 1)}, common)
	if len(all) != 1 || all[0] != "krolik\t1" {
		t.Fatalf("a term whose every form is common keeps its written form: %q", all)
	}
}

func TestBoostTermsFilters(t *testing.T) {
	cand := activePair("кандидат", "Candidate", 1)
	cand.Status = Candidate
	rej := activePair("отклонён", "Rejected", 1)
	rej.Status = Rejected
	got := BoostTerms([]Pair{
		cand, rej,
		activePair("го", "Go", 1),    // meant under 3 characters
		activePair("ab", "Abc", 1),   // heard under 3 characters: term kept, no alias
		activePair("1e5", "OneE", 1), // numeric-looking heard form is an alias, not a weight
		activePair("гитхаб", "GitHub", 2),
		activePair("github", "GitHub", 3), // case-only pair: not its own alias
	}, nil)
	joined := strings.Join(got, "|")
	for _, bad := range []string{"Candidate", "Rejected", "Go\t"} {
		if strings.Contains(joined, bad) {
			t.Fatalf("%q must not be a term: %q", bad, got)
		}
	}
	for _, want := range []string{"Abc\t1", "OneE\t1\t1e5", "GitHub\t1\tгитхаб"} {
		if !strings.Contains(joined+"|", want+"|") {
			t.Fatalf("missing term line %q in %q", want, got)
		}
	}
}

func TestBoostTermsCapAndOrder(t *testing.T) {
	var ps []Pair
	for i := 0; i < 250; i++ {
		ps = append(ps, activePair(fmt.Sprintf("форма%03d", i), fmt.Sprintf("Name%03d", i), i)) // larger i = older
	}
	got := BoostTerms(ps, nil)
	if len(got) != MaxBoostTerms {
		t.Fatalf("terms = %d, want the cap %d", len(got), MaxBoostTerms)
	}
	if !strings.HasPrefix(got[0], "Name000\t") || !strings.HasPrefix(got[199], "Name199\t") {
		t.Fatalf("the most recent must come first and the oldest be cut: first %q last %q", got[0], got[199])
	}
	// aliases are capped too
	var many []Pair
	for i := 0; i < 12; i++ {
		many = append(many, activePair(fmt.Sprintf("вариант%02d", i), "Many", i))
	}
	if n := strings.Count(BoostTerms(many, nil)[0], "\t") - 1; n != maxBoostAliases {
		t.Fatalf("aliases = %d, want %d", n, maxBoostAliases)
	}
}

// The decoder maps boosted spoken forms to the written form (ox-stt); the post-pass still runs on the result.
// The two must be idempotent together: a form the decoder already wrote is not touched again, and a heard
// form that was left out of the boost list (an ordinary word) is still mapped by the post-pass.
func TestPostPassIdempotentWithDecoderMapping(t *testing.T) {
	pairs := []Pair{
		activePair("оксей", "OxSay", 1),
		activePair("кролик", "krolik", 2),
		activePair("гитхаб", "GitHub", 3),
	}
	common := func(h string) bool { return h == "кролик" }
	terms := strings.Join(BoostTerms(pairs, common), "|")
	if !strings.Contains(terms, "OxSay\t1\tоксей") || strings.Contains(terms, "кролик") {
		t.Fatalf("setup: terms = %q", terms)
	}
	// what ox-stt hands back: оксей and гитхаб were boosted and mapped, кролик was not boosted
	decoded := "открой OxSay и GitHub, потом кролик"
	got, n := Apply(decoded, pairs)
	if got != "открой OxSay и GitHub, потом krolik" || n != 1 {
		t.Fatalf("Apply = %q (%d replacements), want only кролик mapped", got, n)
	}
	again, n2 := Apply(got, pairs)
	if again != got || n2 != 0 {
		t.Fatalf("second pass changed the text: %q (%d)", again, n2)
	}
}

// The WRITTEN form is checked too: a meant that is an ordinary word («вкратце», "Pillow") must not be boosted as
// such, or the decoder inserts it into sentences that never said it; its spoken forms still are, and still map back
// to it. A term left with nothing to boost is dropped.
// Mutation: BoostTerms skips the written-form check -> RED.
func TestBoostTermsOrdinaryWrittenFormIsSpokenOnly(t *testing.T) {
	common := func(f string) bool {
		switch f {
		case "вкратце", "Pillow", "кролик", "Opus":
			return true
		}
		return false
	}
	got := BoostTerms([]Pair{
		activePair("в кратцы", "вкратце", 1), // Cyrillic ordinary meant, spoken form not a word
		activePair("пиллоу", "Pillow", 2),    // Latin ordinary meant
		activePair("кролик", "Opus", 3),      // ordinary meant AND ordinary heard: nothing left to boost
		activePair("оксей", "OxSay", 4),      // neither: unchanged
	}, common)
	want := []string{"вкратце\t1\t@spoken-only\tв кратцы", "Pillow\t1\t@spoken-only\tпиллоу", "OxSay\t1\tоксей"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("terms = %q, want %q", got, want)
	}
}

// A meant that would break the term-line format (a tab starts a field, a newline starts a term) never reaches the
// list; a hand-edited glossary.json can hold one. A meant such as "# x" is an ordinary term here: ox-stt has no
// comment syntax, so it cannot be dropped on the other side.
// Mutation: boost.go, drop the wireSafe(p.Meant) check -> RED.
func TestBoostTermsMeantCannotInjectFields(t *testing.T) {
	got := BoostTerms([]Pair{
		activePair("первый", "Evil\tDevin", 1),
		activePair("второй", "Two\nTerms", 2),
		activePair("третий", "Cr\rTerm", 3),
		activePair("хэштег", "# x", 4),
		activePair("оксей", "OxSay", 5),
	}, nil)
	want := []string{"# x\t1\tхэштег", "OxSay\t1\tоксей"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("terms = %q, want %q", got, want)
	}
}

// Limits pinned at their exact edge, so a one-off change of either is seen: the 200th term is kept and the
// 201st dropped; a 3-character meant and a 3-character heard form are kept, 2-character ones dropped.
// Mutations: boost.go:11 MaxBoostTerms 200 -> 201, and boost.go:43 / boost.go:88 minBoostChars compare.
func TestBoostTermsLimitsAtTheEdge(t *testing.T) {
	var ps []Pair
	for i := 0; i < 201; i++ {
		ps = append(ps, activePair(fmt.Sprintf("форма%03d", i), fmt.Sprintf("Name%03d", i), i))
	}
	if got := BoostTerms(ps, nil); len(got) != 200 || !strings.HasPrefix(got[199], "Name199\t") {
		t.Fatalf("terms = %d, want exactly 200 with Name199 last", len(got))
	}
	got := BoostTerms([]Pair{
		activePair("abc", "Xyz", 1), // 3 and 3: both kept
		activePair("ab", "Xyz", 2),  // heard of 2: dropped
		activePair("abc", "Xy", 3),  // meant of 2: dropped
	}, nil)
	if fmt.Sprint(got) != fmt.Sprint([]string{"Xyz\t1\tabc"}) {
		t.Fatalf("terms = %q, want only the 3-character pair", got)
	}
	// characters, not bytes: 3 Cyrillic letters are 6 bytes
	if got := BoostTerms([]Pair{activePair("оксей", "дом", 1)}, nil); len(got) != 1 {
		t.Fatalf("a 3-letter Cyrillic meant must be kept: %q", got)
	}
}

// Only active pairs are a term source, and a non-active spelling of an active meant is not a spoken form.
// Mutation: boost.go:43, p.Status != Active -> p.Status == Rejected -> RED.
func TestBoostTermsActiveOnlyIncludingHeardForms(t *testing.T) {
	cand := activePair("кандидат", "OxSay", 1)
	cand.Status = Candidate
	rej := activePair("отвергнут", "OxSay", 2)
	rej.Status = Rejected
	got := BoostTerms([]Pair{cand, rej, activePair("оксей", "OxSay", 3)}, nil)
	if fmt.Sprint(got) != fmt.Sprint([]string{"OxSay\t1\tоксей"}) {
		t.Fatalf("terms = %q, want only the active spelling", got)
	}
	if got := BoostTerms([]Pair{cand, rej}, nil); len(got) != 0 {
		t.Fatalf("no active pair, no terms: %q", got)
	}
}
