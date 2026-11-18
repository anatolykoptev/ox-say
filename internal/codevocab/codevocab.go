// Package codevocab holds the built-in code vocabulary packs (python, go,
// rust) plus the shared review set that turns on with any of them. Each pack
// entry is the written identifier and two alias lists measured on Parakeet
// TDT 0.6B v3 (~/tmp/code-vocab, 2026-11-17): "safe" heard forms an
// automatic correction may rewrite («Quargs» -> kwargs), and "unsafe" heard
// forms that are natural words or phrases («chords», «Tokyo») — those are
// never rewritten and never reach the decoder's wire aliases, so the boost on
// the written form alone carries them.
//
// The packs produce ordinary glossary.Pair values and ride the glossary's two
// mechanisms untouched: BoostTerms for the decoder boost (the same wire
// format and the same ordinary-word filter) and Apply for the post-pass
// (case-insensitive whole-word rewrites). Nothing here is stored; the user's
// glossary pairs always sort ahead of pack terms, so the term cap drops pack
// terms first.
package codevocab

import (
	"embed"
	"encoding/json"
	"runtime/debug"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/glossary"
	"github.com/anatolykoptev/ox-say/internal/wordlists"
)

//go:embed packs/*.json
var packFiles embed.FS

// Names are the pack ids code_vocabulary accepts, in priority order. The
// shared "review" set is not a choice: it rides with any enabled pack.
var Names = []string{"python", "go", "rust"}

// reviewPack is enabled implicitly whenever any language pack is.
const reviewPack = "review"

// Term is one pack entry. Safe is the heard forms that may be rewritten and
// boosted; Unsafe is the natural words and phrases that may not — an unsafe
// alias produces a rewrite only when it is a fused-identifier spoken form
// (two or more common words whose concatenation is the written form, like
// "type error" for TypeError), and it never becomes a wire alias: the
// ordinary-word filter alone would keep "Tokyo" and "mutex" on the wire
// because they are not dictionary words, and a wire alias is a rewrite.
type Term struct {
	Written string   `json:"written"`
	Safe    []string `json:"safe,omitempty"`
	Unsafe  []string `json:"unsafe,omitempty"`
	// Value ranks the entry for the shared boost budget: 1 = the eval heard it wrong, 2 = partly right, 3 (or
	// unset) = not measured as a problem. A cap keeps the lower numbers.
	Value int `json:"value,omitempty"`
}

// valueOf is Value with the unset default.
func (t Term) valueOf() int {
	if t.Value < 1 || t.Value > defaultValue {
		return defaultValue
	}
	return t.Value
}

const defaultValue = 3

type packJSON struct {
	Name  string `json:"name"`
	Terms []Term `json:"terms"`
}

// packs is the parsed data, read once on first use: a daemon with every pack off never loads it, nor the
// dictionaries the alias check needs.
var (
	packsOnce sync.Once
	packsData map[string][]Term
)

func packs() map[string][]Term {
	packsOnce.Do(func() {
		packsData = loadPacks()
		ck := wordlists.New()
		for n, ts := range packsData {
			for i := range ts {
				ts[i].Safe = filterAliases(ck, ts[i].Safe)
			}
			packsData[n] = ts
		}
		if ck.Err() == nil {
			debug.FreeOSMemory()
		}
	})
	return packsData
}

// filterAliases keeps the safe aliases that pass AliasOK. A dictionary that cannot load keeps none: an alias that
// could not be vetted is never a rewrite.
func filterAliases(ck *wordlists.Checker, in []string) []string {
	var out []string
	for _, a := range in {
		if AliasOK(ck, a) && ck.Err() == nil {
			out = append(out, a)
		}
	}
	return out
}

// AliasOK is the rule a safe alias must meet to be a rewrite: it contains at least one token that is not an ordinary
// word of the English or Russian dictionary (a token with a digit counts as not ordinary). An alias made only of
// ordinary words — "ice instance", "trace back", "under", "dun domain" — is prose, and prose is never rewritten.
// Names (a person's or a product's) are not caught by a dictionary: those aliases are kept out of the data by hand,
// and TestPackAliasesPassTheRule keeps ordinary-word ones out.
func AliasOK(ck *wordlists.Checker, alias string) bool {
	toks := strings.FieldsFunc(alias, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
	for i, t := range toks {
		// "sync dot once", "re dot match": a spoken dot between two words is how code is dictated, not prose
		if (i > 0 && i < len(toks)-1 && strings.EqualFold(t, "dot")) || !ck.Common(t) {
			return true
		}
	}
	return false
}

func loadPacks() map[string][]Term {
	out := map[string][]Term{}
	files, err := packFiles.ReadDir("packs")
	if err != nil {
		return out
	}
	for _, f := range files {
		var p packJSON
		raw, err := packFiles.ReadFile("packs/" + f.Name())
		if err != nil {
			continue
		}
		if json.Unmarshal(raw, &p) == nil && p.Name != "" {
			out[p.Name] = p.Terms
		}
	}
	return out
}

// Enabled normalises a stored code_vocabulary list: unknown ids are dropped,
// duplicates collapse, and the pack order is the canonical Names order. The
// review set follows any language pack, never the stored list.
func Enabled(stored []string) []string {
	set := map[string]bool{}
	for _, n := range stored {
		set[n] = true
	}
	out := []string{}
	for _, n := range Names {
		if set[n] {
			out = append(out, n)
		}
	}
	return out
}

// ValidName reports whether stored names a language pack the setting accepts.
func ValidName(n string) bool {
	for _, v := range Names {
		if v == n {
			return true
		}
	}
	return false
}

// terms is the enabled packs' entries in priority order: language packs in
// the stored (canonical) order, then the shared review set.
func terms(enabled []string) []Term {
	if len(enabled) == 0 {
		return nil
	}
	var out []Term
	for _, n := range enabled {
		out = append(out, packs()[n]...)
	}
	out = append(out, packs()[reviewPack]...)
	// by measured value, terms that were heard wrong first; stable, so a pack keeps its own order within a rank
	sort.SliceStable(out, func(i, j int) bool { return out[i].valueOf() < out[j].valueOf() })
	return out
}

// BoostPairs is the decoder-boost view of the enabled packs as glossary
// pairs: the written form anchors every term (Heard "" is no alias — it only
// opens the meant group), and each safe alias is one heard form. Unsafe
// aliases are deliberately absent: a wire alias is decoded then mapped back
// to the written form, which is a rewrite of the spoken phrase — exactly what
// "unsafe" forbids. Added is synthesised far in the past and decreasing, so
// every real glossary group (and earlier pack entries) sorts first and a cap
// drops the latest pack terms.
func BoostPairs(enabled []string) []glossary.Pair {
	ts := terms(enabled)
	pairs := make([]glossary.Pair, 0, len(ts)*2)
	seq := 0
	added := func() time.Time {
		seq++
		return time.Unix(0, int64(len(ts)*9-seq))
	}
	for _, t := range ts {
		pairs = append(pairs, glossary.Pair{Meant: t.Written, Status: glossary.Active, Added: added()})
		for _, a := range t.Safe {
			pairs = append(pairs, glossary.Pair{Heard: a, Meant: t.Written, Status: glossary.Active, Added: added()})
		}
	}
	return pairs
}

// RewritePairs is the post-pass view: every safe alias rewrites to the
// written form, plus the unsafe aliases that are fused-identifier spoken
// forms — "type error" joins to TypeError because TypeError is a single word
// token made of the spoken phrase's words. Other unsafe aliases ("chords",
// "Tokyo", "my pie") produce nothing: they stay on the decoder boost alone.
func RewritePairs(enabled []string) []glossary.Pair {
	ts := terms(enabled)
	pairs := make([]glossary.Pair, 0, len(ts))
	for _, t := range ts {
		for _, a := range t.Safe {
			pairs = append(pairs, glossary.Pair{Heard: a, Meant: t.Written, Status: glossary.Active})
		}
		for _, a := range t.Unsafe {
			if joinable[t.Written] && fused(a, t.Written) {
				pairs = append(pairs, glossary.Pair{Heard: a, Meant: t.Written, Status: glossary.Active})
			}
		}
	}
	return pairs
}

// fused reports whether spoken is the un-split spelling of a fused
// identifier: two or more words that concatenate, folded, into the written
// form's own folded words — "type error" and TypeError, "go routine" and
// goroutine, but not "walrus operator" (its written form is a phrase, not a
// fusion) and not "weight group" (different letters). The check is the
// glossary's folded word identity on both sides.
func fused(spoken, written string) bool {
	w := glossary.Key(written)
	if strings.Contains(w, " ") {
		return false // a multi-word written form is not a fused identifier
	}
	s := glossary.Key(spoken)
	if !strings.Contains(s, " ") {
		return false // a single word can only be a mishearing, never a split
	}
	for _, word := range strings.Fields(s) {
		if utf8.RuneCountInString(word) < minFusedWord {
			return false // "a sync" -> async would rewrite the ordinary phrase "a sync point"
		}
	}
	return strings.ReplaceAll(s, " ", "") == strings.ReplaceAll(w, " ", "")
}

// minFusedWord is the shortest word a fused-identifier spoken form may contain: a one-letter word is an
// article or an initial, and joining around it would rewrite ordinary prose.
const minFusedWord = 2

// joinable is the allow-list of fused identifiers that may be joined from their spoken words: code-only compounds
// that are not ordinary English once joined — the CamelCase exception names and a few library words. Nothing else
// joins, however well the letters fit: "trace back", "beautiful soup", "hash map", "sub agent" are phrases people
// say, and "go routine" is also "go routine by routine".
var joinable = map[string]bool{
	"TypeError": true, "KeyError": true, "ValueError": true, "IndexError": true, "AttributeError": true,
	"NotImplementedError": true, "StopIteration": true, "dataclass": true, "docstring": true, "asyncio": true,
	"monkeypatch": true, "WaitGroup": true,
}

// DropOwned removes every pack pair that shares a word with an owner pair's heard or meant form: where the owner
// has said anything about a word, the pack says nothing, so an owner pair beats a pack pair even when the pack
// phrase is longer ("beautiful" -> Lovely against "beautiful soup" -> BeautifulSoup).
func DropOwned(pack, owner []glossary.Pair) []glossary.Pair {
	owned := map[string]bool{}
	for _, o := range owner {
		for _, f := range []string{o.Heard, o.Meant} {
			for _, w := range strings.Fields(glossary.Key(f)) {
				owned[w] = true
			}
		}
	}
	out := make([]glossary.Pair, 0, len(pack))
	for _, p := range pack {
		hit := false
		for _, w := range strings.Fields(glossary.Key(p.Heard)) {
			hit = hit || owned[w]
		}
		if !hit {
			out = append(out, p)
		}
	}
	return out
}

// TermCount reports how many entries the enabled set carries — for /status.
func TermCount(enabled []string) int { return len(terms(enabled)) }

// PackTerms exposes the parsed packs for the data tests.
func PackTerms() map[string][]Term { return packs() }
