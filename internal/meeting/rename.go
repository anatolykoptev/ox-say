package meeting

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"github.com/anatolykoptev/ox-say/internal/vproject"
)

// headingFiles are the markdown files whose first line is the meeting's heading (see heading).
var headingFiles = []string{TranscriptMD, NotesMD}

// Rename gives a meeting a new title: the manifest and the heading of transcript.md and notes.md. An empty title
// clears it ("Meeting" stands in the headings, as at create). The caller has checked the text (length, control and
// text-direction characters).
//
// It takes the meeting's speakers lock, the one EditSpeakers and the notes writer's clear take: an edit that has
// read the manifest and is about to write transcript.md whole would otherwise put the old heading back. A meeting
// being recorded or processed is refused like a speakers edit is (ErrSpeakersBusy): the pass in flight renders the
// heading from the title it started with.
//
// The manifest is saved first and the headings are rewritten after it, so a notes or transcript render that starts
// later reads the new title; a rename that died between the two is finished by the same request again (a heading
// already right is left alone).
func (r *Runner) Rename(id, title string) (*Manifest, error) {
	defer r.speakerLocks.lock(id)()
	m, err := r.Store.Load(id)
	if err != nil {
		return nil, err
	}
	switch m.Status {
	case StatusTranscribed, StatusDone, StatusFailed:
	default:
		return nil, ErrSpeakersBusy
	}
	dir, err := r.Store.Dir(id)
	if err != nil {
		return nil, err
	}
	m, err = r.Store.Update(id, func(m *Manifest) { m.Title = title })
	if err != nil {
		return nil, err
	}
	line := "# " + heading(*m)
	for _, name := range headingFiles {
		if err := r.rewriteHeading(filepath.Join(dir, name), line); err != nil {
			return nil, fmt.Errorf("meeting: %s: %w", name, err)
		}
	}
	return m, nil
}

// rewriteHeading replaces the first line of the file with line. No file is nothing to do. A file that does not start
// with a heading was not written by this package; it is left alone and the skip is logged (the name only).
func (r *Runner) rewriteHeading(path, line string) error {
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	text := string(raw)
	if !strings.HasPrefix(text, "# ") {
		r.Log.Warn("meeting: a text without a heading was left as it is on rename", slog.String("file", filepath.Base(path)))
		return nil
	}
	_, rest, hasRest := strings.Cut(text, "\n")
	out := line
	if hasRest {
		out += "\n" + rest
	}
	if out == text {
		return nil
	}
	return vproject.WriteAtomic(path, []byte(out), 0o600)
}
