// Package meeting stores recorded meetings and turns them into a transcript
// and notes. It holds no HTTP and no engine: the daemon injects the speech
// recognizer and the language model (see Deps), so every rule here is a plain
// function of its inputs.
package meeting

import "time"

// Status is where a meeting is in its life. A meeting only moves forward;
// failed and transcribed can be retried.
type Status string

const (
	StatusRecording    Status = "recording"
	StatusQueued       Status = "queued"
	StatusTranscribing Status = "transcribing"
	// StatusTranscribed: the transcript is ready and the notes are pending —
	// the notes model is not installed, or the notes run failed.
	StatusTranscribed Status = "transcribed"
	StatusSummarizing Status = "summarizing"
	StatusDone        Status = "done"
	StatusFailed      Status = "failed"
)

// Terminal reports a status the runner does not pick up again by itself.
func (s Status) Terminal() bool {
	return s == StatusDone || s == StatusFailed || s == StatusTranscribed
}

// Labels name the two channels in the transcript: Me is the microphone, Them
// is everything else the Mac played.
type Labels struct {
	Me   string `json:"me"`
	Them string `json:"them"`
}

// File names inside a meeting directory.
const (
	ManifestFile   = "meeting.json"
	MePCM          = "me.pcm"
	ThemPCM        = "them.pcm"
	TranscriptJSON = "transcript.json"
	TranscriptMD   = "transcript.md"
	// RawTranscriptJSON is the turns as merged before the echo gate ran,
	// written only when DropEcho dropped turns: the way back from a turn that
	// was wrongly judged an echo.
	RawTranscriptJSON = "transcript.raw.json"
	NotesJSON         = "notes.json"
	NotesMD           = "notes.md"
	WorkDir           = "work"
	ManifestVersion   = 1
	SampleRate        = 16000
	bytesPerSample    = 2
	DefaultRetention  = 30
)

// Warning codes a meeting can carry; the app turns them into plain words.
const (
	WarnNoSystemAudio = "no_system_audio" // the "them" channel is silent or missing
	WarnNoMicAudio    = "no_mic_audio"
	WarnLanguage      = "language_unsupported" // speech in a script the recognizer does not read
	WarnEchoDropped   = "echo_dropped"         // DropEcho removed "me" turns it judged an echo of the far side
)

// Manifest is meeting.json: everything about a meeting except its audio and
// text.
type Manifest struct {
	Version   int        `json:"version"`
	ID        string     `json:"id"`
	Title     string     `json:"title,omitempty"`
	Source    string     `json:"source,omitempty"` // zoom, meet, teams, manual...
	Started   time.Time  `json:"started"`
	Ended     *time.Time `json:"ended,omitempty"`
	Status    Status     `json:"status"`
	Error     string     `json:"error,omitempty"`
	Labels    Labels     `json:"labels"`
	EchoRisk  bool       `json:"echo_risk,omitempty"` // the Mac played the call on speakers
	Language  string     `json:"language,omitempty"`  // voices.Language of the speech, "" when unclear; picks the notes headings and names the language to the model
	DurationS float64    `json:"duration_s,omitempty"`
	Warnings  []string   `json:"warnings,omitempty"`
	// EchoDropped counts the "me" turns DropEcho removed; it goes with
	// WarnEchoDropped so the app can say more than "some echo was dropped".
	EchoDropped  int    `json:"echo_dropped,omitempty"`
	NotesPending string `json:"notes_pending,omitempty"` // model_missing | failed
	AudioDeleted bool   `json:"audio_deleted,omitempty"`
	// Attempts counts the times Recover put a failed meeting back in the
	// queue; Retry and a finished meeting reset it.
	Attempts int `json:"attempts,omitempty"`
}
