package meeting

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/anatolykoptev/ox-say/internal/pcm"
	"github.com/anatolykoptev/ox-say/internal/stt"
	"github.com/anatolykoptev/ox-say/internal/voices"
	"github.com/anatolykoptev/ox-say/internal/vproject"
)

const (
	// minNotesWords: a transcript with fewer words is not sent to the model.
	minNotesWords = 25
	// staleRecording: a meeting still "recording" whose audio files have not
	// grown for this long lost its app (a crash, a kill): it is finished with
	// what reached the disk.
	staleRecording = 3 * time.Minute
	busyRetries    = 3
	busyWait       = 5 * time.Second
)

// Deps is everything the runner needs from outside. The daemon wires the
// real recognizer, model and dictation yield; tests wire fakes.
type Deps struct {
	Store *Store
	// Transcribe recognizes one 16 kHz mono WAV file.
	Transcribe func(ctx context.Context, wav string) (*stt.Result, error)
	Chat       Chat
	// NotesReady returns "" when the notes model can run, else the reason
	// code ("model_missing", "unsupported"); the transcript is then kept and
	// the notes wait.
	NotesReady func() string
	// Before runs ahead of every recognizer or model call; the daemon passes
	// the dictation yield. Nil: no waiting.
	Before func(ctx context.Context) error
	Now    func() time.Time
	Sleep  func(time.Duration)
	Log    *slog.Logger
	// PieceSeconds is the recognizer piece length; 0 means DefaultPieceSeconds.
	PieceSeconds int
}

// Runner takes finished meetings through transcription and notes, one at a
// time: the Mac runs one heavy model job at once.
type Runner struct {
	Deps
	mu      sync.Mutex
	pending map[string]bool
	order   []string
	wake    chan struct{}
}

// NewRunner fills the defaults of d.
func NewRunner(d Deps) *Runner {
	if d.Now == nil {
		d.Now = time.Now
	}
	if d.Sleep == nil {
		d.Sleep = time.Sleep
	}
	if d.Log == nil {
		d.Log = slog.Default()
	}
	return &Runner{Deps: d, pending: map[string]bool{}, wake: make(chan struct{}, 1)}
}

// Enqueue schedules a meeting; a meeting already queued or running is not
// queued twice.
func (r *Runner) Enqueue(id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.pending[id] {
		return
	}
	r.pending[id] = true
	r.order = append(r.order, id)
	select {
	case r.wake <- struct{}{}:
	default:
	}
}

// Active is the number of meetings queued or running: /status reports it as
// busy work a daemon restart would interrupt.
func (r *Runner) Active() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.pending)
}

func (r *Runner) next() (string, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.order) == 0 {
		return "", false
	}
	id := r.order[0]
	r.order = r.order[1:]
	return id, true
}

// Run processes the queue until ctx ends.
func (r *Runner) Run(ctx context.Context) {
	for {
		id, ok := r.next()
		if !ok {
			select {
			case <-ctx.Done():
				return
			case <-r.wake:
				continue
			}
		}
		if err := r.Process(ctx, id); err != nil && ctx.Err() == nil {
			r.Log.Warn("meeting: processing failed", slog.String("id", id), slog.Any("error", err))
		}
		r.mu.Lock()
		delete(r.pending, id)
		r.mu.Unlock()
	}
}

// Finish ends a recording: it stamps the end time and queues the meeting.
// Calling it again for a meeting that is already past recording changes nothing.
func (r *Runner) Finish(id string, ended time.Time) (*Manifest, error) {
	m, err := r.Store.Update(id, func(m *Manifest) {
		if m.Status != StatusRecording {
			return
		}
		m.Ended = &ended
		m.Status = StatusQueued
	})
	if err != nil {
		return nil, err
	}
	r.Enqueue(id)
	return m, nil
}

// RetryNotes queues the notes step again for a meeting whose transcript is ready.
func (r *Runner) RetryNotes(id string) (*Manifest, error) {
	var bad bool
	m, err := r.Store.Update(id, func(m *Manifest) {
		if m.Status != StatusTranscribed && m.Status != StatusDone {
			bad = true
			return
		}
		m.Status, m.NotesPending, m.Error = StatusSummarizing, "", ""
	})
	if err != nil {
		return nil, err
	}
	if bad {
		return m, fmt.Errorf("meeting: %s has no transcript yet", id)
	}
	r.Enqueue(id)
	return m, nil
}

// Recover queues every meeting a stopped daemon left half done and finishes
// the recordings whose app is gone. Call it once at start, then from Housekeep.
func (r *Runner) Recover() {
	list, err := r.Store.List()
	if err != nil {
		r.Log.Warn("meeting: cannot list meetings", slog.Any("error", err))
		return
	}
	for _, m := range list {
		switch m.Status {
		case StatusQueued, StatusTranscribing, StatusSummarizing:
			r.Enqueue(m.ID)
		case StatusRecording:
			r.finishIfStale(m)
		}
	}
}

func (r *Runner) finishIfStale(m Manifest) {
	dir, err := r.Store.Dir(m.ID)
	if err != nil {
		return
	}
	last := m.Started
	for _, name := range []string{MePCM, ThemPCM, ManifestFile} {
		if st, err := os.Stat(filepath.Join(dir, name)); err == nil && st.ModTime().After(last) {
			last = st.ModTime()
		}
	}
	if r.Now().Sub(last) < staleRecording {
		return
	}
	if _, err := r.Finish(m.ID, last); err != nil {
		r.Log.Warn("meeting: cannot finish an orphaned recording", slog.String("id", m.ID), slog.Any("error", err))
	}
}

// Housekeep runs Recover and the retention sweep every interval until ctx ends.
func (r *Runner) Housekeep(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		r.Recover()
		r.SweepRetention()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Process runs the meeting's remaining steps. A daemon shutdown (ctx) leaves
// the meeting where it was, so the next start resumes it; any other failure
// marks it failed with the reason, and keeps its audio.
func (r *Runner) Process(ctx context.Context, id string) error {
	m, err := r.Store.Load(id)
	if errors.Is(err, ErrNotFound) {
		return nil // deleted while queued
	}
	if err != nil {
		return err
	}
	if m.Status == StatusQueued || m.Status == StatusTranscribing {
		if err := r.transcribe(ctx, id); err != nil {
			return r.stop(ctx, id, err)
		}
	} else if m.Status != StatusSummarizing {
		return nil
	}
	if err := r.summarize(ctx, id); err != nil {
		return r.stop(ctx, id, err)
	}
	return nil
}

func (r *Runner) stop(ctx context.Context, id string, err error) error {
	if ctx.Err() != nil || errors.Is(err, ErrNotFound) {
		return err
	}
	_, uerr := r.Store.Update(id, func(m *Manifest) { m.Status, m.Error = StatusFailed, err.Error() })
	if uerr != nil {
		r.Log.Warn("meeting: cannot record a failure", slog.String("id", id), slog.Any("error", uerr))
	}
	return err
}

type channel struct {
	file  string
	label string
}

var channels = []channel{{MePCM, SpeakerMe}, {ThemPCM, SpeakerThem}}

// transcribe recognizes both channels piece by piece, caching each piece so a
// restart resumes where it stopped, then merges them into the transcript.
func (r *Runner) transcribe(ctx context.Context, id string) error {
	m, err := r.Store.Update(id, func(m *Manifest) { m.Status = StatusTranscribing })
	if err != nil {
		return err
	}
	dir, err := r.Store.Dir(id)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(dir, WorkDir), 0o700); err != nil {
		return err
	}
	words := map[string][]stt.Word{}
	var warnings []string
	var seconds float64
	for _, ch := range channels {
		w, speech, secs, err := r.channelWords(ctx, dir, ch)
		if err != nil {
			return err
		}
		words[ch.label] = w
		seconds = max(seconds, secs)
		if !speech {
			warnings = append(warnings, map[string]string{SpeakerMe: WarnNoMicAudio, SpeakerThem: WarnNoSystemAudio}[ch.label])
		}
	}
	turns := MergeTurns(words[SpeakerMe], words[SpeakerThem])
	dropped := 0
	if m.EchoRisk {
		var kept []Turn
		kept, dropped = DropEcho(turns)
		if dropped > 0 {
			// Keep the turns as they were before the drop: a turn wrongly
			// judged an echo can be put back from this file.
			raw, err := json.MarshalIndent(turns, "", " ")
			if err != nil {
				return err
			}
			if err := vproject.WriteAtomic(filepath.Join(dir, RawTranscriptJSON), raw, 0o600); err != nil {
				return err
			}
			warnings = append(warnings, WarnEchoDropped)
		}
		turns = kept
	}
	lang := "en"
	var spoken strings.Builder // the words only: speaker names would count as Latin letters
	for _, t := range turns {
		spoken.WriteString(t.Text)
		spoken.WriteByte(' ')
	}
	script := voices.Script(spoken.String())
	if script == "cyrillic" {
		lang = "ru"
	}
	// The recognizer reads 25 European languages; speech in another script
	// comes out as a transliteration. Say so instead of summarizing nonsense.
	if script == "" && WordCount(turns) >= minNotesWords {
		warnings = append(warnings, WarnLanguage)
	}
	raw, err := json.MarshalIndent(turns, "", " ")
	if err != nil {
		return err
	}
	if err := vproject.WriteAtomic(filepath.Join(dir, TranscriptJSON), raw, 0o600); err != nil {
		return err
	}
	if err := vproject.WriteAtomic(filepath.Join(dir, TranscriptMD), []byte(TranscriptMarkdown(*m, turns)), 0o600); err != nil {
		return err
	}
	_, err = r.Store.Update(id, func(m *Manifest) {
		m.Status, m.Language, m.DurationS, m.Warnings, m.EchoDropped = StatusTranscribed, lang, seconds, warnings, dropped
	})
	return err
}

// channelWords recognizes one channel file. speech is false when the file is
// missing, empty or silent throughout — the sign of a capture that heard nothing.
func (r *Runner) channelWords(ctx context.Context, dir string, ch channel) (words []stt.Word, speech bool, seconds float64, err error) {
	f, err := os.Open(filepath.Join(dir, ch.file))
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, 0, nil
	}
	if err != nil {
		return nil, false, 0, err
	}
	defer func() { _ = f.Close() }()
	st, err := f.Stat()
	if err != nil {
		return nil, false, 0, err
	}
	spans, err := Spans(f, st.Size(), r.PieceSeconds)
	if err != nil {
		return nil, false, 0, err
	}
	for _, sp := range spans {
		w, loud, err := r.pieceWords(ctx, dir, f, ch, sp)
		if err != nil {
			return nil, false, 0, err
		}
		words = append(words, w...)
		speech = speech || loud
	}
	return words, speech, float64(st.Size()/bytesPerSample) / SampleRate, nil
}

// pieceCache is one recognized piece on disk: the words, and whether the
// audio held speech at all. A loud piece can yield no words (music, a cough);
// caching only the words would read it back as silence on a resume and warn
// about a channel that actually spoke.
type pieceCache struct {
	Words []stt.Word `json:"words"`
	Loud  bool       `json:"loud"`
}

func (r *Runner) pieceWords(ctx context.Context, dir string, f io.ReaderAt, ch channel, sp Span) ([]stt.Word, bool, error) {
	cache := filepath.Join(dir, WorkDir, fmt.Sprintf("%s-%d-%d.json", ch.label, sp.From, sp.To))
	if raw, err := os.ReadFile(cache); err == nil {
		var pc pieceCache
		if json.Unmarshal(raw, &pc) == nil {
			return pc.Words, pc.Loud, nil
		}
	}
	clip, err := ReadClip(f, sp)
	if err != nil {
		return nil, false, err
	}
	var words []stt.Word
	loud := !Silent(clip)
	if loud {
		if words, err = r.recognize(ctx, dir, ch, sp, clip); err != nil {
			return nil, false, err
		}
	}
	raw, _ := json.Marshal(pieceCache{Words: words, Loud: loud})
	if err := vproject.WriteAtomic(cache, raw, 0o600); err != nil {
		return nil, false, err
	}
	return words, loud, nil
}

func (r *Runner) recognize(ctx context.Context, dir string, ch channel, sp Span, clip pcm.Clip) ([]stt.Word, error) {
	wav := filepath.Join(dir, WorkDir, fmt.Sprintf("%s-%d.wav", ch.label, sp.From))
	if err := os.WriteFile(wav, clip.Encode(), 0o600); err != nil {
		return nil, err
	}
	defer func() { _ = os.Remove(wav) }()
	var res *stt.Result
	var err error
	for attempt := 0; attempt < busyRetries; attempt++ {
		if r.Before != nil {
			if err := r.Before(ctx); err != nil {
				return nil, err
			}
		}
		if res, err = r.Transcribe(ctx, wav); !errors.Is(err, stt.ErrBusy) {
			break
		}
		r.Sleep(busyWait)
	}
	if err != nil {
		return nil, err
	}
	offset := float64(sp.From) / SampleRate
	out := make([]stt.Word, len(res.Words))
	for i, w := range res.Words {
		w.S += offset
		w.E += offset
		out[i] = w
	}
	return out, nil
}

// summarize writes the notes, or leaves the transcript waiting for them.
func (r *Runner) summarize(ctx context.Context, id string) error {
	m, err := r.Store.Load(id)
	if err != nil {
		return err
	}
	dir, err := r.Store.Dir(id)
	if err != nil {
		return err
	}
	var turns []Turn
	raw, err := os.ReadFile(filepath.Join(dir, TranscriptJSON))
	if err == nil {
		err = json.Unmarshal(raw, &turns)
	}
	if err != nil {
		return fmt.Errorf("meeting: no transcript to summarize: %w", err)
	}
	if WordCount(turns) < minNotesWords {
		return r.writeNotes(id, dir, ShortNotesMarkdown(*m, m.Language), nil)
	}
	if r.NotesReady != nil {
		if code := r.NotesReady(); code != "" {
			_, err := r.Store.Update(id, func(m *Manifest) { m.Status, m.NotesPending = StatusTranscribed, code })
			return err
		}
	}
	if _, err := r.Store.Update(id, func(m *Manifest) { m.Status, m.NotesPending, m.Error = StatusSummarizing, "", "" }); err != nil {
		return err
	}
	notes, err := Composer{Chat: r.Chat, Before: r.Before, Log: r.Log}.Compose(ctx, PromptText(*m, turns), m.Labels, m.Language)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		_, uerr := r.Store.Update(id, func(m *Manifest) {
			m.Status, m.NotesPending, m.Error = StatusTranscribed, "failed", err.Error()
		})
		return uerr
	}
	return r.writeNotes(id, dir, NotesMarkdown(*m, notes, m.Language), &notes)
}

func (r *Runner) writeNotes(id, dir, md string, n *Notes) error {
	if n != nil {
		raw, err := json.MarshalIndent(n, "", " ")
		if err != nil {
			return err
		}
		if err := vproject.WriteAtomic(filepath.Join(dir, NotesJSON), raw, 0o600); err != nil {
			return err
		}
	}
	if err := vproject.WriteAtomic(filepath.Join(dir, NotesMD), []byte(md), 0o600); err != nil {
		return err
	}
	_, err := r.Store.Update(id, func(m *Manifest) { m.Status, m.NotesPending, m.Error = StatusDone, "", "" })
	return err
}
