package meeting

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// blockingHandler holds every "meeting: wait" record until release is closed,
// and says when the first one arrived: a log handler that is slow.
type blockingHandler struct {
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (h *blockingHandler) Enabled(context.Context, slog.Level) bool { return true }
func (h *blockingHandler) Handle(_ context.Context, r slog.Record) error {
	if r.Message == "meeting: wait" {
		h.once.Do(func() { close(h.entered) })
		<-h.release
	}
	return nil
}
func (h *blockingHandler) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h *blockingHandler) WithGroup(string) slog.Handler      { return h }

// R1 — a wait line is written after the admission lock is released: a log
// handler stuck on it must not hold up the next admission.
// Mutation: internal/meeting/runner.go lockAdmission, call
// `logWait(r.Log, "", waitAdmission, r.Now().Sub(t))` before `return` (under
// the lock) and drop the deferred logWait in Enqueue -> RED (the second
// admission times out behind the blocked handler).
func TestAdmissionWaitLineIsWrittenOutsideTheLock(t *testing.T) {
	f := newFixture(t)
	h := &blockingHandler{entered: make(chan struct{}), release: make(chan struct{})}
	f.r.Log = slog.New(h)
	var offset, nowCalls atomic.Int64
	base := t0
	f.r.Now = func() time.Time {
		nowCalls.Add(1)
		return base.Add(time.Duration(offset.Load()))
	}

	holding, free := make(chan struct{}), make(chan struct{})
	go func() {
		_ = f.r.WithAdmissionLock(func(int) error {
			close(holding)
			<-free
			return nil
		})
	}()
	<-holding
	enq := make(chan struct{})
	go func() {
		defer close(enq)
		f.r.Enqueue("20260101-000000-aaaa") // stands in line behind the holder
	}()
	deadline := time.Now().Add(5 * time.Second)
	for nowCalls.Load() == 0 { // the waiter has read its start time and is about to block on the lock
		if time.Now().After(deadline) {
			t.Fatal("the second admission never reached the lock")
		}
		time.Sleep(time.Millisecond)
	}
	offset.Store(int64(time.Second)) // the holder kept the lock for a second
	close(free)
	select {
	case <-h.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("no wait line reached the log handler")
	}
	// The handler is now stuck on that line; a third admission must not queue behind it.
	third := make(chan struct{})
	go func() {
		defer close(third)
		_ = f.r.WithAdmissionLock(func(int) error { return nil })
	}()
	select {
	case <-third:
	case <-time.After(2 * time.Second):
		t.Fatal("an admission is blocked behind a log handler: the wait line is written under the lock")
	}
	close(h.release)
	<-enq
}

// R2 — a diarizer's error can wrap what the engine said; none of it reaches
// the log, only its class.
// Mutation: internal/meeting/voices.go:78 (the "diarization failed" line),
// replace slog.String("error_class", errClass(err)) with slog.Any("error", err)
// -> RED for the engine-error case; the same at voices.go:63 -> RED for the
// unavailable case.
func TestDiarizerErrorTextNeverReachesTheLog(t *testing.T) {
	const sentence = "zelda quillworth confirmed the zebra quorum unanimously"
	cases := map[string]error{
		"engine":      fmt.Errorf("ox-diar: %s", sentence),
		"unavailable": &DiarUnavailableError{Reason: "no_ane", Detail: sentence},
	}
	for name, derr := range cases {
		t.Run(name, func(t *testing.T) {
			f := groupFixture(t, &diarFake{err: derr})
			h := &capHandler{}
			f.r.Log = slog.New(h)
			id := f.start(t, 30, 30, 5000, false)
			if err := f.r.Process(context.Background(), id); err != nil {
				t.Fatal(err)
			}
			if len(h.find("meeting: diarization failed"))+len(h.find("meeting: diarization unavailable")) == 0 {
				t.Fatalf("the diarizer failure was not logged at all:\n%s", h.text())
			}
			if txt := strings.ToLower(h.text()); strings.Contains(txt, "quorum") || strings.Contains(txt, "quillworth") {
				t.Fatalf("the diarizer's words reached the log:\n%s", txt)
			}
		})
	}
}

// R2b — the notes model's error text stays out of the chunk-failure line too.
// Mutation: internal/meeting/notes.go:572 swap error_class for
// slog.Any("error", err) -> RED.
func TestNotesChunkErrorTextNeverReachesTheLog(t *testing.T) {
	const sentence = "zelda quillworth confirmed the zebra quorum unanimously"
	f, h := stagedFixture(t)
	bad := errors.New("model said: " + sentence)
	f.r.Chat = &fakeChat{errs: []error{bad, bad, bad, bad}}
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if len(h.find("notes: chunk failed")) == 0 {
		t.Fatalf("no chunk-failure line:\n%s", h.text())
	}
	if txt := strings.ToLower(h.text()); strings.Contains(txt, "quorum") {
		t.Fatalf("the model's words reached the log:\n%s", txt)
	}
}

// R3 — a stage that panics still gets its end line (failed, reason panic) and
// the meeting its summary, and the panic goes on.
// Mutation: internal/meeting/runner.go Process, change `defer sl.finish()` to
// `defer sl.summary()` -> RED (no end line for the transcribe stage).
func TestPanickingStageStillEndsAndSummarizes(t *testing.T) {
	f, h := stagedFixture(t)
	f.r.Transcribe = func(context.Context, string) (*stt.Result, error) { panic("recognizer exploded") }
	id := f.start(t, 30, 30, 5000, false)
	var got any
	func() {
		defer func() { got = recover() }()
		_ = f.r.Process(context.Background(), id)
	}()
	if got != "recognizer exploded" {
		t.Fatalf("recovered %v, want the original panic re-raised", got)
	}
	var end *capRecord
	for _, r := range h.find("meeting: stage") {
		if r.attrs["stage"] == stageTranscribe && r.attrs["event"] == "end" {
			c := r
			end = &c
		}
	}
	if end == nil || end.attrs["result"] != stageFailed || end.attrs["reason"] != "panic" {
		t.Fatalf("transcribe end = %v, want result=failed reason=panic:\n%s", end, h.text())
	}
	if n := len(h.find("meeting: summary")); n != 1 {
		t.Fatalf("summary lines = %d, want 1", n)
	}
}

// R4 — a failure before the first piece of work still has its stage lines and
// the meeting its summary: the stage begins before Store.Dir can fail.
// Mutation: internal/meeting/runner.go transcribe, move `done := sl.begin(
// stageTranscribe)` below the Store.Dir call -> RED (no stage lines).
func TestTranscribeFailureBeforeWorkIsStillLogged(t *testing.T) {
	f, h := stagedFixture(t)
	sl := newStageLog(f.r.Log, "bad", f.r.Now)
	err := f.r.transcribe(context.Background(), "../not-a-meeting-id", sl)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("transcribe err = %v, want ErrNotFound from Store.Dir", err)
	}
	sl.summary()
	var events []string
	for _, r := range h.find("meeting: stage") {
		events = append(events, r.attrs["stage"]+"/"+r.attrs["event"]+"/"+r.attrs["result"])
	}
	want := "transcribe/start/ transcribe/end/failed"
	if strings.Join(events, " ") != want {
		t.Fatalf("stage lines = %q, want %q", events, want)
	}
	if n := len(h.find("meeting: summary")); n != 1 {
		t.Fatalf("summary lines = %d, want 1", n)
	}
}
