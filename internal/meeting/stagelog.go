package meeting

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// waitLogMin: only a wait that lasted at least this long gets its own line —
// an idle run stays quiet, a stalled one says what it stood behind.
const waitLogMin = 250 * time.Millisecond

// The processing stages a finished meeting goes through (issue #526): the
// order the log shows them in is the order this file lists them in.
const (
	stageTranscribe = "transcribe"
	stageEcho       = "echo"
	stageDiarize    = "diarize"
	stageVoices     = "voices"
	stageNotes      = "notes"
)

// A stage end's result.
const (
	stageOK      = "ok"
	stageSkipped = "skipped" // the stage did not run; reason says why
	stageFailed  = "failed"  // the stage ended on an error; reason is errClass
)

// reasonPanic is a failed stage's reason when the run panicked inside it.
const reasonPanic = "panic"

// The things a stage or a call can wait on (the wait line's "wait" value).
const (
	waitDictation  = "dictation"   // the dictation yield ahead of an engine call
	waitQueue      = "queue"       // the processing queue between Enqueue and Process
	waitAdmission  = "admission"   // the queue lock itself (a model trial holds it)
	waitNotesModel = "notes_model" // the notes model's engine reservation
	waitSTTQueue   = "stt_queue"   // the recognizer's queue (ErrBusy)
	waitSTTRetry   = "stt_retry"   // the backoff between recognizer retries
)

// stageLog writes one meeting's processing story (issue #526): a line when a
// stage starts and one when it ends with its duration and outcome, a line for
// every wait that lasted, and one summary at the end — so a slow or stuck
// meeting is diagnosable from the log alone. Nothing it logs carries text:
// ids, stage names, durations, counts and error classes only.
//
// A nil *stageLog is valid and silent: tests that drive a stage function
// directly pass nil.
type stageLog struct {
	log   *slog.Logger
	id    string
	now   func() time.Time
	total time.Time
	durs  []stageDur
	open  []*openStage // begun, not yet ended: finish closes them on a panic
}

// openStage is a begun stage whose end line has not been written yet.
type openStage struct {
	end   stageEnd
	ended bool
}

type stageDur struct {
	stage string
	ms    int64
}

func newStageLog(l *slog.Logger, id string, now func() time.Time) *stageLog {
	if now == nil {
		now = time.Now
	}
	return &stageLog{log: l, id: id, now: now, total: now()}
}

// stageEnd closes the stage begin opened: result is stageOK, stageSkipped or
// stageFailed; reason is empty, the skip's cause, or errClass of the error.
// Extra attrs are counts only (pieces, dropped turns, voices).
type stageEnd func(result, reason string, attrs ...slog.Attr)

// begin writes the stage's start line and returns its end. The end logs the
// stage once however often it is called.
func (s *stageLog) begin(stage string) stageEnd {
	if s == nil || s.log == nil {
		return func(string, string, ...slog.Attr) {}
	}
	s.log.Info("meeting: stage",
		slog.String("id", s.id), slog.String("stage", stage), slog.String("event", "start"))
	t := s.now()
	run := &openStage{}
	s.open = append(s.open, run)
	run.end = func(result, reason string, attrs ...slog.Attr) {
		if run.ended {
			return
		}
		run.ended = true
		d := s.now().Sub(t)
		s.durs = append(s.durs, stageDur{stage, d.Milliseconds()})
		args := make([]slog.Attr, 0, 7+len(attrs))
		args = append(args,
			slog.String("id", s.id), slog.String("stage", stage), slog.String("event", "end"),
			slog.Int64("dur_ms", d.Milliseconds()), slog.String("result", result))
		if reason != "" {
			args = append(args, slog.String("reason", reason))
		}
		args = append(args, attrs...)
		lvl := slog.LevelInfo
		if result == stageFailed {
			lvl = slog.LevelWarn
		}
		s.log.LogAttrs(context.Background(), lvl, "meeting: stage", args...)
	}
	return run.end
}

// skip is a stage that never ran, written as start and end in one: the log's
// stage order stays whole and the reason says what was missing.
func (s *stageLog) skip(stage, reason string) {
	s.begin(stage)(stageSkipped, reason)
}

// waited logs a wait line when d crossed waitLogMin.
func (s *stageLog) waited(what string, d time.Duration) {
	if s == nil {
		return
	}
	logWait(s.log, s.id, what, d)
}

// timed runs fn and logs a wait line when it lasted past waitLogMin.
func (s *stageLog) timed(what string, fn func() error) error {
	if s == nil || s.log == nil {
		return fn()
	}
	t := s.now()
	err := fn()
	s.waited(what, s.now().Sub(t))
	return err
}

// finish is Process's deferred closer: it writes the summary on every way out,
// and when the run is unwinding from a panic it first ends each stage still
// open as failed with reasonPanic (a recovered panic must not leave a stage
// with a start line and no end), then lets the panic go on.
func (s *stageLog) finish() {
	p := recover()
	if p != nil && s != nil {
		for i := len(s.open) - 1; i >= 0; i-- {
			s.open[i].end(stageFailed, reasonPanic)
		}
	}
	s.summary()
	if p != nil {
		panic(p)
	}
}

// summary writes the meeting's one closing line — the run's wall time and the
// duration of every stage that ran. A Process that did no stage writes none.
func (s *stageLog) summary() {
	if s == nil || s.log == nil || len(s.durs) == 0 {
		return
	}
	args := make([]slog.Attr, 0, len(s.durs)+2)
	args = append(args,
		slog.String("id", s.id),
		slog.Int64("total_ms", s.now().Sub(s.total).Milliseconds()))
	for _, d := range s.durs {
		args = append(args, slog.Int64(d.stage+"_ms", d.ms))
	}
	s.log.LogAttrs(context.Background(), slog.LevelInfo, "meeting: summary", args...)
}

// logWait writes one "meeting: wait" line when d crossed waitLogMin. what
// names what was waited for; id is the meeting's, "" where the caller has none.
func logWait(l *slog.Logger, id, what string, d time.Duration) {
	if l == nil || d < waitLogMin {
		return
	}
	args := make([]slog.Attr, 0, 4)
	if id != "" {
		args = append(args, slog.String("id", id))
	}
	args = append(args, slog.String("wait", what), slog.Int64("dur_ms", d.Milliseconds()))
	l.LogAttrs(context.Background(), slog.LevelInfo, "meeting: wait", args...)
}

// errClass is a stage failure's stable class — never the error's text, which
// can carry a server's words or a path: a reason code, an HTTP status, a
// sentinel name, else the Go type without its package.
func errClass(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, context.Canceled):
		return "canceled"
	case errors.Is(err, context.DeadlineExceeded):
		return "deadline"
	case errors.Is(err, errNoTranscript):
		return "no_transcript"
	case errors.Is(err, ErrNoNotes):
		return "no_notes"
	case errors.Is(err, stt.ErrBusy):
		return "stt_busy"
	}
	var down *EngineDownError
	if errors.As(err, &down) && down.Reason != "" {
		return down.Reason
	}
	var se *StatusError
	if errors.As(err, &se) {
		return fmt.Sprintf("http_%d", se.Code)
	}
	var model *stt.ModelError
	if errors.As(err, &model) {
		return "stt_model"
	}
	var timeout *stt.TimeoutError
	if errors.As(err, &timeout) {
		return "stt_timeout"
	}
	var engine *stt.EngineError
	if errors.As(err, &engine) {
		return "stt_engine"
	}
	var input *stt.InputError
	if errors.As(err, &input) {
		return "stt_input"
	}
	cls := fmt.Sprintf("%T", err)
	if i := strings.LastIndex(cls, "."); i >= 0 {
		cls = cls[i+1:]
	}
	return strings.TrimLeft(cls, "*")
}
