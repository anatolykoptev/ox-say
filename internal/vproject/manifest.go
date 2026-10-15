// Package vproject is the on-disk format of a long-form voiceover project:
// manifest v1 (the GUI's and agents' contract), ids, keys, atomic files.
// Leaf package: stdlib only.
package vproject

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Version is the manifest format version.
const Version = 1

// Job statuses.
const (
	StatusRunning             = "running"
	StatusWaitingForDictation = "waiting_for_dictation"
	StatusPausedOnBattery     = "paused_on_battery"
	StatusReview              = "review" // done; some chunks need a listen
	StatusDone                = "done"
	StatusFailed              = "failed"
	StatusCancelled           = "cancelled"
	StatusInterrupted         = "interrupted" // the daemon stopped mid-run; resume to continue
)

// Chunk statuses.
const (
	ChunkPending = "pending"
	ChunkOK      = "ok"
	ChunkReview  = "review"
)

// Layout inside a project directory.
const (
	ManifestFile = "manifest.json"
	ScriptFile   = "script.txt"
	TakesDir     = "takes"
	WorkDir      = "out"
	DirMode      = 0o700
	FileMode     = 0o600
	NoteNumbers  = "numbers left as digits are not checked by the transcript gate"
	// NoteLimitedLoudness is recorded when reaching the loudness target took a
	// peak limiter hard (see issue #153).
	NoteLimitedLoudness = "loudness needed a peak limiter: the loudest peaks were pulled down by several dB to hold the true-peak ceiling, so very peaky speech may sound slightly squashed"
)

// Settings are fixed at creation, except the fields a run recomputes from
// the live voice (CloneMode, VoiceSHA, Engine).
type Settings struct {
	Voice          string  `json:"voice"`
	Style          string  `json:"style,omitempty"`
	Preset         string  `json:"preset"`
	CloneMode      string  `json:"clone_mode"`
	Seed           int64   `json:"seed"`
	Cfg            float64 `json:"cfg_value"`
	Steps          int     `json:"inference_timesteps"`
	Takes          int     `json:"takes_per_chunk"`
	LUFS           float64 `json:"loudness_lufs"`
	ChunkPause     float64 `json:"chunk_pause_s"`
	ParagraphPause float64 `json:"paragraph_pause_s"`
	OutPath        string  `json:"out_path"`
	Overwrite      bool    `json:"overwrite,omitempty"`
	AllowBattery   bool    `json:"allow_battery,omitempty"`
	VoiceSHA       string  `json:"voice_sha"`
	Engine         string  `json:"engine"`
}

// Chunk is one engine request's worth of the script and its takes.
type Chunk struct {
	Index      int     `json:"index"`
	Paragraph  int     `json:"paragraph"`
	Text       string  `json:"text"`
	Spoken     string  `json:"spoken"`
	Style      string  `json:"style,omitempty"`
	PauseAfter float64 `json:"pause_after_s"`
	Status     string  `json:"status"`
	Basis      string  `json:"basis,omitempty"`
	Pick       string  `json:"pick,omitempty"`
	// UserPick records that the person chose Pick after listening: the chunk
	// is ok even when that take failed the automatic checks.
	UserPick bool      `json:"user_pick,omitempty"`
	Reasons  []string  `json:"reasons,omitempty"`
	Takes    []TakeRef `json:"takes"`
	StartS   float64   `json:"start_s"`
	EndS     float64   `json:"end_s"`
}

// Progress of a run.
type Progress struct {
	ChunksTotal int     `json:"chunks_total"`
	ChunksDone  int     `json:"chunks_done"`
	Renders     int     `json:"renders"`
	ElapsedS    float64 `json:"elapsed_s"`
	ETAS        float64 `json:"eta_s"`
}

// Outputs are the published files.
type Outputs struct {
	WAV       string  `json:"wav,omitempty"`
	SRT       string  `json:"srt,omitempty"`
	VTT       string  `json:"vtt,omitempty"`
	Words     string  `json:"words_json,omitempty"`
	Manifest  string  `json:"manifest_export,omitempty"`
	DurationS float64 `json:"duration_s,omitempty"`
	// WAVSHA256 identifies the WAV this project published, so a file a user
	// saved over it later is no longer taken for the project's own.
	WAVSHA256 string `json:"wav_sha256,omitempty"`
}

// Manifest is a project.
type Manifest struct {
	Version  int       `json:"version"`
	ID       string    `json:"id"`
	Title    string    `json:"title"`
	Created  time.Time `json:"created"`
	Updated  time.Time `json:"updated"`
	Status   string    `json:"status"`
	Error    string    `json:"error,omitempty"`
	Settings Settings  `json:"settings"`
	Progress Progress  `json:"progress"`
	Chunks   []Chunk   `json:"chunks"`
	Outputs  Outputs   `json:"outputs"`
	Notes    []string  `json:"notes"`
}

// ChunkSummary is a chunk in the default status view.
type ChunkSummary struct {
	Index   int      `json:"index"`
	Status  string   `json:"status"`
	Reasons []string `json:"reasons,omitempty"`
	Pick    string   `json:"pick,omitempty"`
	// UserPick: the pick was chosen by the person, not by the checks.
	UserPick bool `json:"user_pick,omitempty"`
}

// Summary is the default status view of a project.
type Summary struct {
	ID       string         `json:"id"`
	Title    string         `json:"title"`
	Status   string         `json:"status"`
	Error    string         `json:"error,omitempty"`
	Seed     int64          `json:"seed"`
	Progress Progress       `json:"progress"`
	Outputs  Outputs        `json:"outputs"`
	Chunks   []ChunkSummary `json:"chunks"`
	Notes    []string       `json:"notes"`
}

// Summary builds the default status view: a fresh value, safe to share, whose
// lists are empty rather than null.
func (m *Manifest) Summary() Summary {
	s := Summary{ID: m.ID, Title: m.Title, Status: m.Status, Error: m.Error, Seed: m.Settings.Seed,
		Progress: m.Progress, Outputs: m.Outputs, Notes: append([]string{}, m.Notes...),
		Chunks: make([]ChunkSummary, 0, len(m.Chunks))}
	for _, c := range m.Chunks {
		s.Chunks = append(s.Chunks, ChunkSummary{Index: c.Index, Status: c.Status, Pick: c.Pick, UserPick: c.UserPick,
			Reasons: append([]string(nil), c.Reasons...)})
	}
	return s
}

// Clone is a deep copy that cannot fail: every slice is copied by hand.
func (m *Manifest) Clone() *Manifest {
	c := *m
	c.Notes = append([]string(nil), m.Notes...)
	c.Chunks = make([]Chunk, len(m.Chunks))
	for i, ch := range m.Chunks {
		ch.Reasons = append([]string(nil), ch.Reasons...)
		ch.Takes = make([]TakeRef, len(m.Chunks[i].Takes))
		for j, t := range m.Chunks[i].Takes {
			t.Reasons = append([]string(nil), t.Reasons...)
			ch.Takes[j] = t
		}
		c.Chunks[i] = ch
	}
	return &c
}

// plainManifest has no MarshalJSON of its own.
type plainManifest Manifest

// MarshalJSON writes empty lists as [] (never null: the GUI decodes them as
// non-optional arrays). Reasons stay omitted when empty. m is not modified.
func (m Manifest) MarshalJSON() ([]byte, error) {
	p := plainManifest(m)
	if p.Notes == nil {
		p.Notes = []string{}
	}
	p.Chunks = make([]Chunk, len(m.Chunks))
	for i, c := range m.Chunks {
		if c.Takes == nil {
			c.Takes = []TakeRef{}
		}
		p.Chunks[i] = c
	}
	return json.Marshal(p)
}

// AnyReview reports a chunk that needs a listen.
func (m *Manifest) AnyReview() bool {
	for _, c := range m.Chunks {
		if c.Status == ChunkReview {
			return true
		}
	}
	return false
}

var idRe = regexp.MustCompile(`^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$`)

const idRandBytes = 3

// NewID is YYYYMMDD-HHMMSS-<6 hex>: no script text, unguessable enough to
// never collide on one Mac, sortable by time.
func NewID(t time.Time) string {
	var b [idRandBytes]byte
	_, _ = rand.Read(b[:])
	return t.Format("20060102-150405") + "-" + hex.EncodeToString(b[:])
}

// ValidID reports an id NewID could have made.
func ValidID(id string) bool { return idRe.MatchString(id) }

func (m *Manifest) validate() error {
	if m.Version != Version {
		return fmt.Errorf("manifest version %d; this daemon reads %d", m.Version, Version)
	}
	for _, c := range m.Chunks {
		if c.Pick != "" && !ValidKey(c.Pick) {
			return fmt.Errorf("chunk %d: bad pick", c.Index)
		}
		for _, t := range c.Takes {
			if !ValidKey(t.Key) {
				return fmt.Errorf("chunk %d: bad take key", c.Index)
			}
		}
	}
	return nil
}

// Load reads and validates dir/manifest.json.
func Load(dir string) (*Manifest, error) {
	raw, err := os.ReadFile(filepath.Join(dir, ManifestFile))
	if err != nil {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("project %s: unreadable manifest: %w", filepath.Base(dir), err)
	}
	if err := m.validate(); err != nil {
		return nil, fmt.Errorf("project %s: %w", filepath.Base(dir), err)
	}
	return &m, nil
}

// Save writes dir/manifest.json atomically (0600). The Updated stamp changes
// only when the write succeeded.
func (m *Manifest) Save(dir string) error {
	prev := m.Updated
	m.Updated = time.Now().UTC()
	raw, err := json.MarshalIndent(m, "", "  ")
	if err == nil {
		err = WriteAtomic(filepath.Join(dir, ManifestFile), raw, FileMode)
	}
	if err != nil {
		m.Updated = prev
	}
	return err
}

// Contained refuses a project directory that is not a real directory
// directly inside root (no "..", no symlink).
func Contained(root, dir string) error {
	rel, err := filepath.Rel(root, dir)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) ||
		strings.ContainsRune(rel, filepath.Separator) {
		return fmt.Errorf("not a project directory")
	}
	st, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !st.IsDir() { // Lstat does not follow links: a symlink is never IsDir
		return fmt.Errorf("not a project directory")
	}
	return nil
}

// SweepTemp removes every temp file a crash left in dir, dir/takes and
// dir/out. Call it only while nothing writes into dir; see SweepStaleTemp for
// the form that tolerates a writer that may still be alive.
func SweepTemp(dir string) int { return SweepStaleTemp(dir, 0) }

// SweepStaleTemp is SweepTemp that leaves a temp file modified within minAge
// of now. A daemon killed with SIGKILL leaves its ffmpeg child running as an
// orphan; the orphan keeps modifying its output, so a file that is still
// fresh may have a live writer and is not touched, while a file nobody has
// written for minAge has no writer left to race. It removes only what
// WriteAtomic and the assembly create - a name starting with "." that holds
// TempMark - never a directory, and never looks through a symlinked directory.
func SweepStaleTemp(dir string, minAge time.Duration) int {
	n := 0
	now := time.Now()
	for _, d := range []string{dir, filepath.Join(dir, TakesDir), filepath.Join(dir, WorkDir)} {
		if st, err := os.Lstat(d); err != nil || !st.IsDir() { // Lstat: a link is not a directory
			continue
		}
		entries, _ := os.ReadDir(d)
		for _, e := range entries {
			name := e.Name()
			if e.IsDir() || !strings.HasPrefix(name, ".") || !strings.Contains(name, TempMark) {
				continue
			}
			if info, err := e.Info(); err != nil || now.Sub(info.ModTime()) < minAge {
				continue
			}
			if os.Remove(filepath.Join(d, name)) == nil {
				n++
			}
		}
	}
	return n
}

// TakeRef is one take of a chunk as the manifest lists it. Seed is the seed
// the engine was asked for: every reader takes it from here, never from
// base seed + attempt (the sum wraps into the engine's 32-bit range).
type TakeRef struct {
	Key       string   `json:"key"`
	Seed      int64    `json:"seed"`
	Attempt   int      `json:"attempt"`
	Cfg       float64  `json:"cfg_value"`
	DurationS float64  `json:"duration_s"`
	WER       float64  `json:"wer"`
	Passed    bool     `json:"passed"`
	Reasons   []string `json:"reasons,omitempty"`
}

var keyRe = regexp.MustCompile(`^[0-9a-f]{24}$`)

// ValidKey reports a take key as the producer writes it (24 hex).
func ValidKey(k string) bool { return keyRe.MatchString(k) }
