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
// (labels.go) and the meeting keeps its status, unless the substitution would not be unambiguous, when the notes
// are queued like after a merge. The returned view's NotesQueued says which of the two happened. A meeting being transcribed or summarized is refused (ErrSpeakersBusy): the pass
// in flight would write the old names after it.
//
// One edit runs at a time per meeting (the read-modify-write would lose the other's change). speakers.json is
// saved with NotesStale before the notes are queued and the flag is cleared when notes are written, so a request
// that died between the two is finished by the same request again.
func (r *Runner) EditSpeakers(id string, e Edit) (SpeakersView, error) {
	defer r.speakerLocks.lock(id)()
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
	if r.afterSpeakersRead != nil {
		r.afterSpeakersRead()
	}
	next, err := cur.Apply(*m, turns, e)
	if err != nil {
		return SpeakersView{}, err
	}
	if fmt.Sprint(next.Names, next.Merge, next.Split) == fmt.Sprint(cur.Names, cur.Merge, cur.Split) {
		if cur.NotesStale { // an earlier request saved the speakers and did not get the notes queued
			if _, err := r.Retry(id); err != nil {
				return SpeakersView{}, err
			}
			v := View(*m, cur, turns)
			v.NotesQueued = true
			return v, nil
		}
		return View(*m, cur, turns), nil
	}
	shown, display := Present(*m, next, turns)
	transcript := []byte(TranscriptMarkdown(shown, display))
	if next.Split != cur.Split || !maps.Equal(next.Merge, cur.Merge) {
		return r.queueNotesAfter(id, dir, *m, next, turns, transcript)
	}
	// A rename. speakers.json is saved last: it is what makes the edit visible as done, so a write that fails
	// halfway leaves the old state, and the same request again redoes the corrections (the notes carry the labels
	// they were written under, so a correction already made is not made twice).
	needsModel, err := rewriteNotes(dir, shown, *m, cur, next, turns)
	if err != nil {
		return SpeakersView{}, err
	}
	if needsModel || cur.NotesStale {
		return r.queueNotesAfter(id, dir, *m, next, turns, transcript)
	}
	if err := vproject.WriteAtomic(filepath.Join(dir, TranscriptMD), transcript, 0o600); err != nil {
		return SpeakersView{}, err
	}
	if err := SaveSpeakers(dir, next); err != nil {
		return SpeakersView{}, err
	}
	return View(*m, next, turns), nil
}

// queueNotesAfter saves next with the notes marked stale, writes transcript.md and queues the notes; the view it
// returns says so (NotesQueued).
func (r *Runner) queueNotesAfter(id, dir string, m Manifest, next SpeakerState, turns []Turn, transcript []byte) (SpeakersView, error) {
	next.NotesStale = true
	if err := SaveSpeakers(dir, next); err != nil {
		return SpeakersView{}, err
	}
	if err := vproject.WriteAtomic(filepath.Join(dir, TranscriptMD), transcript, 0o600); err != nil {
		return SpeakersView{}, err
	}
	if _, err := r.Retry(id); err != nil {
		return SpeakersView{}, err
	}
	v := View(m, next, turns)
	v.NotesQueued = true
	return v, nil
}
