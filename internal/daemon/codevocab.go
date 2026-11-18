package daemon

import (
	"slices"
	"strings"

	"github.com/anatolykoptev/ox-say/internal/codevocab"
	"github.com/anatolykoptev/ox-say/internal/glossary"
)

// codePacks is the enabled code packs from the daemon settings — the
// code_vocabulary list, normalised to the known ids in canonical order. An
// unset or unreadable setting means no packs; a name that is not a pack is
// ignored rather than failing the read.
func (d *Daemon) codePacks() []string {
	if d.Meet == nil || d.Meet.Store == nil {
		return []string{}
	}
	return codevocab.Enabled(d.Meet.Store.Settings().CodeVocabulary)
}

// withPackTerms appends the enabled packs' term lines AFTER every owner line. The owner's lines are never touched:
// a pack never joins an owner's group, never lengthens an owner line, and a pack line that names an owner's written
// or spoken form is dropped whole. The wire trims from the tail, so a cap drops pack lines first; the packs are
// ordered by their measured value (terms that were wrong first). With no packs the owner list is returned as is.
func (d *Daemon) withPackTerms(owner []string, packs []string) []string {
	if len(packs) == 0 {
		return owner
	}
	taken := map[string]bool{}
	var ownerSpoken [][]string
	for _, l := range owner {
		for i, f := range strings.Split(l, "\t") {
			if i != 1 { // field 1 is the weight
				taken[glossary.Key(f)] = true
			}
			if i >= 2 {
				if w := strings.Fields(glossary.Key(f)); len(w) > 0 {
					ownerSpoken = append(ownerSpoken, w)
				}
			}
		}
	}
	out := append([]string{}, owner...)
	for _, l := range d.boostTermsFor(codevocab.BoostPairs(packs)) {
		clash := false
		for i, f := range strings.Split(l, "\t") {
			if i != 1 && taken[glossary.Key(f)] {
				clash = true
			}
			// the engine tries the longest spoken form first: "dunder init" would decode as __init__ and the owner's
			// "dunder" -> Dundar would never see it, so a pack form that contains an owner form is not sent
			if i >= 2 && containsOwnerForm(strings.Fields(glossary.Key(f)), ownerSpoken) {
				clash = true
			}
		}
		if !clash && len(out) < glossary.MaxBoostTerms {
			out = append(out, l)
		}
	}
	return out
}

// packFixPairs is the enabled packs' contribution to the post-pass: the safe heard forms and the allow-listed
// fused identifiers, minus every pair that shares a word with an owner pair — the owner's pair always wins, a
// longer overlapping pack phrase included.
func (d *Daemon) packFixPairs(owner []glossary.Pair) []glossary.Pair {
	return codevocab.DropOwned(codevocab.RewritePairs(d.codePacks()), owner)
}

// containsOwnerForm reports whether any owner spoken form occurs in words as a whole-word run.
func containsOwnerForm(words []string, owner [][]string) bool {
	for _, o := range owner {
		for i := 0; i+len(o) <= len(words); i++ {
			if slices.Equal(words[i:i+len(o)], o) {
				return true
			}
		}
	}
	return false
}
