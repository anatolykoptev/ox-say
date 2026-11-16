package glossary

import (
	"sort"
	"strings"
	"unicode/utf8"
)

// Boost-list limits, mirrored by engine/stt/boost.h (kMaxTerms, kMaxAliases, kMinTermChars).
const (
	MaxBoostTerms   = 200
	maxBoostAliases = 8
	minBoostChars   = 3
)

// BoostTerms turns the active pairs into the decoder's term lines, "written<TAB>1<TAB>spoken<TAB>spoken…".
//
// Pairs are grouped by Meant: one term per meant form, written = Meant, spoken = the Heard forms of that
// meant — the spellings the recogniser actually produced for it. The decoder is pushed towards every spoken
// form, and ox-stt maps a decoded spoken form back to the written one on whole words, so the Latin name
// comes out even though Parakeet writes it in Cyrillic when it is said inside Russian speech. The Latin
// Meant itself is a term too (English speech). The weight field is always written out, so a heard form that
// parses as a number ("1e5") is never read as one.
//
// common reports a spoken form that is an ordinary word of the language («кролик»): boosting it makes the
// decoder insert it into sentences that never said it, so such a form is left out of the boost list. The
// post-pass (Apply) still maps it — this only limits what the decoder is pushed towards. A nil common keeps
// every form. The written form (meant) goes through the same check: an ordinary-word meant is marked
// SpokenOnly, so only its spoken forms are boosted, and a term with none left is dropped.
//
// Order: the most recently filed group first, then by Meant, so a cap drops the oldest. At most
// MaxBoostTerms terms and maxBoostAliases spoken forms per term; forms under three characters are dropped
// (ox-stt would drop them anyway).
func BoostTerms(pairs []Pair, common func(heard string) bool) []string {
	type group struct {
		meant  string
		newest int64
		heard  []Pair
	}
	byMeant := map[string]*group{}
	var order []*group
	for _, p := range pairs {
		if p.Status != Active || utf8.RuneCountInString(p.Meant) < minBoostChars || !wireSafe(p.Meant) {
			continue
		}
		g := byMeant[p.Meant]
		if g == nil {
			g = &group{meant: p.Meant}
			byMeant[p.Meant] = g
			order = append(order, g)
		}
		g.heard = append(g.heard, p)
		if t := p.Added.UnixNano(); t > g.newest {
			g.newest = t
		}
	}
	sort.SliceStable(order, func(i, j int) bool {
		if order[i].newest != order[j].newest {
			return order[i].newest > order[j].newest
		}
		return order[i].meant < order[j].meant
	})
	var out []string
	for _, g := range order {
		if len(out) == MaxBoostTerms {
			break
		}
		sort.SliceStable(g.heard, func(i, j int) bool { return g.heard[i].Added.After(g.heard[j].Added) })
		// an ordinary-word written form is not boosted itself (it would be inserted into sentences that never
		// said it); its spoken forms are, and map back to it
		spokenOnly := common != nil && common(g.meant)
		var sb strings.Builder
		sb.WriteString(g.meant)
		sb.WriteString("\t1")
		if spokenOnly {
			sb.WriteString("\t" + SpokenOnly)
		}
		seen := map[string]bool{key(g.meant): true}
		n := 0
		for _, p := range g.heard {
			h := strings.TrimSpace(p.Heard)
			k := key(h)
			if seen[k] || utf8.RuneCountInString(h) < minBoostChars || !wireSafe(h) {
				continue
			}
			if common != nil && common(h) {
				continue
			}
			seen[k] = true
			sb.WriteByte('\t')
			sb.WriteString(h)
			if n++; n == maxBoostAliases {
				break
			}
		}
		if spokenOnly && n == 0 {
			continue // nothing left to boost
		}
		out = append(out, sb.String())
	}
	return out
}

// SpokenOnly is the term-line flag for a written form that is an ordinary word (engine/stt/boost.h kSpokenOnly).
const SpokenOnly = "@spoken-only"

// wireSafe reports a form that survives the term-line format: one term per line, fields split on a tab. The
// glossary's own validation keeps these characters out, but glossary.json is a file a person can edit, and a
// tab or a newline in a meant form would start a new field or a new term in the decoder's list.
func wireSafe(s string) bool { return !strings.ContainsAny(s, "\t\n\r") }
