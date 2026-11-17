package codevocab

import (
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/glossary"
)

func TestPacksLoad(t *testing.T) {
	packs := PackTerms()
	if len(packs["python"]) == 0 || len(packs["go"]) == 0 || len(packs["rust"]) == 0 || len(packs["review"]) == 0 {
		t.Fatalf("a pack is missing or empty: %v", maps(packs))
	}
	for name, ts := range packs {
		if name == "review" {
			continue // shared set rides on the language packs' budget, not its own ~80
		}
		if len(ts) > 85 {
			t.Errorf("pack %s carries %d terms, over the ~80 budget", name, len(ts))
		}
	}
}

func maps(p map[string][]Term) map[string]int {
	out := map[string]int{}
	for k, v := range p {
		out[k] = len(v)
	}
	return out
}

// TestPackDataQuality pins the invariants the two mechanisms rely on: written forms that survive the term-line
// format, aliases that are not the written form's own identity, and no folded duplicates inside one entry.
func TestPackDataQuality(t *testing.T) {
	for name, ts := range PackTerms() {
		seenMeant := map[string]bool{}
		for _, term := range ts {
			if strings.ContainsAny(term.Written, "\t\n\r") || strings.TrimSpace(term.Written) == "" {
				t.Errorf("%s: written %q is not wire-safe", name, term.Written)
			}
			mk := glossary.Key(term.Written)
			if seenMeant[mk] {
				t.Errorf("%s: %q is listed twice (same folded form)", name, term.Written)
			}
			seenMeant[mk] = true
			seenHeard := map[string]bool{}
			for _, a := range append(append([]string{}, term.Safe...), term.Unsafe...) {
				if strings.ContainsAny(a, "\t\n\r") || strings.TrimSpace(a) == "" {
					t.Errorf("%s %s: alias %q is not usable", name, term.Written, a)
				}
				ak := glossary.Key(a)
				if ak == mk {
					t.Errorf("%s %s: alias %q is the written form itself", name, term.Written, a)
				}
				if seenHeard[ak] {
					t.Errorf("%s %s: alias %q listed twice (same folded form)", name, term.Written, a)
				}
				seenHeard[ak] = true
			}
		}
	}
}

// TestRequiredAliases pins the aliases the task named: the dunder respellings, the pie/my-pie/num-pie forms,
// and the dotted-Go dictation.
func TestRequiredAliases(t *testing.T) {
	want := map[string][]string{
		"__init__":        {"dunder init"},
		"pytest":          {"pie test"},
		"mypy":            {"my pie"},
		"NumPy":           {"num pie"},
		"sync.WaitGroup":  {"sync dot wait group"},
		"context.Context": {"context dot context"},
	}
	packs := PackTerms()
	for written, aliases := range want {
		found := false
	outer:
		for _, ts := range packs {
			for _, term := range ts {
				if term.Written != written {
					continue
				}
				found = true
				for _, a := range aliases {
					for _, have := range append(append([]string{}, term.Safe...), term.Unsafe...) {
						if glossary.Key(have) == glossary.Key(a) {
							continue outer
						}
					}
					t.Errorf("%s: required alias %q is not in its pack", written, a)
				}
			}
		}
		if !found {
			t.Errorf("term %s is not in any pack", written)
		}
	}
}

// TestBoostPairsShape checks the boost view: an anchor pair per entry plus one pair per safe alias; unsafe
// aliases never appear — a wire alias is decoded and mapped back, which is a rewrite the unsafe flag forbids.
func TestBoostPairsShape(t *testing.T) {
	pairs := BoostPairs([]string{"python"})
	anchors, aliases := 0, 0
	for _, p := range pairs {
		if p.Heard == "" {
			anchors++
			continue
		}
		aliases++
		for _, bad := range []string{"chords", "Tokyo", "type error", "pie test", "my pie"} {
			if glossary.Key(p.Heard) == glossary.Key(bad) {
				t.Errorf("unsafe alias %q reached the boost pairs", p.Heard)
			}
		}
	}
	if anchors != len(PackTerms()["python"])+len(PackTerms()["review"]) {
		t.Errorf("python pack anchors = %d, want python + review entries", anchors)
	}
	if aliases == 0 {
		t.Error("python pack produced no safe alias pairs")
	}
}

// TestBoostPairsPriority: every pack pair's Added is far older than a real glossary pair's, so BoostTerms'
// newest-first order keeps the owner's glossary ahead of the packs — the cap drops pack terms first.
func TestBoostPairsPriority(t *testing.T) {
	pairs := BoostPairs([]string{"python", "go", "rust"})
	for _, p := range pairs {
		if p.Added.Year() > 2000 {
			t.Errorf("pack pair %q Added = %v, must be far older than any glossary pair", p.Heard, p.Added)
		}
	}
}

// TestRewritePairsFused: unsafe aliases join only as fused identifiers — the phrase is the exact spoken form
// and the written form is a single word built of the phrase's words.
func TestRewritePairsFused(t *testing.T) {
	pairs := RewritePairs([]string{"python", "go", "rust"})
	got := map[string]string{}
	for _, p := range pairs {
		got[glossary.Key(p.Heard)] = p.Meant
	}
	joins := map[string]string{
		"type error":            "TypeError",
		"data class":            "dataclass",
		"monkey patch":          "monkeypatch",
		"wait group":            "WaitGroup",
		"not implemented error": "NotImplementedError",
		"beautiful soup":        "BeautifulSoup",
		"doc string":            "docstring",
		"stop iteration":        "StopIteration",
		"attribute error":       "AttributeError",
		"index error":           "IndexError",
		"key error":             "KeyError",
		"value error":           "ValueError",
		"async io":              "asyncio",
	}
	for heard, meant := range joins {
		if got[heard] != meant {
			t.Errorf("fused join %q -> %q missing (got %q)", heard, meant, got[heard])
		}
	}
	for _, never := range []string{
		"chords", "tokyo", "salary", "celery", "bull", "gill", "rough", "tray", "chords", "knit",
		"jason", "union", "optional", "generator", "box", "weight group", "get attribute", "my pie",
		"pie test", "lru cache", "walrus operator", "strake on f test", "uv corn", "c d", "impulse",
		"arc", "option", "pin", "result", "none", "isn't it", "select", "itertools", "a sync", "unit test", "class method", "this error", "air group",
	} {
		if _, bad := got[glossary.Key(never)]; bad {
			t.Errorf("unsafe alias %q must never become a rewrite pair", never)
		}
	}
}

// TestFusedEdges pins the join rule's edges: written phrases cannot be a fusion, single words never join.
func TestFusedEdges(t *testing.T) {
	for _, tc := range []struct {
		spoken, written string
		want            bool
	}{
		{"type error", "TypeError", true},
		{"go routine", "goroutine", true},
		{"walrus operator", "walrus operator", false}, // the written form is a phrase, not a fusion
		{"wait group", "WaitGroup", true},
		{"weight group", "WaitGroup", false}, // different letters
		{"get attribute", "getattr", false},  // not a concat match
		{"tokyo", "tokio", false},            // one word is a mishearing, not a split
		{"my pie", "mypy", false},
		{"pie test", "pytest", false},
		{"lru cache", "lru_cache", false}, // the underscore never comes out of words
		{"a sync", "async", false},        // a one-letter word is an article: "a sync point" is prose
	} {
		if got := fused(tc.spoken, tc.written); got != tc.want {
			t.Errorf("fused(%q, %q) = %v, want %v", tc.spoken, tc.written, got, tc.want)
		}
	}
}

func TestEnabledNormalises(t *testing.T) {
	got := Enabled([]string{"rust", "bogus", "python", "rust"})
	if len(got) != 2 || got[0] != "python" || got[1] != "rust" {
		t.Errorf("Enabled = %v, want [python rust] (canonical order, deduped, unknown dropped)", got)
	}
	if len(Enabled(nil)) != 0 {
		t.Error("nil setting must mean no packs")
	}
}

func TestTermsIncludeReviewWhenAnyPackOn(t *testing.T) {
	if TermCount(nil) != 0 {
		t.Error("no packs -> no terms")
	}
	only := TermCount([]string{"go"})
	withReview := len(PackTerms()["go"]) + len(PackTerms()["review"])
	if only != withReview {
		t.Errorf("one pack on must carry the review set too: %d != %d", only, withReview)
	}
}

// TestWrittenBoostable documents which entries the decoder can boost at all: a written form under three runes
// is dropped by BoostTerms before a cap or a dictionary ever sees it.
func TestWrittenBoostable(t *testing.T) {
	for name, ts := range PackTerms() {
		for _, term := range ts {
			if utf8.RuneCountInString(term.Written) < 3 && len(term.Safe) == 0 {
				t.Logf("%s %s: too short to boost and no safe aliases — dead entry", name, term.Written)
			}
		}
	}
}
