package daemon

import (
	"encoding/json"
	"log/slog"

	"github.com/anatolykoptev/ox-say/internal/glossary"
)

// finishRewrite is the answer of a dictation's finish: the glossary applied to the recogniser's final text, and
// that same raw text counted as a recurrence of the candidate pairs. Finish is the one place a dictation is
// counted: its "text" is the whole utterance, where the per-chunk answers carry segments that the finish
// re-decodes, so counting both would count one sentence twice under two different cuts. The count comes after
// the correction, so the dictation that completes a pair's evidence is answered with the pairs it started with
// and the next one gets the correction. Counting precedes the write of the answer, so the next dictation sees it.
func (d *Daemon) finishRewrite(raw []byte) []byte {
	out := d.correctSessionBody(raw)
	d.noteDictation(raw)
	return out
}

// noteDictation counts the recogniser's raw final text of a dictation. It parses the body only when some
// candidate could count, so a glossary with no vetted candidate costs a stat of the glossary file.
func (d *Daemon) noteDictation(raw []byte) {
	if d.recurrenceMatcher().Empty() {
		return
	}
	var fin struct {
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &fin) != nil {
		return
	}
	d.noteDictationText(fin.Text)
}

// noteDictationText records, for every vetted candidate whose heard form the text carries, the hash of the
// sentence it is in. Only counts are logged: the sentence, the heard form and the hashes never are.
func (d *Daemon) noteDictationText(text string) {
	found := d.recurrenceMatcher().Scan(text)
	if len(found) == 0 {
		return
	}
	rec, err := d.Glossary.RecordDictation(found)
	if err != nil {
		d.log.Warn("glossary: dictation sightings not saved", slog.Any("error", err))
		return
	}
	if rec.Sightings == 0 {
		return
	}
	d.invalidateGlossary()
	d.log.Info("glossary dictation sightings", slog.Int("sightings", rec.Sightings), slog.Int("activated", rec.Activated))
}

// recurrenceMatcher is the matcher for the current state of the glossary file, cached by its mtime+size like
// the active pairs. A glossary that cannot be read means no counting and one Warn per distinct file state.
func (d *Daemon) recurrenceMatcher() *glossary.Recurrence {
	if d.Glossary == nil {
		return nil
	}
	k := d.glossaryFileKey()
	d.rcMu.Lock()
	defer d.rcMu.Unlock()
	if d.rcSet && k == d.rcKey {
		return d.rcM
	}
	pairs, err := d.Glossary.List()
	if err != nil {
		if k != d.rcWarned {
			d.rcWarned = k
			d.log.Warn("glossary: dictation sightings not counted", slog.Any("error", err))
		}
		pairs = nil
	}
	d.rcSet, d.rcKey, d.rcM = true, k, glossary.NewRecurrence(pairs)
	return d.rcM
}
