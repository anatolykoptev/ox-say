// Package transcripts keeps file transcripts: private user text, one directory
// per transcript under the store root, written atomically and readable by the
// owner alone.
package transcripts

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// Meta describes one stored transcript. The text itself lives in the ox_json
// document and is never part of Meta, so a list carries no transcript text.
type Meta struct {
	ID       string    `json:"id"`
	Title    string    `json:"title"`
	Engine   string    `json:"engine"`
	Language string    `json:"language,omitempty"`
	Created  time.Time `json:"created"`
	Seconds  float64   `json:"seconds"`
}

var (
	// ErrNotFound is a well-formed id that names no transcript.
	ErrNotFound = errors.New("transcripts: no such transcript")
	// ErrInvalidID is an id that could not have been issued by Put. It is refused
	// before the disk is touched, so no id can reach outside the store.
	ErrInvalidID = errors.New("transcripts: invalid transcript id")
)

const (
	metaFile  = "meta.json"
	oxFile    = "ox.json"
	tmpPrefix = ".tmp-"
	// tmpSweepMinAge is how long a leftover temp directory must have been
	// untouched before New takes it: a younger one may belong to a live
	// daemon mid-Put — a second `ox-say serve` must not delete the first's
	// in-flight write.
	tmpSweepMinAge = 2 * time.Minute
)

// rename is os.Rename; a var so a test can make the final step fail.
var rename = os.Rename

// removeAll is os.RemoveAll; a var so a test can make the sweep fail.
var removeAll = os.RemoveAll

// Store is a directory of transcripts.
type Store struct {
	dir string
	// Log receives a warning for an entry that cannot be read. It carries ids and
	// errors only, never transcript text. Nil logs nothing.
	Log *slog.Logger
}

// ValidID reports an id Put could have issued: YYYYMMDD-HHMMSS-<6 hex>.
func ValidID(id string) bool { return vproject.ValidID(id) }

// New opens (creating it) the store directory with mode 0700 and removes the
// temp directories an interrupted write or delete left behind. An existing
// directory with looser permissions is tightened. A temp directory younger
// than tmpSweepMinAge is left alone — it may be a live daemon's in-flight
// write — and one that cannot be removed is logged and kept rather than
// failing the store over it.
func New(dir string, log *slog.Logger) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, err
	}
	s := &Store{dir: dir, Log: log}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	for _, e := range entries {
		if !e.IsDir() || !strings.HasPrefix(e.Name(), tmpPrefix) {
			continue
		}
		info, ierr := e.Info()
		if ierr != nil || now.Sub(info.ModTime()) < tmpSweepMinAge {
			continue
		}
		if err := removeAll(filepath.Join(dir, e.Name())); err != nil && s.Log != nil {
			s.Log.Warn("transcripts: cannot remove a leftover temp dir", slog.String("name", e.Name()), slog.Any("error", err))
		}
	}
	return s, nil
}

// Put stores one transcript: m.ID and m.Created are assigned when empty, ox is
// the ox_json document. Both files are written into a temp directory and the
// directory is renamed into place, so a reader sees all of a transcript or none
// of it; any failure removes the temp directory. It returns the stored Meta.
func (s *Store) Put(m Meta, ox []byte) (Meta, error) {
	if m.Created.IsZero() {
		m.Created = time.Now()
	}
	m.Created = m.Created.UTC()
	if m.ID == "" {
		m.ID = vproject.NewID(m.Created)
	} else if !ValidID(m.ID) {
		return Meta{}, ErrInvalidID
	}
	raw, err := json.Marshal(m)
	if err != nil {
		return Meta{}, err
	}
	final := filepath.Join(s.dir, m.ID)
	if _, err := os.Lstat(final); err == nil {
		return Meta{}, fmt.Errorf("transcripts: %s already exists", m.ID)
	}
	tmp := filepath.Join(s.dir, tmpPrefix+m.ID)
	if err := os.Mkdir(tmp, 0o700); err != nil {
		return Meta{}, err
	}
	fail := func(err error) (Meta, error) {
		_ = os.RemoveAll(tmp)
		return Meta{}, err
	}
	if err := writeFile(filepath.Join(tmp, oxFile), ox); err != nil {
		return fail(err)
	}
	if err := writeFile(filepath.Join(tmp, metaFile), raw); err != nil {
		return fail(err)
	}
	if err := rename(tmp, final); err != nil {
		return fail(err)
	}
	return m, nil
}

// writeFile creates path 0600 (never overwriting) and syncs it.
func writeFile(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// List returns the stored transcripts newest first (Created, then id, both
// descending, so two taken in one second still order the same way every time);
// limit <= 0 means all. An entry that is not a readable transcript is skipped
// with a warning rather than failing the list.
func (s *Store) List(limit int) ([]Meta, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, err
	}
	out := []Meta{}
	for _, e := range entries {
		if !e.IsDir() || !ValidID(e.Name()) {
			continue
		}
		m, err := s.readMeta(e.Name())
		if err != nil {
			if s.Log != nil && !errors.Is(err, ErrNotFound) {
				s.Log.Warn("transcripts: skipping an unreadable entry", slog.String("id", e.Name()), slog.Any("error", err))
			}
			continue
		}
		out = append(out, m)
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].Created.Equal(out[j].Created) {
			return out[i].Created.After(out[j].Created)
		}
		return out[i].ID > out[j].ID
	})
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (s *Store) readMeta(id string) (Meta, error) {
	raw, err := os.ReadFile(filepath.Join(s.dir, id, metaFile))
	if errors.Is(err, os.ErrNotExist) {
		return Meta{}, ErrNotFound
	}
	if err != nil {
		return Meta{}, err
	}
	var m Meta
	if err := json.Unmarshal(raw, &m); err != nil {
		return Meta{}, fmt.Errorf("transcripts: %s: %w", metaFile, err)
	}
	if m.ID != id {
		return Meta{}, fmt.Errorf("transcripts: %s names id %q, not %q", metaFile, m.ID, id)
	}
	return m, nil
}

// Get returns a transcript's Meta and its ox_json document.
func (s *Store) Get(id string) (Meta, []byte, error) {
	if !ValidID(id) {
		return Meta{}, nil, ErrInvalidID
	}
	m, err := s.readMeta(id)
	if err != nil {
		return Meta{}, nil, err
	}
	ox, err := os.ReadFile(filepath.Join(s.dir, id, oxFile))
	switch {
	case errors.Is(err, os.ErrNotExist):
		// deleted between the meta read and this one, or an entry that lost
		// its document: the transcript is not there
		return Meta{}, nil, ErrNotFound
	case err != nil:
		return Meta{}, nil, fmt.Errorf("transcripts: %s: %w", oxFile, err)
	}
	return m, ox, nil
}

// Delete removes a transcript. The directory is renamed out of sight first, so
// it disappears at once and a failed removal leaves a temp directory the next
// New sweeps, never a half-deleted transcript.
func (s *Store) Delete(id string) error {
	if !ValidID(id) {
		return ErrInvalidID
	}
	final := filepath.Join(s.dir, id)
	if _, err := os.Lstat(final); errors.Is(err, os.ErrNotExist) {
		return ErrNotFound
	} else if err != nil {
		return err
	}
	gone := filepath.Join(s.dir, tmpPrefix+"del-"+id)
	if err := rename(final, gone); err != nil {
		if errors.Is(err, os.ErrNotExist) { // deleted by a concurrent request
			return ErrNotFound
		}
		return err
	}
	return os.RemoveAll(gone)
}
