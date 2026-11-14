package daemon

import (
	"log/slog"
	"runtime/debug"
	"unicode"

	"github.com/anatolykoptev/ox-say/internal/glossary"
	"github.com/anatolykoptev/ox-say/internal/ruwords"
	"github.com/anatolykoptev/ox-say/internal/stt"
)

// sttBoost is the decoder boost list for ONE request: the active glossary pairs as ox-stt term lines
// (glossary.BoostTerms) with the configured strength (OX_SAY_STT_BOOST_ALPHA, 0 = off). The list is derived
// from the glossary file only — there is no second store and no file copy — and cached per version of that
// file. It never blocks a request: while a new version is being derived (the Russian dictionary check takes a
// few hundred milliseconds), the request goes out with the previous list, or with none before the first one.
func (d *Daemon) sttBoost() stt.Boost {
	if d.Cfg.STTBoostAlpha <= 0 || d.Glossary == nil {
		return stt.Boost{}
	}
	pairs, gen := d.glossaryPairsGen()
	d.tbMu.Lock()
	defer d.tbMu.Unlock()
	if !(d.tbHave && d.tbGen == gen) && !d.tbBuilding {
		d.tbBuilding = true
		go d.deriveBoost(pairs, gen)
	}
	return stt.Boost{Alpha: d.Cfg.STTBoostAlpha, Terms: d.tbTerms}
}

// deriveBoost builds the term lines for one glossary generation and stores them.
func (d *Daemon) deriveBoost(pairs []glossary.Pair, gen uint64) {
	terms := d.boostTermsFor(pairs)
	d.tbMu.Lock()
	d.tbHave, d.tbGen, d.tbTerms, d.tbBuilding = true, gen, terms, false
	d.tbMu.Unlock()
}

// boostTermsFor applies the common-word filter. The Russian dictionary is parsed on first use and dropped
// right after — it is ~100 MB of heap, and the list is rebuilt only when the glossary changes. A dictionary
// that cannot load means no boost list: boosting common words is the failure the filter exists to prevent.
func (d *Daemon) boostTermsFor(pairs []glossary.Pair) []string {
	if len(pairs) == 0 {
		return nil
	}
	var ck *ruwords.Checker
	loadFailed := false
	common := func(heard string) bool {
		if !hasCyrillic(heard) {
			return false
		}
		if ck == nil && !loadFailed {
			var err error
			if ck, err = ruwords.Load(); err != nil {
				loadFailed = true
				d.log.Warn("stt boost: the Russian word list did not load; no glossary terms are boosted", slog.Any("error", err))
			}
		}
		return loadFailed || ck.Common(heard)
	}
	terms := glossary.BoostTerms(pairs, common)
	if loadFailed {
		return nil
	}
	if ck != nil {
		ck = nil
		go debug.FreeOSMemory()
	}
	return terms
}

func hasCyrillic(s string) bool {
	for _, r := range s {
		if unicode.Is(unicode.Cyrillic, r) {
			return true
		}
	}
	return false
}
