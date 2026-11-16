package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"log/slog"
	"runtime/debug"
	"slices"
	"strings"

	"github.com/anatolykoptev/ox-say/internal/glossary"
	"github.com/anatolykoptev/ox-say/internal/stt"
	"github.com/anatolykoptev/ox-say/internal/wordlists"
)

// sttBoost is the decoder boost list for ONE request: the active glossary pairs as ox-stt term lines
// (glossary.BoostTerms) with the configured strength (OX_SAY_STT_BOOST_ALPHA, 0 = off). The list is derived
// from the glossary file only — there is no second store and no file copy — and cached per CONTENT of the
// active (meant, heard) set, so a sighting of an existing pair (which rewrites the file and moves the pair
// generation) does not derive again. It never blocks a request: while a new list is being derived, the request
// goes out with the previous one, or with none before the first; the daemon derives once at start.
func (d *Daemon) sttBoost() stt.Boost {
	if d.Cfg.STTBoostAlpha <= 0 || d.Glossary == nil {
		return stt.Boost{}
	}
	pairs, gen := d.glossaryPairsGen()
	d.tbMu.Lock()
	defer d.tbMu.Unlock()
	if !d.tbKeyOK || d.tbSeenGen != gen {
		d.tbSeenGen, d.tbCurKey, d.tbKeyOK = gen, boostKey(pairs), true
	}
	if !(d.tbHave && d.tbKey == d.tbCurKey) && !d.tbBuilding {
		d.tbBuilding = true
		go d.deriveBoost(pairs, d.tbCurKey)
	}
	return stt.Boost{Alpha: d.Cfg.STTBoostAlpha, Terms: d.tbTerms}
}

// refreshBoost derives the list for the current glossary now, on the caller's goroutine (tests, the eval).
func (d *Daemon) refreshBoost() {
	pairs, gen := d.glossaryPairsGen()
	d.tbMu.Lock()
	key := boostKey(pairs)
	d.tbSeenGen, d.tbCurKey, d.tbKeyOK = gen, key, true
	d.tbMu.Unlock()
	d.deriveBoost(pairs, key)
}

// boostKey identifies what the boost list depends on: every active pair's meant and heard form. A sighting
// changes a pair's Seen and Sightings, never these, so it never changes the key.
func boostKey(pairs []glossary.Pair) string {
	lines := make([]string, len(pairs))
	for i, p := range pairs {
		lines[i] = p.Meant + "\x00" + p.Heard + "\x00" + p.Added.UTC().Format("20060102150405.000000000")
	}
	slices.Sort(lines)
	sum := sha256.Sum256([]byte(strings.Join(lines, "\n")))
	return hex.EncodeToString(sum[:])
}

// deriveBoost builds the term lines for one key and stores them, unless a newer key has been seen meanwhile.
func (d *Daemon) deriveBoost(pairs []glossary.Pair, key string) {
	d.tbDerives.Add(1)
	terms := d.boostTermsFor(pairs)
	d.tbMu.Lock()
	if !d.tbHave || key == d.tbCurKey {
		d.tbHave, d.tbKey, d.tbTerms = true, key, terms
	}
	d.tbBuilding = false
	d.tbMu.Unlock()
}

// boostTermsFor applies the common-word filter to every spoken form and every written form. The dictionaries
// are parsed on the first form that is not already in the verdict memo and dropped right after (the Russian one
// is ~100 MB of heap), so a derivation whose forms were all judged before loads nothing. A dictionary that
// cannot load means no boost list: boosting common words is the failure the filter exists to prevent.
func (d *Daemon) boostTermsFor(pairs []glossary.Pair) []string {
	if len(pairs) == 0 {
		return nil
	}
	var ck *wordlists.Checker
	failed := false
	common := func(form string) bool {
		d.tbVMu.Lock()
		v, ok := d.tbVerdicts[form]
		d.tbVMu.Unlock()
		if ok {
			return v
		}
		if failed {
			return true
		}
		if ck == nil {
			ck = wordlists.New()
		}
		d.tbChecks.Add(1)
		v = ck.Common(form)
		if ck.Err() != nil {
			failed = true
			d.log.Warn("stt boost: a word list did not load; no glossary terms are boosted", slog.Any("error", ck.Err()))
			return true
		}
		d.tbVMu.Lock()
		if d.tbVerdicts == nil {
			d.tbVerdicts = map[string]bool{}
		}
		d.tbVerdicts[form] = v
		d.tbVMu.Unlock()
		return v
	}
	terms := glossary.BoostTerms(pairs, common)
	if failed {
		return nil
	}
	if ck != nil {
		ck = nil
		go debug.FreeOSMemory()
	}
	return terms
}

// heardIsVetted reports whether a heard form filed by an agent may borrow the evidence of its meant form: a single
// word that the dictionary does not know as an ordinary word («давайте» is one). A phrase is not looked up. It
// shares the verdict memo with the boost list; the dictionary is parsed on the first form not judged before and
// dropped right after. A dictionary that cannot load means "not vetted": no borrowing without the check.
func (d *Daemon) heardIsVetted(heard string) bool {
	form := strings.TrimSpace(heard)
	if form == "" || len(strings.Fields(form)) != 1 {
		return false
	}
	d.tbVMu.Lock()
	v, ok := d.tbVerdicts[form]
	d.tbVMu.Unlock()
	if ok {
		return !v
	}
	ck := wordlists.New()
	v = ck.Common(form)
	if err := ck.Err(); err != nil {
		d.log.Warn("glossary: a word list did not load; the pair cannot borrow evidence", slog.Any("error", err))
		return false
	}
	go debug.FreeOSMemory()
	d.tbVMu.Lock()
	if d.tbVerdicts == nil {
		d.tbVerdicts = map[string]bool{}
	}
	d.tbVerdicts[form] = v
	d.tbVMu.Unlock()
	return !v
}
