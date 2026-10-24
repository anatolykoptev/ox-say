package meeting

import (
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// ErrSpeakersBusy: the meeting is still being processed; its speakers can be
// edited once the transcript is done.
var ErrSpeakersBusy = errors.New("meeting: the meeting is still being processed")

// readTurns reads transcript.json; no file yet is ErrSpeakersBusy: the transcript is still to come.
func readTurns(dir string) ([]Turn, error) {
	raw, err := os.ReadFile(filepath.Join(dir, TranscriptJSON))
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrSpeakersBusy
	}
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errNoTranscript, err)
	}
	var turns []Turn
	if err := json.Unmarshal(raw, &turns); err != nil {
		return nil, fmt.Errorf("%w: %w", errNoTranscript, err)
	}
	return turns, nil
}

// Speakers returns the far side's speakers as the transcript shows them.
func (r *Runner) Speakers(id string) (SpeakersView, error) {
	m, err := r.Store.Load(id)
	if err != nil {
		return SpeakersView{}, err
	}
	dir, err := r.Store.Dir(id)
	if err != nil {
		return SpeakersView{}, err
	}
	turns, err := readTurns(dir)
	if err != nil {
		return SpeakersView{}, err
	}
	st, err := LoadSpeakers(dir)
	if err != nil {
		return SpeakersView{}, err
	}
	return View(*m, st, turns), nil
}

// EditSpeakers applies e to a meeting whose transcript exists and writes transcript.md again with the new names.
// A merge, an unmerge or the split changes who said what: speakers.json is saved and the notes are queued to be
// written again by the model. A rename alone does not: the notes already written are corrected by substitution
// (labels.go) and the meeting keeps its status. A meeting being transcribed or summarized is refused
// (ErrSpeakersBusy): the pass in flight would write the old names after it.
func (r *Runner) EditSpeakers(id string, e Edit) (SpeakersView, error) {
	m, err := r.Store.Load(id)
	if err != nil {
		return SpeakersView{}, err
	}
	switch m.Status {
	case StatusTranscribed, StatusDone, StatusFailed:
	default:
		return SpeakersView{}, ErrSpeakersBusy
	}
	dir, err := r.Store.Dir(id)
	if err != nil {
		return SpeakersView{}, err
	}
	turns, err := readTurns(dir)
	if err != nil {
		return SpeakersView{}, err
	}
	cur, err := LoadSpeakers(dir)
	if err != nil {
		return SpeakersView{}, err
	}
	next, err := cur.Apply(*m, turns, e)
	if err != nil {
		return SpeakersView{}, err
	}
	if fmt.Sprint(next.Names, next.Merge, next.Split) == fmt.Sprint(cur.Names, cur.Merge, cur.Split) {
		return View(*m, cur, turns), nil
	}
	shown, display := Present(*m, next, turns)
	transcript := []byte(TranscriptMarkdown(shown, display))
	if next.Split != cur.Split || !maps.Equal(next.Merge, cur.Merge) {
		if err := SaveSpeakers(dir, next); err != nil {
			return SpeakersView{}, err
		}
		if err := vproject.WriteAtomic(filepath.Join(dir, TranscriptMD), transcript, 0o600); err != nil {
			return SpeakersView{}, err
		}
		if _, err := r.Retry(id); err != nil {
			return SpeakersView{}, err
		}
		return View(*m, next, turns), nil
	}
	// A rename. speakers.json is saved last: it is what makes the edit visible as done, so a write that fails
	// halfway leaves the old state, and the same request again redoes the corrections (they are idempotent).
	if err := rewriteNotes(dir, shown, changesBetween(*m, cur, next, turns)); err != nil {
		return SpeakersView{}, err
	}
	if err := vproject.WriteAtomic(filepath.Join(dir, TranscriptMD), transcript, 0o600); err != nil {
		return SpeakersView{}, err
	}
	if err := SaveSpeakers(dir, next); err != nil {
		return SpeakersView{}, err
	}
	return View(*m, next, turns), nil
}
