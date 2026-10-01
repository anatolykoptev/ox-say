// Package voices persists voice clones under $OX_SAY_HOME/voices as
// <name>.wav + <name>.json pairs. The engine child holds voices only in
// memory, so this store is the source of truth replayed into every start.
package voices

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// voiceNameRe constrains names to a safe file-name alphabet; the name becomes
// <name>.wav / <name>.json on disk, so anything outside this set is refused
// before the filesystem is touched.
var voiceNameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,31}$`)

// ValidateName rejects names that are unsafe as file names.
func ValidateName(name string) error {
	if !voiceNameRe.MatchString(name) {
		return &InputError{fmt.Sprintf("voices: invalid name %q: must match %s", name, voiceNameRe)}
	}
	return nil
}

// ErrNotFound is returned by Remove for an unknown voice.
var ErrNotFound = errors.New("voices: no such voice")

// InputError marks a failure caused by caller input — a bad name, an
// unreadable or undecodable clip, a non-absolute path. The HTTP layer maps
// it to 400; everything else is a 500.
type InputError struct{ msg string }

func (e *InputError) Error() string { return e.msg }

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

	// writeFile is os.WriteFile; tests swap it to simulate a failed write.
	writeFile func(string, []byte, os.FileMode) error
}

// New creates the directory if needed and returns the store.
func New(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("voices: %w", err)
	}
	return &Store{dir: dir, ffmpeg: "ffmpeg", writeFile: os.WriteFile}, nil
}

// SweepTemp removes normalization leftovers of a daemon that died between
// Prepare and Commit. Call it only while holding the home lock: a live
// daemon's in-flight Prepare writes the same kind of file.
func (s *Store) SweepTemp() error {
	left, err := filepath.Glob(filepath.Join(s.dir, ".normalize-*"))
	if err != nil {
		return err
	}
	for _, p := range left {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

// Add normalises audioPath and persists the voice: Prepare followed by Commit.
func (s *Store) Add(ctx context.Context, name, audioPath, refText string) (*Voice, error) {
	p, err := s.Prepare(ctx, name, audioPath, refText)
	if err != nil {
		return nil, err
	}
	defer p.Discard()
	return p.Commit()
}

// Pending is a normalised clip waiting to be committed under its name.
type Pending struct {
	s       *Store
	name    string
	refText string
	tmp     string
}

// ValidateInput runs the checks Prepare applies before it writes anything
// or invokes ffmpeg: a safe voice name, an absolute audioPath (the daemon's
// cwd is "/" under launchd, so a relative path would resolve somewhere
// unexpected), and an existing clip. It performs no writes, so callers can
// reject a request before taking a lock or a guard they would otherwise
// hold through the refusal.
func (s *Store) ValidateInput(name, audioPath string) error {
	if err := ValidateName(name); err != nil {
		return err
	}
	if !filepath.IsAbs(audioPath) {
		return &InputError{fmt.Sprintf("voices: audio path %q is not absolute", audioPath)}
	}
	if _, err := os.Stat(audioPath); err != nil {
		return &InputError{fmt.Sprintf("voices: audio: %v", err)}
	}
	return nil
}

// Prepare normalises audioPath to 24 kHz mono s16 WAV (max 20 s) with ffmpeg
// into a temporary file in the store dir. It touches no live voice, so callers
// run it outside their locks (ffmpeg may take up to its 60 s cap). The input
// is validated before any filesystem or ffmpeg work — see ValidateInput.
func (s *Store) Prepare(ctx context.Context, name, audioPath, refText string) (*Pending, error) {
	if err := s.ValidateInput(name, audioPath); err != nil {
		return nil, err
	}
	tmp, err := os.CreateTemp(s.dir, ".normalize-"+name+"-*.wav")
	if err != nil {
		return nil, fmt.Errorf("voices: %w", err)
	}
	tmpName := tmp.Name()
	_ = tmp.Close()
	ok := false
	defer func() {
		if !ok {
			_ = os.Remove(tmpName)
		}
	}()
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, s.ffmpeg,
		"-hide_banner", "-loglevel", "error", "-y",
		"-protocol_whitelist", "file",
		"-i", "file:"+audioPath,
		"-t", "20",
		"-ar", "24000",
		"-ac", "1",
		"-c:a", "pcm_s16le",
		tmpName,
	).CombinedOutput()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && ctx.Err() == nil {
			// ffmpeg ran and refused the clip — caller input.
			return nil, &InputError{fmt.Sprintf("voices: cannot decode audio %q: %s", audioPath, strings.TrimSpace(string(out)))}
		}
		// Missing ffmpeg binary, a kill on the 60s cap, or an I/O error —
		// daemon-side, not client input.
		return nil, fmt.Errorf("voices: ffmpeg: %w: %s", err, strings.TrimSpace(string(out)))
	}
	ok = true
	return &Pending{s: s, name: name, refText: refText, tmp: tmpName}, nil
}

// Commit moves the clip into place and writes its metadata. The metadata is
// written to a temporary file first: a failed write (disk full) must leave a
// voice being re-added exactly as it was, not with its clip replaced or gone.
func (p *Pending) Commit() (*Voice, error) {
	s := p.s
	v := &Voice{Name: p.name, RefText: p.refText, Created: time.Now().UTC()}
	meta, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	metaTmp := p.tmp + ".meta"
	if err := s.writeFile(metaTmp, meta, 0o644); err != nil {
		_ = os.Remove(metaTmp)
		return nil, fmt.Errorf("voices: %w", err)
	}
	if err := os.Rename(p.tmp, s.WAVPath(p.name)); err != nil {
		_ = os.Remove(metaTmp)
		return nil, fmt.Errorf("voices: %w", err)
	}
	p.tmp = ""
	if err := os.Rename(metaTmp, s.metaPath(p.name)); err != nil {
		_ = os.Remove(metaTmp)
		return nil, fmt.Errorf("voices: %w", err)
	}
	return v, nil
}

// Discard removes the temporary clip if it was not committed.
func (p *Pending) Discard() {
	if p.tmp != "" {
		_ = os.Remove(p.tmp)
		p.tmp = ""
	}
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
		// dotfiles are in-flight temporaries (Prepare/Commit), never voices
		if e.IsDir() || strings.HasPrefix(e.Name(), ".") || filepath.Ext(e.Name()) != ".json" {
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
