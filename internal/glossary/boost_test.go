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
