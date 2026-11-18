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
	"slices"
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
//
// A safe alias written in Cyrillic («джойн» for join) or holding a Cyrillic
// letter inside a Latin word («startс») is post-pass only: it is rewritten
// like any safe alias but BoostPairs drops it, so the decoder is never pushed
// towards Cyrillic. The script of the alias is the mark — no field is needed.
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
		dropConflicting(packsData)
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

// dropConflicting removes every safe alias that names two different written forms: one folded
// spoken form must not map to go's "mutex" and rust's "Mutex" — whichever term sorted first would
// win silently. The alias is dropped from every term that carries it, so neither pack keeps it.
func dropConflicting(packs map[string][]Term) {
	target := map[string]string{}
	conflict := map[string]bool{}
	for _, ts := range packs {
		for _, t := range ts {
			for _, a := range t.Safe {
				k := glossary.Key(a)
				if w, ok := target[k]; ok && w != t.Written {
					conflict[k] = true
					continue
				}
				target[k] = t.Written
			}
		}
	}
	if len(conflict) == 0 {
		return
	}
	for n, ts := range packs {
		for i := range ts {
			ts[i].Safe = slices.DeleteFunc(ts[i].Safe, func(a string) bool { return conflict[glossary.Key(a)] })
		}
		packs[n] = ts
	}
}

// AliasOK is the rule a safe alias must meet to be a rewrite: it contains at least one token that is
// not an ordinary word of the English or Russian dictionary, and a purely-Cyrillic token only
// qualifies when it is at least minAliasLetters long, is not spelled like a capitalised name and is
// not a common loanword the dictionaries miss (proseAliases). A lone token faces the same length
// floor in any script — a two-to-four-letter heard form is a name or a prose word too often («ок»,
// "arc"). An alias made only of ordinary words is prose, and prose is never rewritten. The rule
// applies in both languages: «пай тест» and «матч» fail it just as "ice instance" does, and a
// token that mixes scripts («startс») is a word of neither dictionary, so it satisfies the rule on
// its own.
func AliasOK(ck *wordlists.Checker, alias string) bool {
	toks := strings.FieldsFunc(alias, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
	for i, t := range toks {
		// "sync dot once", "re dot match": a spoken dot between two words is how code is dictated, not prose
		if (i > 0 && i < len(toks)-1 && strings.EqualFold(t, "dot")) || aliasTokenOK(ck, t, len(toks) == 1) {
			return true
		}
	}
	return false
}

// minAliasLetters is the shortest token a safe alias may be carried by: a shorter spelling is a
// name or a prose word too often — «ок», «нан», «Пин», "arc".
const minAliasLetters = 5

// proseAliases are the Cyrillic heard forms a safe alias may never carry: spellings ordinary
// speech owns but the dictionaries do not — common loanwords («принт» on a shirt, «крейт» a
// crate), product and pet names («Джойн» a DJ, «Горан») and words a code pack borrowed («серде»
// for serde). The set is the forms review found rewriting real prose; a folded form is the key.
var proseAliases = map[string]bool{
	"арк": true, "арси": true, "аксум": true, "горан": true, "гил": true, "дефер": true,
	"джанго": true, "джойн": true, "джупитер": true, "дроп": true, "крейт": true, "нан": true,
	"ок": true, "пин": true, "принт": true, "рафф": true, "рейз": true, "рейндж": true,
	"рендж": true, "рун": true, "руф": true, "селери": true, "серде": true, "синк": true,
	"тайпинг": true, "трейт": true, "фанк": true, "элиф": true,
}

// aliasTokenOK reports whether one token can carry a safe alias: it is not an ordinary dictionary
// word, and a purely-Cyrillic token is also at least minAliasLetters long, is not spelled like a
// capitalised name («Пин») and is not a proseAliases word — a loanword Hunspell does not know is
// still prose. lone marks the whole-alias case, where the length floor applies whatever the
// script ("arc" is not safer than «арк»).
func aliasTokenOK(ck *wordlists.Checker, t string, lone bool) bool {
	if pureCyrillic(t) {
		if letters(t) < minAliasLetters || startsUpper(t) || proseAliases[glossary.Key(t)] {
			return false
		}
	} else if lone && letters(t) < minAliasLetters {
		return false
	}
	return !ck.Common(t)
}

// pureCyrillic reports whether s holds at least one Cyrillic letter and no Latin one.
func pureCyrillic(s string) bool {
	seen := false
	for _, r := range s {
		switch {
		case unicode.Is(unicode.Latin, r):
			return false
		case unicode.Is(unicode.Cyrillic, r):
			seen = true
		}
	}
	return seen
}

// letters counts the letters of s — digits and marks do not make an alias longer.
func letters(s string) int {
	n := 0
	for _, r := range s {
		if unicode.IsLetter(r) {
			n++
		}
	}
	return n
}

// startsUpper reports whether s opens with an uppercase letter — the shape of a filed name.
func startsUpper(s string) bool {
	for _, r := range s {
		return unicode.IsUpper(r)
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
		pairs = append(pairs, glossary.Pair{Meant: t.Written, Status: glossary.Active, Added: added(), Pack: true})
		for _, a := range t.Safe {
			if hasCyrillic(a) {
				continue // a Cyrillic heard form is a post-pass rewrite, never a wire alias
			}
			pairs = append(pairs, glossary.Pair{Heard: a, Meant: t.Written, Status: glossary.Active, Added: added(), Pack: true})
		}
	}
	return pairs
}

// hasCyrillic reports whether the alias holds a Cyrillic letter.
func hasCyrillic(s string) bool {
	return strings.IndexFunc(s, func(r rune) bool { return unicode.Is(unicode.Cyrillic, r) }) >= 0
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
			pairs = append(pairs, glossary.Pair{Heard: a, Meant: t.Written, Status: glossary.Active, Pack: true})
		}
		for _, a := range t.Unsafe {
			if joinable[t.Written] && fused(a, t.Written) {
				pairs = append(pairs, glossary.Pair{Heard: a, Meant: t.Written, Status: glossary.Active, Pack: true})
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
// phrase is longer ("beautiful" -> Lovely against "beautiful soup" -> BeautifulSoup). The comparison is the
// matcher's own normalisation — the folded word identity transliterated to Latin — so an owner pair written in
// Cyrillic or in a script mix («Stаrts» -> MyBrand) owns the same spoken word the pack alias «startс» does.
func DropOwned(pack, owner []glossary.Pair) []glossary.Pair {
	owned := map[string]bool{}
	for _, o := range owner {
		for _, f := range []string{o.Heard, o.Meant} {
			for _, w := range strings.Fields(glossary.Latinized(glossary.Key(f))) {
				owned[w] = true
			}
		}
	}
	out := make([]glossary.Pair, 0, len(pack))
	for _, p := range pack {
		hit := false
		for _, w := range strings.Fields(glossary.Latinized(glossary.Key(p.Heard))) {
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
