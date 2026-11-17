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
	// LiveCaptions is the user's choice of live captions while recording; nil is "never chosen", which the daemon
	// answers with the Mac's default (on for Apple Silicon, off for Intel). A pointer so a settings file written
	// before the option existed is not read as "off".
	LiveCaptions *bool `json:"live_captions,omitempty"`
	// AEC is the user's choice of echo cancellation before transcription: AECOn or AECOff; "" is "never chosen",
	// which is on — a settings file written before the option existed gets the default every new install does,
	// and only an explicit off keeps it off.
	AEC string `json:"meeting_aec,omitempty"`
	// LLMEndpoint is the user's choice of serving the notes model to other local apps: LLMEndpointOn or
	// LLMEndpointOff; "" is "never chosen", which is OFF — the endpoint ships closed and only an explicit on
	// opens it. The polarity is the reverse of AEC's on purpose.
	LLMEndpoint string `json:"llm_endpoint,omitempty"`
	// LLMEndpointCtx is the context the notes child is started with while the endpoint is on, in tokens;
	// 0 is "never chosen" = LLMEndpointDefaultCtx. Values below NotesContextTokens are clamped up to it,
	// never refused: a smaller stored number (an older daemon, a hand edit) still means "as large as asked".
	LLMEndpointCtx int `json:"llm_endpoint_ctx,omitempty"`
	// LLMEndpointMaxS is the longest one endpoint request may run, in seconds; 0 is "never chosen" =
	// LLMEndpointDefaultMaxS. A stream that reaches it is ended cleanly so one agent cannot hold the
	// notes model for the upstream's whole timeout.
	LLMEndpointMaxS int `json:"llm_endpoint_max_s,omitempty"`
}

// The values Settings.AEC accepts ("" stands for never chosen).
const (
	AECOn  = "on"
	AECOff = "off"
)

// The values Settings.LLMEndpoint accepts ("" stands for never chosen = off).
const (
	LLMEndpointOn  = "on"
	LLMEndpointOff = "off"
)

// LLMEndpointDefaultCtx is the notes child's context while the endpoint is on and nothing is stored.
const LLMEndpointDefaultCtx = 131072

// The bounds of llm_endpoint_ctx the settings route accepts: the notes context below, and above the
// largest window any model in the catalog's class advertises (1 Mi tokens). A multiple of
// LLMEndpointCtxStep, llama.cpp's KV allocation granularity.
const (
	LLMEndpointMaxCtx  = 1 << 20
	LLMEndpointCtxStep = 4096
)

// The bounds of llm_endpoint_max_s the settings route accepts, and its default: ten minutes covers a
// long agent turn, and the ceiling is the notes call's own 20-minute bound.
const (
	LLMEndpointDefaultMaxS = 600
	LLMEndpointMinMaxS     = 10
	LLMEndpointMaxMaxS     = 1200
)

func validRetention(days int) bool { return slices.Contains(RetentionChoices, days) }

// validLLMEndpoint refuses a stored value that is none of on/off/never-chosen.
func validLLMEndpoint(v string) error {
	if v != "" && v != LLMEndpointOn && v != LLMEndpointOff {
		return fmt.Errorf("llm_endpoint of %q is not %q or %q", v, LLMEndpointOff, LLMEndpointOn)
	}
	return nil
}

// AECEnabled is the effective choice behind Settings.AEC: off only when it says so — ox-aec ships in
// every package, so echo cancellation is on unless the user turned it off.
func (st Settings) AECEnabled() bool { return st.AEC != AECOff }

// LLMEndpointEnabled is the effective choice behind Settings.LLMEndpoint: ON only when it says so —
// the endpoint is opt-in and a settings file written before the option existed stays closed.
func (st Settings) LLMEndpointEnabled() bool { return st.LLMEndpoint == LLMEndpointOn }

// LLMEndpointCtxTokens is the effective context: the stored value, the default when unset, and never
// below the context meeting notes are built for.
func (st Settings) LLMEndpointCtxTokens() int {
	if st.LLMEndpointCtx <= 0 {
		return LLMEndpointDefaultCtx
	}
	return max(st.LLMEndpointCtx, NotesContextTokens())
}

// LLMEndpointMaxSeconds is the effective per-request cap: the stored value, the default when unset.
func (st Settings) LLMEndpointMaxSeconds() int {
	if st.LLMEndpointMaxS <= 0 {
		return LLMEndpointDefaultMaxS
	}
	return st.LLMEndpointMaxS
}

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
	if got.AEC != "" && got.AEC != AECOn && got.AEC != AECOff {
		return Settings{}, fmt.Errorf("meeting: %s: meeting_aec of %q is not %q or %q", SettingsFile, got.AEC, AECOff, AECOn)
	}
	if err := validLLMEndpoint(got.LLMEndpoint); err != nil {
		return Settings{}, fmt.Errorf("meeting: %s: %w", SettingsFile, err)
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

// UpdateSettings changes the settings file as one step: change gets what is stored (or why it cannot be read) and
// returns what to store. Two requests that each change a different field cannot overwrite one another with the
// stale value they read: a retention the user picked is the setting that decides whether audio is deleted.
func (s *Store) UpdateSettings(change func(cur Settings, loadErr error) (Settings, error)) error {
	s.settingsMu.Lock()
	defer s.settingsMu.Unlock()
	cur, err := s.LoadSettings()
	next, cerr := change(cur, err)
	if cerr != nil {
		return cerr
	}
	return s.SetSettings(next)
}

// SetSettings saves the settings; a retention outside RetentionChoices is refused.
func (s *Store) SetSettings(st Settings) error {
	if !validRetention(st.RetentionDays) {
		return fmt.Errorf("meeting: retention of %d days is not one of %v: %w", st.RetentionDays, RetentionChoices, os.ErrInvalid)
	}
	if st.AEC != "" && st.AEC != AECOn && st.AEC != AECOff {
		return fmt.Errorf("meeting: meeting_aec of %q is not %q or %q: %w", st.AEC, AECOff, AECOn, os.ErrInvalid)
	}
	if err := validLLMEndpoint(st.LLMEndpoint); err != nil {
		return fmt.Errorf("meeting: %w: %w", err, os.ErrInvalid)
	}
	if st.LLMEndpointCtx < 0 {
		return fmt.Errorf("meeting: llm_endpoint_ctx of %d is negative: %w", st.LLMEndpointCtx, os.ErrInvalid)
	}
	if st.LLMEndpointMaxS < 0 {
		return fmt.Errorf("meeting: llm_endpoint_max_s of %d is negative: %w", st.LLMEndpointMaxS, os.ErrInvalid)
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
	// audioFiles are moved out one by one, the far side's first (retiredNames).
	audioFiles = []string{ThemPCM, MePCM}
	// aecFiles are the echo canceller's output and report, made from the audio (the aec stage, when meeting_aec is on):
	// they go with it and are moved out beside it (retiredNames).
	aecFiles = []string{MeAECPCM, AECJSON}
	// liveFiles are the audio as text (live captions): they go with the audio and are moved out beside it (retiredNames).
	liveFiles = []string{LiveJSONL}
	// workFiles live inside WorkDir, which is removed whole.
	workFiles = []string{DiarizationJSON}
	// keptFiles stay for the life of the meeting.
	keptFiles = []string{ManifestFile, TranscriptJSON, TranscriptMD, RawTranscriptJSON, NotesJSON, NotesMD, SpeakersJSON}
	// rootFiles sit beside the meetings, not in one.
	rootFiles = []string{SettingsFile}
)

// errNotDue: by the time the sweep held the store lock the meeting was no longer one whose audio may go.
var errNotDue = errors.New("meeting: audio is not due for deletion")

// deleteAudio removes a meeting's audio and work files and records it. False when the meeting is no longer due, the
// files could not be moved or the record could not be saved: the next sweep tries again.
//
// The decision, the move and the record are one step under the store lock (Store.Retire), the lock a retry takes to
// queue a meeting (Retry, RetryVoices, retryFailed all go through Store.Update). expired is asked again on the record
// as it is now: a meeting that a retry has queued, or that the runner has begun, is no longer done/transcribed/failed
// and is left alone, and a retry that comes after finds the files gone. The files are renamed to a tombstone under
// the lock and unlinked after it, so a long recording does not stall the other meetings. them.pcm goes first: a
// rename that fails halfway leaves no far-side file, never a far-side file without the mic.
func (r *Runner) deleteAudio(m Manifest, days int) bool {
	if r.beforeAudioDelete != nil {
		r.beforeAudioDelete()
	}
	err := r.Store.Retire(m.ID, retiredNames,
		func(cur *Manifest) error {
			if !r.expired(*cur, days) {
				return errNotDue
			}
			return nil
		},
		func(cur *Manifest) { cur.AudioDeleted = true })
	switch {
	case errors.Is(err, errNotDue), errors.Is(err, ErrNotFound): // not due, or deleted meanwhile: nothing to do
		return false
	case err != nil:
		r.Log.Warn("meeting: audio could not be deleted, will retry", slog.String("id", m.ID), slog.Any("error", err))
		return false
	}
	r.Log.Info("meeting: audio deleted by retention", slog.String("id", m.ID))
	return true
}

// retiredNames are what retention moves out of a meeting, in this order: audioFiles, aecFiles and liveFiles, then the
// work directory (which holds workFiles and the piece caches).
var retiredNames = []string{ThemPCM, MePCM, MeAECPCM, AECJSON, LiveJSONL, WorkDir}
