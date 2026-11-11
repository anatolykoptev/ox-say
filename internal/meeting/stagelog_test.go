package meeting

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/stt"
)

// capHandler is a test slog.Handler keeping every record's message and
// attributes, so the meeting's stage, wait and summary lines can be asserted.
type capHandler struct {
	mu   sync.Mutex
	recs []capRecord
}

type capRecord struct {
	msg   string
	attrs map[string]string
	raw   string // message plus attributes, for the privacy check
}

func (h *capHandler) Enabled(context.Context, slog.Level) bool { return true }

func (h *capHandler) Handle(_ context.Context, r slog.Record) error {
	rec := capRecord{msg: r.Message, attrs: map[string]string{}}
	var b strings.Builder
	b.WriteString(r.Message)
	r.Attrs(func(a slog.Attr) bool {
		rec.attrs[a.Key] = a.Value.String()
		b.WriteByte(' ')
		b.WriteString(a.Key)
		b.WriteByte('=')
		b.WriteString(a.Value.String())
		return true
	})
	rec.raw = b.String()
	h.mu.Lock()
	h.recs = append(h.recs, rec)
	h.mu.Unlock()
	return nil
}

func (h *capHandler) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h *capHandler) WithGroup(string) slog.Handler      { return h }

func (h *capHandler) find(msg string) []capRecord {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []capRecord
	for _, r := range h.recs {
		if r.msg == msg {
			out = append(out, r)
		}
	}
	return out
}

func (h *capHandler) text() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	var b strings.Builder
	for _, r := range h.recs {
		b.WriteString(r.raw)
		b.WriteByte('\n')
	}
	return b.String()
}

// stagedFixture runs the log through a capture handler.
func stagedFixture(t *testing.T) (*fixture, *capHandler) {
	t.Helper()
	f := newFixture(t)
	h := &capHandler{}
	f.r.Log = slog.New(h)
	return f, h
}

// F1 — the journey: a meeting end to end leaves a start and an end line for
// every stage in the pipeline's order, then one summary whose per-stage
// durations do not exceed its total. The group fixture wires a real diarizer
// fake so the diarize and voices stages run, not skip.
// Mutation: internal/meeting/voices.go voices, delete the `done(stageOK, "")`
// call site that ends the diarize stage -> RED (no diarize end line).
func TestStageLogCoversEveryStageInOrder(t *testing.T) {
	f := groupFixture(t, &diarFake{})
	h := &capHandler{}
	f.r.Log = slog.New(h)
	good := f.r.Transcribe
	f.r.Transcribe = func(ctx context.Context, wav string) (*stt.Result, error) {
		f.now = f.now.Add(time.Second) // the recognizer took a second
		return good(ctx, wav)
	}
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	type step struct{ stage, event string }
	var got []step
	for _, r := range h.find("meeting: stage") {
		if r.attrs["id"] != id {
			t.Errorf("stage line for another meeting: %v", r.attrs)
		}
		got = append(got, step{r.attrs["stage"], r.attrs["event"]})
	}
	want := []step{
		{"transcribe", "start"}, {"transcribe", "end"},
		{"echo", "start"}, {"echo", "end"},
		{"diarize", "start"}, {"diarize", "end"},
		{"voices", "start"}, {"voices", "end"},
		{"notes", "start"}, {"notes", "end"},
	}
	if len(got) != len(want) {
		t.Fatalf("stage events = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("stage event %d = %v, want %v (all: %v)", i, got[i], want[i], got)
		}
	}
	sums := h.find("meeting: summary")
	if len(sums) != 1 {
		t.Fatalf("summary lines = %d, want 1", len(sums))
	}
	total, err := strconv.ParseInt(sums[0].attrs["total_ms"], 10, 64)
	if err != nil {
		t.Fatalf("summary total_ms = %q: %v", sums[0].attrs["total_ms"], err)
	}
	var sum int64
	for _, stage := range []string{"transcribe", "echo", "diarize", "voices", "notes"} {
		v, ok := sums[0].attrs[stage+"_ms"]
		if !ok {
			t.Fatalf("summary lacks %s_ms (attrs: %v)", stage, sums[0].attrs)
		}
		ms, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			t.Fatalf("summary %s_ms = %q: %v", stage, v, err)
		}
		sum += ms
	}
	if sum > total {
		t.Fatalf("stage durations sum %d ms > total %d ms", sum, total)
	}
	t.Log(h.text()) // one meeting's whole log, for the report and for debugging
}

// F2 — the journey: a transcription that stood behind a dictation leaves a
// wait line naming the dictation priority and how long it stood there.
// Mutation: internal/meeting/runner.go waitBefore, replace
// `return sl.timed(waitDictation, func() error { return r.Before(ctx) })` with
// `return r.Before(ctx)` -> RED (no wait line).
func TestStageLogNamesTheDictationWait(t *testing.T) {
	f, h := stagedFixture(t)
	f.r.Before = func(context.Context) error {
		f.now = f.now.Add(time.Second) // the dictation yield held a second
		return nil
	}
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, r := range h.find("meeting: wait") {
		if r.attrs["id"] != id || r.attrs["wait"] != "dictation" {
			continue
		}
		ms, _ := strconv.ParseInt(r.attrs["dur_ms"], 10, 64)
		if ms >= 1000 {
			found = true
		}
	}
	if !found {
		t.Fatalf("no wait line naming the dictation priority with dur_ms >= 1000:\n%s", h.text())
	}
}

// F3 — the journey: a notes stage that fails ends failed with the error's
// class, and the meeting's summary line is still written.
// Mutation: internal/meeting/runner.go summarize, delete the
// `done(stageFailed, errClass(err))` on the compose error path -> RED.
func TestStageLogStillSummarizesAFailedNotesStage(t *testing.T) {
	f, h := stagedFixture(t)
	fail := errors.New("the notes model refused")
	f.r.Chat = &fakeChat{errs: []error{fail, fail, fail, fail}}
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	var end *capRecord
	for _, r := range h.find("meeting: stage") {
		if r.attrs["stage"] == "notes" && r.attrs["event"] == "end" {
			got := r
			end = &got
		}
	}
	if end == nil {
		t.Fatalf("no notes stage end line:\n%s", h.text())
	}
	if end.attrs["result"] != "failed" || end.attrs["reason"] == "" {
		t.Fatalf("notes stage end = %v, want result=failed with the error class", end.attrs)
	}
	if got := len(h.find("meeting: summary")); got != 1 {
		t.Fatalf("summary lines = %d, want 1 even on a failed stage", got)
	}
}

// F4 — privacy: whatever the transcript said, none of it reaches the log.
// Mutation: internal/meeting/runner.go transcribe, add
// `r.Log.Info("meeting: turns", slog.Any("turns", turns))` after the
// MergeTurns line -> RED (the turn text carries the sentence and the name).
func TestStageLogNeverCarriesTranscriptText(t *testing.T) {
	f, h := stagedFixture(t)
	const sentence = "zelda quillworth confirmed the zebra quorum unanimously"
	const name = "quillworth"
	f.r.Transcribe = func(_ context.Context, _ string) (*stt.Result, error) {
		return &stt.Result{Words: words(1, sentence)}, nil
	}
	id := f.start(t, 30, 30, 5000, false)
	if err := f.r.Process(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	dir, _ := f.r.Store.Dir(id)
	if tr, _ := os.ReadFile(filepath.Join(dir, TranscriptMD)); !strings.Contains(strings.ToLower(string(tr)), "quorum") {
		t.Fatal("the transcript does not carry the distinctive sentence — the run did not transcribe it")
	}
	text := strings.ToLower(h.text())
	if strings.Contains(text, name) || strings.Contains(text, "quorum") {
		t.Fatalf("the meeting's log carries transcript text:\n%s", text)
	}
}
