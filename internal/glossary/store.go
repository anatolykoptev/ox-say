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
	ID        string    `json:"id"`
	Heard     string    `json:"heard"`
	Meant     string    `json:"meant"`
	Status    Status    `json:"status"`
	Sightings []string  `json:"sightings,omitempty"` // hashes of distinct sentences
	Seen      int       `json:"seen"`
	Added     time.Time `json:"added"`
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
// applies: a single word can be a real word in other sentences, so it needs more.
func needed(heard string) int {
	if len(words(heard)) == 1 {
		return 3
	}
	return 2
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

// Add files a pair or counts another sighting of it. context is the sentence
// the heard form came from; it must contain the heard form, and only its hash
// is kept. A pair with no context is filed but never activates on its own.
func (s *Store) Add(heard, meant, context string) (Pair, error) {
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
	if context != "" {
		if h := hash8(key(context)); !slices.Contains(p.Sightings, h) && len(p.Sightings) < maxSightings {
			p.Sightings = append(p.Sightings, h)
		}
	}
	if p.Status == Candidate && len(p.Sightings) >= needed(heard) {
		p.Status = Active
	}
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
