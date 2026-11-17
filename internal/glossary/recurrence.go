package glossary

import (
	"slices"
	"strings"
)

// sentenceEnds are the characters that close a sentence in recognised text. A "." between word characters
// (node.js) is not one: the tokenizer keeps it inside the word.
const sentenceEnds = ".!?…\n"

// Recurrence finds the heard forms of the pairs that may gain a sighting from dictation: the candidates the
// dictionary vetted, whose heard form is a single non-ordinary word. A recogniser that writes the same garbled
// form in a new sentence shows the error is systematic, which is the same evidence an agent's second filing is.
// It is built once per state of the glossary file and scanned on every dictation, so a scan touches no file and
// no dictionary.
type Recurrence struct {
	cs []compiled
	// first indexes cs by the first word of the heard form.
	first map[string][]int
}

// NewRecurrence compiles the pairs that can count. Active pairs need nothing, a rejected pair is a tombstone,
// and a pair with no verdict (or an ordinary word) must not count on recurrence alone.
func NewRecurrence(pairs []Pair) *Recurrence {
	cs := compileWhere(pairs, func(p Pair) bool { return p.Status == Candidate && p.Vetted })
	r := &Recurrence{cs: cs, first: make(map[string][]int, len(cs))}
	for i, c := range cs {
		r.first[c.heard[0]] = append(r.first[c.heard[0]], i)
	}
	return r
}

// Empty reports whether nothing can count; a nil Recurrence is empty.
func (r *Recurrence) Empty() bool { return r == nil || len(r.cs) == 0 }

// Scan returns, per pair id, the hashes of the distinct sentences of text that carry its heard form. Only the
// hash of a sentence leaves this function, never its words. The match is the exact heard form: a stem match
// would count a different word.
func (r *Recurrence) Scan(text string) map[string][]string {
	if r.Empty() {
		return nil
	}
	toks := tokenize(text)
	var found map[string][]string
	hits := map[int]struct{}{}
	start := 0
	for i, t := range toks {
		switch {
		case t.word:
			for _, ci := range r.first[fold(t.s)] {
				if _, ok := matchAt(toks, i, r.cs[ci], true); ok {
					hits[ci] = struct{}{}
				}
			}
		case strings.ContainsAny(t.s, sentenceEnds):
			found = r.flush(found, toks[start:i], hits)
			start = i + 1
			clear(hits)
		}
	}
	return r.flush(found, toks[start:], hits)
}

// flush adds the sentence's hash to every pair that hit in it. The hash is the one the store keeps for an
// agent's context (hash8 of the folded words), so one sentence is one sighting whoever reports it.
func (r *Recurrence) flush(found map[string][]string, sentence []token, hits map[int]struct{}) map[string][]string {
	if len(hits) == 0 {
		return found
	}
	var ws []string
	for _, t := range sentence {
		if t.word {
			ws = append(ws, fold(t.s))
		}
	}
	h := hash8(strings.Join(ws, " "))
	if found == nil {
		found = map[string][]string{}
	}
	for ci := range hits {
		id := r.cs[ci].id
		if !slices.Contains(found[id], h) {
			found[id] = append(found[id], h)
		}
	}
	return found
}

// Recorded is what RecordDictation changed.
type Recorded struct {
	Sightings int // sighting hashes added across all pairs
	Activated int // candidates that reached their threshold on them
}

// RecordDictation adds the sightings a dictation found (Recurrence.Scan) to the pairs they belong to, then runs
// the same promotion an agent's filing does. Only a vetted candidate counts, whatever the caller found: a
// pair that was approved, rejected or has no verdict since the scan is skipped. A call that changes nothing
// writes nothing.
func (s *Store) RecordDictation(found map[string][]string) (Recorded, error) {
	var rec Recorded
	if len(found) == 0 {
		return rec, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	pairs, err := s.load()
	if err != nil {
		return rec, err
	}
	meants := map[string]struct{}{}
	for i := range pairs {
		p := &pairs[i]
		if p.Status != Candidate || !p.Vetted {
			continue
		}
		if n := p.addDictation(found[p.ID]); n > 0 {
			rec.Sightings += n
			meants[p.Meant] = struct{}{}
		}
	}
	if rec.Sightings == 0 {
		return rec, nil
	}
	before := countActive(pairs)
	for m := range meants {
		promote(pairs, m)
	}
	rec.Activated = countActive(pairs) - before
	return rec, s.save(pairs)
}

// addDictation appends the hashes the pair has not seen, up to maxSightings, and counts each as a sighting from
// dictation. It returns how many it added.
func (p *Pair) addDictation(hashes []string) int {
	n := 0
	for _, h := range hashes {
		if slices.Contains(p.Sightings, h) || len(p.Sightings) >= maxSightings {
			continue
		}
		p.Sightings = append(p.Sightings, h)
		p.SeenDictation++
		n++
	}
	return n
}

func countActive(pairs []Pair) int {
	n := 0
	for _, p := range pairs {
		if p.Status == Active {
			n++
		}
	}
	return n
}

// Needed is how many distinct sentences the pair needs before it activates on its own evidence.
func Needed(p Pair) int { return needed(p.Heard) }
