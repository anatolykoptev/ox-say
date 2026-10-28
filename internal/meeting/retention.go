package meeting

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// SettingsFile holds the daemon-side meeting settings beside the meetings.
const SettingsFile = "settings.json"

// RetentionChoices are the audio retention periods the user can pick, in days;
// 0 keeps the audio forever. Nothing else is accepted, read or written.
var RetentionChoices = []int{0, 7, 30, 90}

// Settings are the meeting settings the daemon itself needs. RetentionDays is
// how long audio is kept after a meeting ends; 0 keeps it forever.
type Settings struct {
	RetentionDays int `json:"retention_days"`
}

func validRetention(days int) bool { return slices.Contains(RetentionChoices, days) }

// LoadSettings reads settings.json. A file that does not exist means the
// default of DefaultRetention days; a file that exists but cannot be read,
// parsed or holds a period outside RetentionChoices is an error, not a default:
// guessing 30 days over a "never" the user chose would delete audio they asked
// to keep.
func (s *Store) LoadSettings() (Settings, error) {
	raw, err := os.ReadFile(filepath.Join(s.Root, SettingsFile))
	if errors.Is(err, os.ErrNotExist) {
		return Settings{RetentionDays: DefaultRetention}, nil
	}
	if err != nil {
		return Settings{}, err
	}
	var got Settings
	if err := json.Unmarshal(raw, &got); err != nil {
		return Settings{}, fmt.Errorf("meeting: %s: %w", SettingsFile, err)
	}
	if !validRetention(got.RetentionDays) {
		return Settings{}, fmt.Errorf("meeting: %s: retention of %d days is not one of %v", SettingsFile, got.RetentionDays, RetentionChoices)
	}
	return got, nil
}

// Settings is LoadSettings for display: when the file is unusable it shows the
// default. The retention sweep does not use it; it stops on the error.
func (s *Store) Settings() Settings {
	st, err := s.LoadSettings()
	if err != nil {
		return Settings{RetentionDays: DefaultRetention}
	}
	return st
}

// SetSettings saves the settings; a retention outside RetentionChoices is refused.
func (s *Store) SetSettings(st Settings) error {
	if !validRetention(st.RetentionDays) {
		return fmt.Errorf("meeting: retention of %d days is not one of %v: %w", st.RetentionDays, RetentionChoices, os.ErrInvalid)
	}
	if err := os.MkdirAll(s.Root, 0o700); err != nil {
		return err
	}
	raw, _ := json.Marshal(st)
	return vproject.WriteAtomic(filepath.Join(s.Root, SettingsFile), raw, 0o600)
}

// SweepRetention deletes the audio of meetings that ended more than the
// retention period ago and whose transcript exists. Transcripts and notes are
// never touched. A meeting without a readable transcript keeps its audio, failed
// or not: deleting it would lose the only copy of what was said.
//
// It deletes nothing when the settings cannot be read (logged once until they
// can), and marks a meeting AudioDeleted only when both files are really gone;
// a file that would not go is tried again at the next sweep.
func (r *Runner) SweepRetention() int {
	st, err := r.Store.LoadSettings()
	r.mu.Lock()
	warn := err != nil && !r.retentionWarned
	r.retentionWarned = err != nil
	r.mu.Unlock()
	if err != nil {
		if warn {
			r.Log.Warn("meeting: audio retention paused, the settings file is unusable", slog.Any("error", err))
		}
		return 0
	}
	if st.RetentionDays == 0 {
		return 0
	}
	list, err := r.Store.List()
	if err != nil {
		return 0
	}
	deleted := 0
	for _, m := range list {
		if r.expired(m, st.RetentionDays) && r.deleteAudio(m, st.RetentionDays) {
			deleted++
		}
	}
	return deleted
}

// expired reports a meeting whose audio is past the retention period and may
// go. Only a meeting whose transcript is on disk and readable qualifies, failed
// or not: without one the audio is the only copy of what was said, and it stays
// until the user retries or deletes the meeting.
func (r *Runner) expired(m Manifest, days int) bool {
	if m.AudioDeleted || m.Ended == nil {
		return false
	}
	switch m.Status {
	case StatusDone, StatusTranscribed, StatusFailed:
	default:
		return false
	}
	if r.Now().Before(m.Ended.Add(time.Duration(days) * 24 * time.Hour)) {
		return false
	}
	dir, err := r.Store.Dir(m.ID)
	if err != nil {
		return false
	}
	// a recording longer than its transcript has a tail nobody has transcribed yet
	return transcriptReadable(dir) && !grewSince(dir, &m)
}

// transcriptReadable reports a transcript.json that is on disk and parses.
func transcriptReadable(dir string) bool {
	raw, err := os.ReadFile(filepath.Join(dir, TranscriptJSON))
	if err != nil {
		return false
	}
	var turns []Turn
	return json.Unmarshal(raw, &turns) == nil
}

// What a meeting directory can hold, by what becomes of it when the audio goes. Every file-name constant of this
// package is on exactly one of these lists (or is rootFiles' settings file); TestEveryMeetingFileIsAccountedFor
// reads the constants from the source, so a file added without deciding is a red test, not a voiceprint that
// outlives the retention period.
var (
	// audioFiles are removed one by one.
	audioFiles = []string{MePCM, ThemPCM}
	// workFiles live inside WorkDir, which is removed whole.
	workFiles = []string{DiarizationJSON}
	// keptFiles stay for the life of the meeting.
	keptFiles = []string{ManifestFile, TranscriptJSON, TranscriptMD, RawTranscriptJSON, NotesJSON, NotesMD, SpeakersJSON}
	// rootFiles sit beside the meetings, not in one.
	rootFiles = []string{SettingsFile}
)

// errNotDue: by the time the sweep held the store lock the meeting was no longer one whose audio may go.
var errNotDue = errors.New("meeting: audio is not due for deletion")

// deleteAudio removes a meeting's audio and work files and records it. False when the meeting is no longer due, a
// file would not go or the record could not be saved: the next sweep tries again.
//
// The decision and the delete are made under the store lock, the lock a retry takes to queue the meeting (Retry,
// RetryVoices, retryFailed all go through Store.Update). expired is asked again on the record as it is now: a
// meeting that a retry has queued, or that the runner has begun, is no longer done/transcribed/failed and is left
// alone, and a retry that comes after sees the files gone and refuses. Judging a stale list and deleting later
// left a gap in which a queued transcription lost the audio it was queued for.
func (r *Runner) deleteAudio(m Manifest, days int) bool {
	if r.beforeAudioDelete != nil {
		r.beforeAudioDelete()
	}
	dir, err := r.Store.Dir(m.ID)
	if err != nil {
		return false
	}
	stuck := false
	_, err = r.Store.Modify(m.ID, func(cur *Manifest) error {
		if !r.expired(*cur, days) {
			return errNotDue
		}
		if !removeAudio(dir) {
			stuck = true
			return errors.New("meeting: audio could not be deleted")
		}
		cur.AudioDeleted = true // saved only if it all went, and under the same lock
		return nil
	})
	switch {
	case errors.Is(err, errNotDue):
		return false
	case stuck:
		r.Log.Warn("meeting: audio could not be deleted, will retry", slog.String("id", m.ID))
		return false
	case err != nil:
		r.Log.Warn("meeting: cannot record the audio deletion", slog.String("id", m.ID), slog.Any("error", err))
		return false
	}
	r.Log.Info("meeting: audio deleted by retention", slog.String("id", m.ID))
	return true
}

// removeAudio deletes the audio files and the work directory; false when something would not go.
func removeAudio(dir string) bool {
	gone := true
	for _, name := range audioFiles {
		if err := os.Remove(filepath.Join(dir, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			gone = false
		}
	}
	for _, name := range workFiles {
		if err := os.Remove(filepath.Join(dir, WorkDir, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			gone = false
		}
	}
	if err := os.RemoveAll(filepath.Join(dir, WorkDir)); err != nil { // the piece caches too
		gone = false
	}
	return gone
}
