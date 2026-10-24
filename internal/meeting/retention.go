package meeting

import (
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// SettingsFile holds the daemon-side meeting settings beside the meetings.
const SettingsFile = "settings.json"

// Settings are the meeting settings the daemon itself needs. RetentionDays is
// how long audio is kept after a meeting ends; 0 keeps it forever.
type Settings struct {
	RetentionDays int `json:"retention_days"`
}

// Settings reads settings.json; a missing or unreadable file means the
// default of DefaultRetention days.
func (s *Store) Settings() Settings {
	st := Settings{RetentionDays: DefaultRetention}
	if raw, err := os.ReadFile(filepath.Join(s.Root, SettingsFile)); err == nil {
		var got Settings
		if json.Unmarshal(raw, &got) == nil && got.RetentionDays >= 0 {
			st = got
		}
	}
	return st
}

// SetSettings saves the settings; a negative retention is refused.
func (s *Store) SetSettings(st Settings) error {
	if st.RetentionDays < 0 {
		return os.ErrInvalid
	}
	if err := os.MkdirAll(s.Root, 0o700); err != nil {
		return err
	}
	raw, _ := json.Marshal(st)
	return vproject.WriteAtomic(filepath.Join(s.Root, SettingsFile), raw, 0o600)
}

// SweepRetention deletes the audio of meetings that ended more than the
// retention period ago and whose transcript exists. Transcripts and notes are
// never touched. A meeting without a transcript keeps its audio: deleting it
// would lose the only copy of what was said.
func (r *Runner) SweepRetention() int {
	days := r.Store.Settings().RetentionDays
	if days == 0 {
		return 0
	}
	list, err := r.Store.List()
	if err != nil {
		return 0
	}
	deleted := 0
	for _, m := range list {
		if m.AudioDeleted || m.Ended == nil || (m.Status != StatusDone && m.Status != StatusTranscribed) {
			continue
		}
		if r.Now().Before(m.Ended.Add(time.Duration(days) * 24 * time.Hour)) {
			continue
		}
		dir, err := r.Store.Dir(m.ID)
		if err != nil {
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, TranscriptJSON)); err != nil {
			continue
		}
		for _, name := range []string{MePCM, ThemPCM} {
			_ = os.Remove(filepath.Join(dir, name))
		}
		_ = os.RemoveAll(filepath.Join(dir, WorkDir))
		if _, err := r.Store.Update(m.ID, func(m *Manifest) { m.AudioDeleted = true }); err != nil {
			r.Log.Warn("meeting: cannot record the audio deletion", slog.String("id", m.ID), slog.Any("error", err))
			continue
		}
		deleted++
	}
	return deleted
}
