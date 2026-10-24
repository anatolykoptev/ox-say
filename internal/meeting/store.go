package meeting

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
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
	// Log receives one line per meeting List had to skip; nil uses slog.Default.
	Log *slog.Logger

	newID func(time.Time) string // test seam; nil means vproject.NewID
	mu    sync.Mutex
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
	m.Status = StatusRecording
	if m.Started.IsZero() {
		m.Started = now
	}
	if err := os.MkdirAll(s.Root, 0o700); err != nil {
		return Manifest{}, "", fmt.Errorf("meeting: %w", err)
	}
	dir, err := s.makeDir(&m, now)
	if err != nil {
		return Manifest{}, "", err
	}
	if err := s.save(dir, &m); err != nil {
		return Manifest{}, "", err
	}
	return m, dir, nil
}

// createTries bounds the fresh-id retries when an id's directory exists.
const createTries = 5

// makeDir assigns m.ID and makes its directory. os.Mkdir (not MkdirAll) fails
// on an existing directory, so a colliding id is never silently shared with
// another meeting; it retries with a fresh id.
func (s *Store) makeDir(m *Manifest, now time.Time) (string, error) {
	newID := s.newID
	if newID == nil {
		newID = vproject.NewID
	}
	for range createTries {
		m.ID = newID(now)
		dir := filepath.Join(s.Root, m.ID)
		err := os.Mkdir(dir, 0o700)
		if err == nil {
			return dir, nil
		}
		if !errors.Is(err, os.ErrExist) {
			return "", fmt.Errorf("meeting: %w", err)
		}
	}
	return "", fmt.Errorf("meeting: no free id after %d tries", createTries)
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
	m.ID = id // fn edits the record, it does not move it
	if err := s.save(dir, m); err != nil {
		return nil, err
	}
	return m, nil
}

// List returns every readable meeting, newest first. A directory whose
// manifest cannot be read is skipped, not fatal: one bad meeting must not hide
// the others. Each skip is logged (directory name and error only). A directory
// with no manifest yet is a Create in flight and is skipped silently.
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
		m, err := load(filepath.Join(s.Root, e.Name()))
		if errors.Is(err, ErrNotFound) {
			continue
		}
		if err != nil {
			s.log().Warn("meeting skipped: manifest unreadable", slog.String("dir", e.Name()), slog.Any("error", err))
			continue
		}
		out = append(out, *m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Started.After(out[j].Started) })
	return out, nil
}

func (s *Store) log() *slog.Logger {
	if s.Log != nil {
		return s.Log
	}
	return slog.Default()
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
