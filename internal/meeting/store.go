package meeting

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// ErrNotFound: no meeting has this id.
var ErrNotFound = errors.New("meeting not found")

// Store keeps one directory per meeting under Root. Every change to a
// manifest goes through Update, which serializes writers.
type Store struct {
	Root string
	mu   sync.Mutex
}

// Dir is the directory of meeting id; the id must be one NewID made.
func (s *Store) Dir(id string) (string, error) {
	if !vproject.ValidID(id) {
		return "", fmt.Errorf("%w: %q is not a meeting id", ErrNotFound, id)
	}
	return filepath.Join(s.Root, id), nil
}

// Create assigns an id, makes the directory (0700: private audio) and saves
// the manifest in StatusRecording.
func (s *Store) Create(m Manifest, now time.Time) (Manifest, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m.Version = ManifestVersion
	m.ID = vproject.NewID(now)
	m.Status = StatusRecording
	if m.Started.IsZero() {
		m.Started = now
	}
	dir := filepath.Join(s.Root, m.ID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return Manifest{}, "", fmt.Errorf("meeting: %w", err)
	}
	if err := s.save(dir, &m); err != nil {
		return Manifest{}, "", err
	}
	return m, dir, nil
}

func (s *Store) save(dir string, m *Manifest) error {
	raw, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	return vproject.WriteAtomic(filepath.Join(dir, ManifestFile), raw, 0o600)
}

// Load reads one manifest.
func (s *Store) Load(id string) (*Manifest, error) {
	dir, err := s.Dir(id)
	if err != nil {
		return nil, err
	}
	return load(dir)
}

func load(dir string) (*Manifest, error) {
	raw, err := os.ReadFile(filepath.Join(dir, ManifestFile))
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("meeting: %s: %w", dir, err)
	}
	if m.Version != ManifestVersion {
		return nil, fmt.Errorf("meeting: %s is version %d; this daemon reads %d", dir, m.Version, ManifestVersion)
	}
	return &m, nil
}

// Update loads id, applies fn and saves the result, all under the store lock.
func (s *Store) Update(id string, fn func(*Manifest)) (*Manifest, error) {
	dir, err := s.Dir(id)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := load(dir)
	if err != nil {
		return nil, err
	}
	fn(m)
	return m, s.save(dir, m)
}

// List returns every readable meeting, newest first. A directory whose
// manifest cannot be read is skipped, not fatal: one bad meeting must not hide
// the others.
func (s *Store) List() ([]Manifest, error) {
	entries, err := os.ReadDir(s.Root)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []Manifest
	for _, e := range entries {
		if !e.IsDir() || !vproject.ValidID(e.Name()) {
			continue
		}
		if m, err := load(filepath.Join(s.Root, e.Name())); err == nil {
			out = append(out, *m)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Started.After(out[j].Started) })
	return out, nil
}

// Delete removes a meeting and all its files.
func (s *Store) Delete(id string) error {
	dir, err := s.Dir(id)
	if err != nil {
		return err
	}
	if err := vproject.Contained(s.Root, dir); err != nil {
		return ErrNotFound
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return os.RemoveAll(dir)
}

// Text reads one of the meeting's text files (TranscriptMD or NotesMD).
// Any other name is refused: the callers pass user-chosen ids and this keeps
// the audio and the manifest out of their reach.
func (s *Store) Text(id, name string) (string, error) {
	if name != TranscriptMD && name != NotesMD {
		return "", fmt.Errorf("meeting: %q is not a text file", name)
	}
	dir, err := s.Dir(id)
	if err != nil {
		return "", err
	}
	raw, err := os.ReadFile(filepath.Join(dir, name))
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	return string(raw), err
}
