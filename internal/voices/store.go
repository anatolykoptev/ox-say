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

// Meta is the optional, engine-facing metadata of a voice. Every field is
// additive (omitempty): a daemon that predates it reads the voice unchanged.
type Meta struct {
	// Engine is the voice's preferred TTS model ("" = the daemon default).
	Engine string `json:"engine,omitempty"`
	// Style is the default VoxCPM2 style steering, used when a request sets
	// no instructions.
	Style string `json:"style,omitempty"`
	// DesignedFrom is the description a designed voice was rendered from.
	DesignedFrom string `json:"designed_from,omitempty"`
	// Seed is the seed of the design take the voice was kept from. Like
	// DesignedFrom it describes the audio, so a re-add never inherits it.
	Seed *int64 `json:"seed,omitempty"`
}

// Voice is one persisted clone. Every code path that rewrites the metadata
// file (Commit, Update, Repair.Apply) must carry Meta over.
type Voice struct {
	Name    string    `json:"name"`
	RefText string    `json:"ref_text,omitempty"`
	Created time.Time `json:"created"`
	// Meta is embedded, so its fields stay flat in the JSON file.
	Meta

	// Notice is a one-line, human-readable remark about how the voice was
	// stored (e.g. its ref_text was replaced). Set by Commit only; never
	// persisted.
	Notice string `json:"-"`
}

// WAVPath returns the clip path for a valid name.
func (s *Store) WAVPath(name string) string { return filepath.Join(s.dir, name+".wav") }

func (s *Store) metaPath(name string) string { return filepath.Join(s.dir, name+".json") }

// Store is the on-disk voice registry.
type Store struct {
	dir    string
	ffmpeg string // binary name/path; "ffmpeg" by default

	// transcribe derives word timestamps for reference clips that outrun the
	// cap and for repairs; nil when the daemon cannot transcribe.
	transcribe Transcriber

	// writeFile is os.WriteFile; tests swap it to simulate a failed write.
	writeFile func(string, []byte, os.FileMode) error

	// rename is os.Rename; tests swap it to simulate a crash between the
	// steps of a repair.
	rename func(string, string) error
}

// New creates the directory if needed and returns the store.
func New(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("voices: %w", err)
	}
	return &Store{dir: dir, ffmpeg: "ffmpeg", writeFile: os.WriteFile, rename: os.Rename}, nil
}

// SetTranscriber wires the word-timestamp source used to keep a reference
// clip and its transcript consistent (see Prepare and PrepareRepair).
func (s *Store) SetTranscriber(t Transcriber) { s.transcribe = t }

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
	notice  string
	tmp     string
	meta    Meta
}

// SetMeta sets the metadata Commit will persist with the voice.
func (p *Pending) SetMeta(m Meta) { p.meta = m }

// Seconds is the duration of the normalised clip waiting to be committed.
func (p *Pending) Seconds() (float64, error) { return WAVSeconds(p.tmp) }

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

// Prepare normalises audioPath to 24 kHz mono s16 WAV (max MaxRefSeconds)
// with ffmpeg into a temporary file in the store dir. A clip that runs past
// the cap with a ref_text is cut at a word boundary and its ref_text replaced
// by the transcript of the kept part (see fitReference). It touches no live voice, so callers
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
		"-t", fmt.Sprint(probeSeconds),
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
	text, notice, err := s.fitReference(ctx, tmpName, refText)
	if err != nil {
		return nil, err
	}
	ok = true
	return &Pending{s: s, name: name, refText: text, notice: notice, tmp: tmpName}, nil
}

// Commit moves the clip into place and writes its metadata. The metadata is
// written to a temporary file first: a failed write (disk full) must leave a
// voice being re-added exactly as it was, not with its clip replaced or gone.
func (p *Pending) Commit() (*Voice, error) {
	s := p.s
	v := &Voice{Name: p.name, RefText: p.refText, Created: time.Now().UTC(), Meta: p.inheritedMeta(), Notice: p.notice}
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
	// A fresh add supersedes any repair backup of an earlier voice by this
	// name: a stale one would later be mistaken for this voice's original.
	for _, ext := range []string{".wav", ".json"} {
		_ = os.Remove(s.backupPath(p.name, ext))
	}
	return v, nil
}

// inheritedMeta is the metadata a commit persists. Re-adding a voice replaces
// its audio but keeps the preferences it was set up with (engine, style): an
// older client that does not know the fields must not silently reset them.
// DesignedFrom describes the old audio, so it is never carried over. Clear a
// preference with Update.
func (p *Pending) inheritedMeta() Meta {
	m := p.meta
	prev, err := p.s.Get(p.name)
	if err != nil {
		return m
	}
	if m.Engine == "" {
		m.Engine = prev.Engine
	}
	if m.Style == "" {
		m.Style = prev.Style
	}
	return m
}

// Discard removes the temporary clip if it was not committed.
func (p *Pending) Discard() {
	if p.tmp != "" {
		_ = os.Remove(p.tmp)
		p.tmp = ""
	}
}

// Update applies fn to an existing voice's metadata and rewrites it through a
// temp file and a rename; the clip is untouched. Name and Created are kept
// whatever fn does. The caller serialises Update against Commit, Repair.Apply
// and Remove (the daemon holds voiceMu).
func (s *Store) Update(name string, fn func(*Voice)) (*Voice, error) {
	v, err := s.Get(name)
	if err != nil {
		return nil, err
	}
	keepName, keepCreated := v.Name, v.Created
	fn(v)
	v.Name, v.Created = keepName, keepCreated
	meta, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	tmp := filepath.Join(s.dir, ".normalize-update-"+name+".meta")
	if err := s.writeFile(tmp, meta, 0o644); err != nil {
		_ = os.Remove(tmp)
		return nil, fmt.Errorf("voices: %w", err)
	}
	if err := s.rename(tmp, s.metaPath(name)); err != nil {
		_ = os.Remove(tmp)
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
	// The repair backup is the deleted voice's recording too.
	for _, ext := range []string{".wav", ".json"} {
		if err := os.Remove(s.backupPath(name, ext)); err != nil && !errors.Is(err, fs.ErrNotExist) {
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
		if e.IsDir() || strings.HasPrefix(e.Name(), ".") || filepath.Ext(e.Name()) != ".json" ||
			strings.HasSuffix(strings.TrimSuffix(e.Name(), ".json"), backupInfix) {
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
