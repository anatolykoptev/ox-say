package meeting

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// expiredMeeting is a processed meeting whose retention period has passed.
func expiredMeeting(t *testing.T, f *fixture) string {
	t.Helper()
	id := f.start(t, 20, 20, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	f.now = f.now.Add(400 * 24 * time.Hour)
	return id
}

func audioLeft(t *testing.T, f *fixture, id string) bool {
	t.Helper()
	dir, _ := f.r.Store.Dir(id)
	_, err := os.Stat(filepath.Join(dir, MePCM))
	return err == nil
}

// Only a missing settings file means "30 days". A file that exists and cannot
// be understood pauses the sweep: the user may have chosen "never".
// Mutation: internal/meeting/retention.go LoadSettings, delete the
// `if err != nil { return Settings{}, err }` read-error return, or the
// json.Unmarshal error return, or the validRetention check -> RED in the
// matching case.
func TestAnUnusableSettingsFileNeverFallsBackToTheDefault(t *testing.T) {
	for name, setup := range map[string]func(path string) error{
		"garbage":     func(p string) error { return os.WriteFile(p, []byte("{not json"), 0o600) },
		"empty":       func(p string) error { return os.WriteFile(p, nil, 0o600) },
		"not allowed": func(p string) error { return os.WriteFile(p, []byte(`{"retention_days": 15}`), 0o600) },
		"negative":    func(p string) error { return os.WriteFile(p, []byte(`{"retention_days": -1}`), 0o600) },
		"huge":        func(p string) error { return os.WriteFile(p, []byte(`{"retention_days": 9223372036854775807}`), 0o600) },
		"unreadable":  func(p string) error { return os.Mkdir(p, 0o700) }, // ReadFile fails with EISDIR, not ENOENT
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			var logs syncBuf
			f.logTo(&logs)
			id := expiredMeeting(t, f)
			if err := setup(filepath.Join(f.r.Store.Root, SettingsFile)); err != nil {
				t.Fatal(err)
			}
			for range 3 {
				if n := f.r.SweepRetention(); n != 0 {
					t.Fatalf("swept %d meetings over an unusable settings file", n)
				}
			}
			if !audioLeft(t, f, id) {
				t.Fatal("audio was deleted although the retention setting is unknown")
			}
			if got := strings.Count(logs.String(), "retention paused"); got != 1 {
				t.Errorf("logged %d times in 3 sweeps, want once:\n%s", got, logs.String())
			}
		})
	}
}

// Once the file is good again the sweep resumes, and a later breakage is
// reported again.
func TestRetentionResumesWhenTheSettingsAreFixed(t *testing.T) {
	f := newFixture(t)
	id := expiredMeeting(t, f)
	path := filepath.Join(f.r.Store.Root, SettingsFile)
	_ = os.WriteFile(path, []byte("{"), 0o600)
	if f.r.SweepRetention() != 0 {
		t.Fatal("swept over a broken file")
	}
	if err := f.r.Store.SetSettings(Settings{RetentionDays: 30}); err != nil {
		t.Fatal(err)
	}
	if f.r.SweepRetention() != 1 || audioLeft(t, f, id) {
		t.Fatal("the sweep did not resume")
	}
}

func TestMissingSettingsMeanTheDefault(t *testing.T) {
	f := newFixture(t)
	st, err := f.r.Store.LoadSettings()
	if err != nil || st.RetentionDays != DefaultRetention {
		t.Fatalf("LoadSettings = %+v, %v; want %d days", st, err, DefaultRetention)
	}
}

// Only the periods the app offers are accepted.
// Mutation: internal/meeting/retention.go SetSettings, replace
// `!validRetention(st.RetentionDays)` with `st.RetentionDays < 0` -> RED.
func TestSetSettingsAcceptsOnlyTheOfferedPeriods(t *testing.T) {
	s := newStore(t)
	for _, days := range []int{0, 7, 30, 90} {
		if err := s.SetSettings(Settings{RetentionDays: days}); err != nil {
			t.Errorf("%d days refused: %v", days, err)
		}
		if got := s.Settings().RetentionDays; got != days {
			t.Errorf("round trip of %d gave %d", days, got)
		}
	}
	for _, days := range []int{-1, 1, 15, 31, 365, 1 << 62} {
		if err := s.SetSettings(Settings{RetentionDays: days}); err == nil {
			t.Errorf("%d days accepted", days)
		}
	}
	if got := s.Settings().RetentionDays; got != 90 {
		t.Errorf("a refused value changed the saved setting to %d", got)
	}
}

// AudioDeleted is a claim that the audio is gone; it is made only when it is.
// Mutation: internal/meeting/retention.go deleteAudio, delete `gone = false`
// in the os.Remove error branch -> RED (the manifest says gone, the file is there).
func TestAudioIsMarkedDeletedOnlyWhenBothFilesAreGone(t *testing.T) {
	f := newFixture(t)
	id := expiredMeeting(t, f)
	dir, _ := f.r.Store.Dir(id)
	me := filepath.Join(dir, MePCM)
	// me.pcm cannot be removed: a non-empty directory stands in for a locked file.
	_ = os.Remove(me)
	if err := os.MkdirAll(filepath.Join(me, "x"), 0o700); err != nil {
		t.Fatal(err)
	}
	if n := f.r.SweepRetention(); n != 0 {
		t.Fatalf("swept %d, want 0 while a file will not go", n)
	}
	if f.load(t, id).AudioDeleted {
		t.Fatal("AudioDeleted set with audio still on disk")
	}
	if _, err := os.Stat(filepath.Join(dir, ThemPCM)); err == nil {
		t.Error("them.pcm should still have been removed")
	}
	_ = os.RemoveAll(me) // the lock is released
	if n := f.r.SweepRetention(); n != 1 || !f.load(t, id).AudioDeleted {
		t.Fatalf("the next sweep did not finish the job (%d)", n)
	}
	// A file that was already gone (ENOENT) counts as gone.
	if n := f.r.SweepRetention(); n != 0 {
		t.Fatalf("a deleted meeting was swept again (%d)", n)
	}
}

// A failed meeting's audio does not outlive the retention period either; the
// period counts from its start when it never got an end.
// Mutation: internal/meeting/retention.go expired, delete the
// `case m.Status == StatusFailed && ...` branch -> RED.
func TestFailedMeetingsAudioFollowsRetentionToo(t *testing.T) {
	f := newFixture(t)
	f.sleeps()
	id := f.start(t, 20, 0, 5000, false)
	_, _ = f.r.Store.Update(id, func(m *Manifest) { m.Status, m.Ended, m.Attempts = StatusFailed, nil, maxAutoRetries })
	if f.r.SweepRetention() != 0 || !audioLeft(t, f, id) {
		t.Fatal("audio of a meeting that failed moments ago was deleted")
	}
	f.now = t0.Add(31 * 24 * time.Hour)
	if n := f.r.SweepRetention(); n != 1 || audioLeft(t, f, id) {
		t.Fatalf("swept %d; the failed meeting's audio is past 30 days from its start", n)
	}
	if !f.load(t, id).AudioDeleted {
		t.Error("manifest must say the audio is gone")
	}
}

// ... but not while the automatic retries are still to come.
func TestAFailedMeetingStillBeingRetriedKeepsItsAudio(t *testing.T) {
	f := newFixture(t)
	id := f.start(t, 20, 0, 5000, false)
	_, _ = f.r.Store.Update(id, func(m *Manifest) { m.Status, m.Attempts = StatusFailed, 1 })
	f.now = t0.Add(400 * 24 * time.Hour)
	if f.r.SweepRetention() != 0 || !audioLeft(t, f, id) {
		t.Fatal("audio deleted before the retries were spent")
	}
}
