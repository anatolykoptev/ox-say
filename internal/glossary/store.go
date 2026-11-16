// Package glossary keeps the user's heard → meant word pairs and applies the
// active ones to recognised text. Agents file pairs when they understood a
// garbled term in a dictated message; the user approves or rejects them. The
// file never holds a dictated sentence: a sighting is stored as an 8-hex hash
// of the sentence, which is all that is needed to tell sentences apart.
package glossary

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// FileName is the glossary file under the daemon's home.
const FileName = "glossary.json"

type Status string

const (
	Candidate Status = "candidate"
	Active    Status = "active"
	Rejected  Status = "rejected" // a tombstone: filing it again never reactivates it
)

const (
	maxRunes     = 60
	maxWords     = 4
	maxSightings = 8
)

var (
	ErrNotFound = errors.New("glossary: no such pair")
	ErrConflict = errors.New("glossary: this heard form already maps to another term")
	ErrInvalid  = errors.New("glossary: invalid pair")
)

// Pair is one correction. ID comes from the heard form, so the same heard
// form filed twice lands on the same pair.
type Pair struct {
	ID        string   `json:"id"`
	Heard     string   `json:"heard"`
	Meant     string   `json:"meant"`
	Status    Status   `json:"status"`
	Sightings []string `json:"sightings,omitempty"` // hashes of distinct sentences
	Seen      int      `json:"seen"`
	// Vetted: the dictionary was consulted when the pair was filed and the heard form is a single word that is not
	// ordinary words of its language. Only a vetted pair may activate on the evidence of its meant form's other
	// spellings; a pair with no verdict (filed with no dictionary, or before this field) activates on its own
	// sentences alone.
	Vetted bool      `json:"vetted,omitempty"`
	Added  time.Time `json:"added"`
}

type file struct {
	Version int    `json:"version"`
	Pairs   []Pair `json:"pairs"`
}

// Store reads and writes the glossary file; one mutex serialises every
// read-modify-write in the daemon.
type Store struct {
	mu   sync.Mutex
	path string
	Now  func() time.Time
}

func NewStore(home string) *Store {
	return &Store{path: filepath.Join(home, FileName), Now: time.Now}
}

func hash8(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:4])
}

// ID is the pair id for a heard form.
func ID(heard string) string { return hash8(key(heard)) }

// needed is how many distinct sentences an agent's pair needs before it
// applies. A single word can be a real word in other sentences, so it needs
// more: two for a heard form of at least five letters, three below that (a
// short form collides with ordinary words far more often). A multi-word form
// needs two.
func needed(heard string) int {
	ws := words(heard)
	if len(ws) != 1 {
		return 2
	}
	n := 0
	for _, r := range ws[0] {
		if unicode.IsLetter(r) {
			n++
		}
	}
	if n >= 5 {
		return 2
	}
	return 3
}

// promote activates the candidates of one meant form that have enough evidence. A pair has its own evidence:
// the distinct sentences it was heard in, against its own threshold (needed). A vetted spelling (a single word
// the dictionary does not know as ordinary) may also borrow: the distinct sentences any non-rejected spelling of
// the meant form was heard in are pooled, so a term the recogniser writes a different way each time still
// activates. An ordinary word («давайте»), a phrase, or a pair with no verdict never borrows: a mistaken filing
// against an established meant would activate on its first sentence. Every candidate must itself have been
// filed with a sentence, and a rejected pair counts for nothing.
func promote(pairs []Pair, meant string) {
	sentences := map[string]struct{}{}
	for _, p := range pairs {
		if p.Meant == meant && p.Status != Rejected {
			for _, h := range p.Sightings {
				sentences[h] = struct{}{}
			}
		}
	}
	for i := range pairs {
		p := &pairs[i]
		if p.Meant != meant || p.Status != Candidate || len(p.Sightings) == 0 {
			continue
		}
		need := needed(p.Heard)
		borrow := p.Vetted && len(words(p.Heard)) == 1
		if len(p.Sightings) >= need || (borrow && len(sentences) >= need) {
			p.Status = Active
		}
	}
}

func (s *Store) load() ([]Pair, error) {
	raw, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var f file
	if err := json.Unmarshal(raw, &f); err != nil {
		return nil, fmt.Errorf("glossary: %s is not valid JSON: %w", s.path, err)
	}
	return f.Pairs, nil
}

func (s *Store) save(pairs []Pair) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(file{Version: 1, Pairs: pairs}, "", " ")
	if err != nil {
		return err
	}
	return vproject.WriteAtomic(s.path, raw, 0o600)
}

func (s *Store) List() ([]Pair, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.load()
}

// Active returns the pairs that apply.
func (s *Store) Active() ([]Pair, error) {
	all, err := s.List()
	if err != nil {
		return nil, err
	}
	var out []Pair
	for _, p := range all {
		if p.Status == Active {
			out = append(out, p)
		}
	}
	return out, nil
}

// Add is AddChecked for a caller that has no dictionary: the pair is not vetted, so it never borrows evidence.
func (s *Store) Add(heard, meant, context string) (Pair, error) {
	return s.AddChecked(heard, meant, context, false)
}

// AddChecked files a pair or counts another sighting of it. context is the sentence
// the heard form came from; it must contain the heard form, and only its hash
// is kept. A pair with no context is filed but never activates on its own.
// vetted says the caller consulted the dictionary and the heard form is a single word that is not ordinary words
// of its language (wordlists.Common); the caller computes it, the store never loads a dictionary. It is sticky.
func (s *Store) AddChecked(heard, meant, context string, vetted bool) (Pair, error) {
	heard, meant, context = strings.TrimSpace(heard), strings.TrimSpace(meant), strings.TrimSpace(context)
	if err := validate(heard, meant); err != nil {
		return Pair{}, err
	}
	if context != "" && !containsSeq(words(context), words(heard)) {
		return Pair{}, fmt.Errorf("%w: the sentence does not contain %q", ErrInvalid, heard)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	pairs, err := s.load()
	if err != nil {
		return Pair{}, err
	}
	id := ID(heard)
	i := slices.IndexFunc(pairs, func(p Pair) bool { return p.ID == id })
	switch {
	case i < 0:
		pairs = append(pairs, Pair{ID: id, Heard: heard, Meant: meant, Status: Candidate, Added: s.Now().UTC()})
		i = len(pairs) - 1
	case pairs[i].Meant != meant:
		return Pair{}, fmt.Errorf("%w: %q → %q", ErrConflict, pairs[i].Heard, pairs[i].Meant)
	}
	p := &pairs[i]
	p.Seen++
	p.Vetted = p.Vetted || vetted
	if context != "" {
		if h := hash8(key(context)); !slices.Contains(p.Sightings, h) && len(p.Sightings) < maxSightings {
			p.Sightings = append(p.Sightings, h)
		}
	}
	promote(pairs, meant)
	if err := s.save(pairs); err != nil {
		return Pair{}, err
	}
	return *p, nil
}

func (s *Store) setStatus(id string, st Status) (Pair, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	pairs, err := s.load()
	if err != nil {
		return Pair{}, err
	}
	i := slices.IndexFunc(pairs, func(p Pair) bool { return p.ID == id })
	if i < 0 {
		return Pair{}, ErrNotFound
	}
	pairs[i].Status = st
	if err := s.save(pairs); err != nil {
		return Pair{}, err
	}
	return pairs[i], nil
}

// Approve makes a pair active, a rejected one included.
func (s *Store) Approve(id string) (Pair, error) { return s.setStatus(id, Active) }

// Reject stops a pair from applying and keeps it as a tombstone.
func (s *Store) Reject(id string) (Pair, error) { return s.setStatus(id, Rejected) }

// Edit replaces the meant form of a pair. It keeps the id, the heard form and
// the status, and re-runs the same validation as Add. An active pair stays
// active and a candidate stays a candidate; a rejected one comes back as a
// candidate, because the owner has just chosen a new meaning for it. The
// sightings vouched for the old meant, so they are cleared for every pair —
// otherwise they would be pooled as evidence for the new one; a pair that is
// not active also loses its count.
func (s *Store) Edit(id, meant string) (Pair, error) {
	meant = strings.TrimSpace(meant)
	s.mu.Lock()
	defer s.mu.Unlock()
	pairs, err := s.load()
	if err != nil {
		return Pair{}, err
	}
	i := slices.IndexFunc(pairs, func(p Pair) bool { return p.ID == id })
	if i < 0 {
		return Pair{}, ErrNotFound
	}
	if err := validate(pairs[i].Heard, meant); err != nil {
		return Pair{}, err
	}
	pairs[i].Meant = meant
	pairs[i].Sightings = nil
	if pairs[i].Status != Active {
		// One agent filing of the new meant must not reach the activation threshold and settle a pair the owner
		// only re-opened: activation needs fresh evidence or an owner approve.
		pairs[i].Status = Candidate
		pairs[i].Seen = 0
	}
	if err := s.save(pairs); err != nil {
		return Pair{}, err
	}
	return pairs[i], nil
}

// Purge removes a pair entirely, with no tombstone: an agent may file the
// same heard form again as a fresh candidate. Reject is the way to keep it out.
func (s *Store) Purge(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	pairs, err := s.load()
	if err != nil {
		return err
	}
	i := slices.IndexFunc(pairs, func(p Pair) bool { return p.ID == id })
	if i < 0 {
		return ErrNotFound
	}
	return s.save(slices.Delete(pairs, i, i+1))
}

func validate(heard, meant string) error {
	switch {
	case heard == "" || meant == "":
		return fmt.Errorf("%w: heard and meant are both required", ErrInvalid)
	case utf8.RuneCountInString(heard) > maxRunes || utf8.RuneCountInString(meant) > maxRunes:
		return fmt.Errorf("%w: at most %d characters each", ErrInvalid, maxRunes)
	case !hasLetter(heard):
		return fmt.Errorf("%w: the heard form needs a letter", ErrInvalid)
	case heard == meant:
		return fmt.Errorf("%w: heard and meant are the same", ErrInvalid)
	}
	// The heard form is matched against tokenised words, so it may carry only
	// word characters and spaces — "node.js" would never match and files a
	// dead pair.
	for _, r := range heard {
		if !isWordRune(r) && r != ' ' {
			return fmt.Errorf("%w: the heard form may carry only letters, digits, spaces, ' and -", ErrInvalid)
		}
	}
	hw := words(heard)
	if len(hw) == 0 || len(hw) > maxWords {
		return fmt.Errorf("%w: heard must be 1 to %d words", ErrInvalid, maxWords)
	}
	// meant lands verbatim in transcripts and subtitles, so it is a term,
	// not text: as few words as a heard form and only word characters plus
	// the punctuation a term legitimately carries — never a newline or a
	// control character.
	if len(strings.Fields(meant)) > maxWords {
		return fmt.Errorf("%w: meant must be at most %d words", ErrInvalid, maxWords)
	}
	for _, r := range meant {
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) && !strings.ContainsRune(" .-+_'#", r) {
			return fmt.Errorf("%w: meant may carry only letters, digits, spaces and . - + _ ' #", ErrInvalid)
		}
	}
	// A case-only pair ("github" → "GitHub") is idempotent; any other meant form
	// that contains the heard words would change again on every pass.
	if key(meant) != key(heard) && containsSeq(words(meant), hw) {
		return fmt.Errorf("%w: meant contains the heard form", ErrInvalid)
	}
	return nil
}
