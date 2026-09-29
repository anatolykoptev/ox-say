// Package voices persists voice clones under $OX_SAY_HOME/voices as
// <name>.wav + <name>.json pairs. The engine child holds voices only in
// memory, so this store is the source of truth replayed into every start.
package voices

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"time"
)

// voiceNameRe constrains names to a safe file-name alphabet; the name becomes
// <name>.wav / <name>.json on disk, so anything outside this set is refused
// before the filesystem is touched.
var voiceNameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,31}$`)

// ValidateName rejects names that are unsafe as file names.
func ValidateName(name string) error {
	if !voiceNameRe.MatchString(name) {
		return fmt.Errorf("voices: invalid name %q: must match %s", name, voiceNameRe)
	}
	return nil
}

// ErrNotFound is returned by Remove for an unknown voice.
var ErrNotFound = errors.New("voices: no such voice")

// Voice is one persisted clone.
type Voice struct {
	Name    string    `json:"name"`
	RefText string    `json:"ref_text,omitempty"`
	Created time.Time `json:"created"`
}

// WAVPath returns the clip path for a valid name.
func (s *Store) WAVPath(name string) string { return filepath.Join(s.dir, name+".wav") }

func (s *Store) metaPath(name string) string { return filepath.Join(s.dir, name+".json") }

// Store is the on-disk voice registry.
type Store struct {
	dir    string
	ffmpeg string // binary name/path; "ffmpeg" by default
}

// New creates the directory if needed and returns the store.
func New(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("voices: %w", err)
	}
	return &Store{dir: dir, ffmpeg: "ffmpeg"}, nil
}

// Add normalises audioPath to 24 kHz mono s16 WAV (max 20 s) with ffmpeg and
// persists name.wav + name.json. The name is validated before any filesystem
// or ffmpeg work.
func (s *Store) Add(name, audioPath, refText string) (*Voice, error) {
	if err := ValidateName(name); err != nil {
		return nil, err
	}
	if _, err := os.Stat(audioPath); err != nil {
		return nil, fmt.Errorf("voices: audio: %w", err)
	}
	tmp := filepath.Join(s.dir, ".normalize-"+name+".wav")
	defer os.Remove(tmp)
	out, err := exec.Command(s.ffmpeg,
		"-hide_banner", "-loglevel", "error", "-y",
		"-i", audioPath,
		"-t", "20",
		"-ar", "24000",
		"-ac", "1",
		"-c:a", "pcm_s16le",
		tmp,
	).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("voices: ffmpeg: %w: %s", err, out)
	}
	if err := os.Rename(tmp, s.WAVPath(name)); err != nil {
		return nil, fmt.Errorf("voices: %w", err)
	}
	v := &Voice{Name: name, RefText: refText, Created: time.Now().UTC()}
	meta, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(s.metaPath(name), meta, 0o644); err != nil {
		_ = os.Remove(s.WAVPath(name)) // do not leave an orphaned clip
		return nil, fmt.Errorf("voices: %w", err)
	}
	return v, nil
}

// Remove deletes a voice's wav+json. Unknown names yield ErrNotFound.
func (s *Store) Remove(name string) error {
	if err := ValidateName(name); err != nil {
		return err
	}
	var missing bool
	for _, p := range []string{s.WAVPath(name), s.metaPath(name)} {
		switch err := os.Remove(p); {
		case err == nil:
		case errors.Is(err, fs.ErrNotExist):
			missing = true
		default:
			return fmt.Errorf("voices: %w", err)
		}
	}
	if missing {
		return ErrNotFound
	}
	return nil
}

// Get returns one voice.
func (s *Store) Get(name string) (*Voice, error) {
	if err := ValidateName(name); err != nil {
		return nil, err
	}
	meta, err := os.ReadFile(s.metaPath(name))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("voices: %s metadata: %w", name, err)
	}
	var v Voice
	if err := json.Unmarshal(meta, &v); err != nil {
		return nil, fmt.Errorf("voices: %s metadata: %w", name, err)
	}
	return &v, nil
}

// List returns all persisted voices sorted by name.
func (s *Store) List() ([]Voice, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, fmt.Errorf("voices: %w", err)
	}
	var out []Voice
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".json" {
			continue
		}
		meta, err := os.ReadFile(filepath.Join(s.dir, e.Name()))
		if err != nil {
			continue
		}
		var v Voice
		if json.Unmarshal(meta, &v) == nil && ValidateName(v.Name) == nil {
			out = append(out, v)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}
