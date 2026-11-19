package glossary

import (
	"crypto/sha256"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"
)

// sentenceEnds are the characters that close a sentence in recognised text. A "." between word characters
// (node.js) is not one: the tokenizer keeps it inside the word.
const sentenceEnds = ".!?…\n"

// maxContextWords bounds the run of words a stored whole-context hash may have covered (legacyHash): a context
// is "the sentence that carries the heard form", so a longer run is not one an agent filed.
const maxContextWords = 64

// abbreviations are the words a "." after which does not end a sentence, besides a dotted abbreviation
// ("e.g", "т.е": every part at most two letters, see isAbbreviation). The list is short on purpose: a word it
// misses ("Dr" is in, "Gen" is not) only cuts a sentence where a dictation without the dot would not.
var abbreviations = []string{"mr", "mrs", "ms", "mx", "dr", "prof", "sr", "jr", "vs", "ул", "им", "напр", "проф", "тов"}

// maxAbbrevPart is the most letters one part of a dotted abbreviation ("e.g", "т.е", "ph.d") has.
const maxAbbrevPart = 2

// isAbbreviation reports whether word w, followed by a ".", abbreviates rather than ends a sentence.
func isAbbreviation(w string) bool {
	for _, a := range abbreviations {
		if strings.EqualFold(w, a) { // no allocation: this runs for every terminator of every dictation
			return true
		}
	}
	if !strings.Contains(w, ".") {
		return false
	}
	for _, part := range strings.Split(w, ".") {
		if part == "" || utf8.RuneCountInString(part) > maxAbbrevPart || strings.ContainsFunc(part, func(r rune) bool { return !unicode.IsLetter(r) }) {
			return false
		}
	}
	return true
}

// isCut reports whether non-word token i closes a sentence. It must carry a terminator (sentenceEnds) that is
// followed by white space or the end of the text, so a "?" inside a URL does not cut, and a "." that only
// follows an abbreviation ("Mr. ", "e.g. ", «т.е. ») does not either: the same words under different
// punctuation are the same sentence. A sentence is hashed by its words, so a cut is the only way punctuation
// can change a hash.
func isCut(toks []token, i int) bool {
	s := toks[i].s
	p := strings.IndexAny(s, sentenceEnds)
	if p < 0 {
		return false
	}
	if i+1 < len(toks) && !strings.ContainsFunc(s[p:], unicode.IsSpace) {
		return false
	}
	dotsOnly := !strings.ContainsAny(s, "!?…\n")
	return !dotsOnly || i == 0 || !toks[i-1].word || !isAbbreviation(toks[i-1].s)
}

// Recurrence finds the heard forms of the pairs that may gain a sighting from dictation: the candidates the
// dictionary vetted, whose heard form is a single non-ordinary word. A recogniser that writes the same garbled
// form in a new sentence shows the error is systematic, which is the same evidence an agent's second filing is.
// It is built once per state of the glossary file and scanned on every dictation, so a scan touches no file and
// no dictionary.
type Recurrence struct {
	cs []compiled
	// first indexes cs by the first word of the heard form.
	first map[string][]int
	// known is the sightings each pair already holds, by pair id: a sentence that one of them vouches for is
	// that sighting again (legacyHash), not a new one.
	known map[string][]string
}

// NewRecurrence compiles the pairs that can count. Active pairs need nothing, a rejected pair is a tombstone,
// and a pair with no verdict (or an ordinary word) must not count on recurrence alone.
func NewRecurrence(pairs []Pair) *Recurrence {
	cs := compileWhere(pairs, func(p Pair) bool { return p.Status == Candidate && p.Vetted })
	r := &Recurrence{cs: cs, first: make(map[string][]int, len(cs)), known: make(map[string][]string, len(cs))}
	for _, p := range pairs {
		if p.Status == Candidate && p.Vetted && len(p.Sightings) > 0 {
			r.known[p.ID] = p.Sightings
		}
	}
	for i, c := range cs {
		r.first[c.heard[0]] = append(r.first[c.heard[0]], i)
	}
	return r
}

// Empty reports whether nothing can count; a nil Recurrence is empty.
func (r *Recurrence) Empty() bool { return r == nil || len(r.cs) == 0 }

// Scan returns, per pair id, the hashes of the distinct sentences of text that carry its heard form (at most
// maxSightings+1 per pair: the store takes the first one it lacks, and it holds at most maxSightings). Only the
// hash of a sentence leaves this function, never its words. The match is the exact heard form: a stem match
// would count a different word. A text with no heard form is one linear pass that cuts and hashes nothing.
func (r *Recurrence) Scan(text string) map[string][]string {
	if r.Empty() {
		return nil
	}
	s := scan{r: r, toks: tokenize(text)}
	for i, t := range s.toks {
		switch {
		case t.word:
			s.word(i)
		case isCut(s.toks, i):
			s.end()
		}
	}
	s.end()
	return s.found
}

// scan is one Scan's state: the sentence being read is the words in [lo, words), and hits are the pairs whose
// heard form it carries.
type scan struct {
	r     *Recurrence
	toks  []token
	found map[string][]string
	hits  []int
	ws    []string // every folded word of the text, built when the first sentence is hashed
	words int
	lo    int
}

func (s *scan) word(i int) {
	s.words++
	for _, ci := range s.r.first[fold(s.toks[i].s)] {
		if _, ok := matchAt(s.toks, i, s.r.cs[ci], true, nil); ok && !slices.Contains(s.hits, ci) {
			s.hits = append(s.hits, ci)
		}
	}
}

// end closes the sentence: it is hashed only if some pair hit in it.
func (s *scan) end() {
	if len(s.hits) > 0 {
		s.flush()
		s.hits = s.hits[:0]
	}
	s.lo = s.words
}

func (s *scan) flush() {
	if s.ws == nil {
		s.ws = textWords(s.toks)
	}
	own := hashWords(s.ws[s.lo:s.words])
	for _, ci := range s.hits {
		id := s.r.cs[ci].id
		h := own
		if k, ok := legacyHash(s.ws, s.lo, s.words, s.r.known[id]); ok {
			h = k
		}
		got := s.found[id]
		if len(got) > maxSightings || slices.Contains(got, h) {
			continue
		}
		if s.found == nil {
			s.found = map[string][]string{}
		}
		s.found[id] = append(got, h)
	}
}

// textWords is the folded words of the tokens.
func textWords(toks []token) []string {
	var ws []string
	for _, t := range toks {
		if t.word {
			ws = append(ws, fold(t.s))
		}
	}
	return ws
}

// sentenceSpans is the folded words of the tokens and the [lo, hi) word ranges of their sentences, cut by isCut
// exactly as a Scan cuts a dictation.
func sentenceSpans(toks []token) (ws []string, spans [][2]int) {
	lo := 0
	for i, t := range toks {
		switch {
		case t.word:
			ws = append(ws, fold(t.s))
		case isCut(toks, i):
			spans, lo = appendSpan(spans, lo, len(ws)), len(ws)
		}
	}
	return ws, appendSpan(spans, lo, len(ws))
}

func appendSpan(spans [][2]int, lo, hi int) [][2]int {
	if hi > lo {
		spans = append(spans, [2]int{lo, hi})
	}
	return spans
}

// hashWords is the sighting hash of a run of folded words: the sentence's identity, whatever punctuation it came
// with. It is also what the store kept for a whole context before sentences were cut (hash8(key(context))).
func hashWords(ws []string) string { return hash8(strings.Join(ws, " ")) }

// legacyHash finds, among the hashes a pair already holds, the one that vouches for the sentence ws[lo:hi]: its
// own hash, or the hash of a longer run of the text's words that carries it. Such a run is a context an
// earlier filing hashed whole; the sentence in it is that sighting again, not a new one. Only the pair's own
// stored hashes are compared, so the words of a run never leave this function.
func legacyHash(ws []string, lo, hi int, known []string) (string, bool) {
	if len(known) == 0 {
		return "", false
	}
	var (
		h   = sha256.New()
		sum []byte
		buf []byte
		hx  [8]byte
	)
	for i := max(0, hi-maxContextWords); i <= lo; i++ {
		h.Reset()
		for j := i; j < min(len(ws), i+maxContextWords); j++ {
			buf = buf[:0]
			if j > i {
				buf = append(buf, ' ')
			}
			buf = append(buf, ws[j]...)
			h.Write(buf)
			if j+1 < hi {
				continue
			}
			sum = h.Sum(sum[:0])
			hexEncode(hx[:], sum[:4])
			if k := indexOfHash(known, hx[:]); k >= 0 {
				return known[k], true
			}
		}
	}
	return "", false
}

func hexEncode(dst, src []byte) {
	const digits = "0123456789abcdef"
	for i, b := range src {
		dst[2*i], dst[2*i+1] = digits[b>>4], digits[b&0xf]
	}
}

func indexOfHash(known []string, hx []byte) int {
	for i, k := range known {
		if k == string(hx) {
			return i
		}
	}
	return -1
}

// filingHash is the sighting an agent's filing of context adds for the heard form, and whether it adds one.
// The sentences of the context that carry the heard form are cut and hashed as a dictation's are. The filing
// adds nothing when the pair already holds the hash of the whole context or of any of those sentences
// (legacyHash): a retry of the same filing, or the same sentence reported twice, is no new evidence. A context
// in which no single sentence carries the form (it spans a cut) is hashed whole.
func filingHash(context, heard string, known []string) (string, bool) {
	ws, spans := sentenceSpans(tokenize(context))
	whole := hashWords(ws)
	if slices.Contains(known, whole) {
		return "", false
	}
	hw := words(heard)
	first := ""
	for _, sp := range spans {
		if !containsSeq(ws[sp[0]:sp[1]], hw) {
			continue
		}
		if _, ok := legacyHash(ws, sp[0], sp[1], known); ok {
			return "", false
		}
		if first == "" {
			first = hashWords(ws[sp[0]:sp[1]])
		}
	}
	if first == "" {
		first = whole
	}
	return first, true
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
		// One dictation is one sighting for a meant: a second spelling of it in the same dictation would
		// otherwise borrow the first one's evidence and activate on a sentence already counted.
		if _, done := meants[p.Meant]; done {
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

// addDictation appends the first hash the pair has not seen (room permitting) and counts it as a sighting from
// dictation: one dictation is one sighting at most, since recurrence means the error comes back in a LATER
// dictation, and two sentences of one utterance would otherwise activate a pair on their own. It returns how
// many it added (0 or 1).
func (p *Pair) addDictation(hashes []string) int {
	n := 0
	for _, h := range hashes {
		if slices.Contains(p.Sightings, h) || len(p.Sightings) >= maxSightings {
			continue
		}
		p.Sightings = append(p.Sightings, h)
		p.SeenDictation++
		n++
		break
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
