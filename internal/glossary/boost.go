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
// every form. A meant that is itself an ordinary word keeps its term, with no spoken form.
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
		if p.Status != Active || utf8.RuneCountInString(p.Meant) < minBoostChars {
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
		var sb strings.Builder
		sb.WriteString(g.meant)
		sb.WriteString("\t1")
		seen := map[string]bool{key(g.meant): true}
		n := 0
		for _, p := range g.heard {
			h := strings.TrimSpace(p.Heard)
			k := key(h)
			if seen[k] || utf8.RuneCountInString(h) < minBoostChars || strings.ContainsAny(h, "\t\n\r") {
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
		out = append(out, sb.String())
	}
	return out
}
