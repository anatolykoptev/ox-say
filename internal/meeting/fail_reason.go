package meeting

import (
	"errors"
	"io/fs"
	"os"
	"syscall"
	"time"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// Why a meeting failed (Manifest.FailReason), the way DiarReason says why it has no voices. The app turns each code
// into a sentence in the user's language and shows a general one for a code it does not know; Manifest.Error keeps
// the raw English text for the log. A code is set by markFailed / markNotesFailed, the only places that mark a
// meeting failed (TestEveryFailureSiteSetsACode).
const (
	FailSpeechModelMissing = "speech_model_missing" // the recognizer's model file is not there; installing it cures it
	FailSpeechBusy         = "speech_busy"          // the recognizer's queue stayed full through every retry
	FailSpeechFailed       = "speech_failed"        // the recognizer broke or timed out through every retry
	FailNoTranscript       = "no_transcript"        // the notes step found no readable transcript
	FailStorage            = "storage"              // a file of the meeting could not be read or written
	// The notes engine did not run (notes.EngineDownError): how its start ended.
	FailNotesEngineStart   = "notes_engine_start"   // the child did not start or crashed
	FailNotesEngineVerify  = "notes_engine_verify"  // the child ran and the daemon's check refused it
	FailNotesEngineTimeout = "notes_engine_timeout" // the child did not answer /health in time
	FailNotesEmpty         = "notes_empty"          // the model answered, but nothing on any part of the transcript was usable
	FailNotesFailed        = "notes_failed"         // the notes step failed for another reason
)

// failReason is the code for an error that stopped the transcription (notes false) or the notes (notes true).
func failReason(err error, notes bool) string {
	var (
		model *stt.ModelError
		down  *EngineDownError
		path  *fs.PathError
		link  *os.LinkError // a failed rename: the atomic write of a meeting file
	)
	switch {
	case errors.As(err, &model):
		return FailSpeechModelMissing
	case errors.Is(err, errNoTranscript):
		return FailNoTranscript
	case errors.Is(err, stt.ErrBusy):
		return FailSpeechBusy
	case errors.As(err, &down):
		if down.Reason != "" {
			return down.Reason
		}
		return FailNotesEngineStart
	case errors.Is(err, ErrNoNotes):
		return FailNotesEmpty
	case errors.As(err, &path), errors.As(err, &link), errors.Is(err, syscall.ENOSPC):
		return FailStorage
	case notes:
		return FailNotesFailed
	}
	return FailSpeechFailed
}

// markFailed records a run that failed before the transcript: the meeting waits for a retry.
func (m *Manifest) markFailed(err error, at *time.Time) {
	m.Status, m.Error, m.WaitingFor, m.FailedAt = StatusFailed, err.Error(), "", at
	m.FailReason = failReason(err, false)
}

// markNotesFailed records a notes step that failed: the transcript stands, the notes are pending.
func (m *Manifest) markNotesFailed(err error) {
	m.Status, m.NotesPending, m.Error = StatusTranscribed, "failed", err.Error()
	m.FailReason = failReason(err, true)
}
