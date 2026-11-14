package meeting

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
)

// An engine failure that merely wraps context.DeadlineExceeded, raised while the
// run's budget is still live, is the engine's failure: Compose returns it. It
// is not the run budget running out, which would mark the chunks skipped and
// hide the failure behind ErrNoNotes.
// Mutation: internal/meeting/notes.go Compose, `errors.Is(runCtx.Err(),
// context.DeadlineExceeded)` -> `errors.Is(err, context.DeadlineExceeded)` -> RED.
func TestComposeEngineDownWrappingADeadlineIsNotTheRunBudget(t *testing.T) {
	down := &EngineDownError{Err: fmt.Errorf("start: %w", context.DeadlineExceeded), Retryable: false, Reason: FailNotesEngineTimeout}
	chat := &fakeChat{errs: []error{down}}
	_, err := (Composer{Chat: chat}).Compose(context.Background(), splitTranscript(10), Labels{Me: "Me"}, "en")
	var got *EngineDownError
	if !errors.As(err, &got) {
		t.Fatalf("err = %v, want the EngineDownError (not ErrNoNotes or a skipped run)", err)
	}
}

// slowSplitChat makes one 150-line chunk split into quarters: a part longer
// than 40 lines overflows; the first three quarters answer after slow, the
// last one waits for its context to end.
type slowSplitChat struct {
	t    *testing.T
	slow time.Duration
	mu   sync.Mutex
	ok   int
}

func (s *slowSplitChat) Complete(ctx context.Context, r Request) (string, error) {
	if r.Schema == nil {
		return "merged summary", nil
	}
	_, part, _ := strings.Cut(r.User, "TRANSCRIPT PART:\n")
	lines := strings.Split(strings.TrimRight(part, "\n"), "\n")
	if len(lines) > 40 {
		return `{"summary": "cut off`, ErrTruncated
	}
	s.mu.Lock()
	s.ok++
	n := s.ok
	s.mu.Unlock()
	if n > 3 {
		<-ctx.Done()
		return "", ctx.Err()
	}
	time.Sleep(s.slow)
	first, _, _ := strings.Cut(strings.TrimPrefix(lines[0], "[0:01] Me: "), " ")
	return replyJSON(s.t, ChunkNotes{Summary: "summary " + first, Decisions: []string{"decision " + first}}), nil
}

// The run budget ends while a split chunk's last quarter is in flight: the three
// quarters that finished stay in the notes, the chunk is recorded as skipped.
// CallTimeout 1s gives a 3s budget; each answered quarter takes 0.8s, so the
// fourth starts at 2.4s with 0.6s of budget and 1s of its own deadline left.
// Mutation: internal/meeting/notes.go summarise half loop, `return append(parts, got...), true, err`
// -> `return nil, false, err` -> RED (ErrNoNotes).
func TestComposeKeepsFinishedHalvesWhenTheRunBudgetEnds(t *testing.T) {
	chat := &slowSplitChat{t: t, slow: 800 * time.Millisecond}
	text := splitTranscript(150)
	if n := len(Chunk(text, ChunkChars)); n != 1 {
		t.Fatalf("fixture is %d chunks, want 1", n)
	}
	n, err := (Composer{Chat: chat, CallTimeout: time.Second}).Compose(context.Background(), text, Labels{Me: "Me"}, "en")
	if err != nil {
		t.Fatalf("Compose = %v, want the finished quarters' notes", err)
	}
	if len(n.Decisions) != 3 {
		t.Fatalf("decisions = %q, want the 3 finished quarters", n.Decisions)
	}
	if len(n.SkippedChunks) != 1 || n.SkippedChunks[0] != 0 {
		t.Fatalf("skipped = %v, want [0]", n.SkippedChunks)
	}
}
