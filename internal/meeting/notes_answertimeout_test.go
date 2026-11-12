package meeting

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// overtimeChat answers a map call with AnswerTimeoutError — the daemon's mark for a call that ran out of its own
// per-call deadline on a live engine — while its transcript part holds more than maxLines lines, and with one
// decision named after the part's first line otherwise. A call without a schema is the summary merge.
type overtimeChat struct {
	t        *testing.T
	maxLines int
	calls    int
}

func (o *overtimeChat) Complete(_ context.Context, r Request) (string, error) {
	if r.Schema == nil {
		return "merged summary", nil
	}
	o.calls++
	_, part, _ := strings.Cut(r.User, "TRANSCRIPT PART:\n")
	lines := strings.Split(strings.TrimRight(part, "\n"), "\n")
	if len(lines) > o.maxLines {
		return "", &AnswerTimeoutError{Err: context.DeadlineExceeded}
	}
	first, _, _ := strings.Cut(strings.TrimPrefix(lines[0], "[0:01] Me: "), " ")
	return replyJSON(o.t, ChunkNotes{Summary: "summary " + first, Decisions: []string{"decision " + first}}), nil
}

// A chunk whose answer ran out of the call's own deadline on a live engine is summarised in halves, not skipped:
// the slow Mac still gets notes for the long meeting, and the halves' items sit in order.
// Mutation: internal/meeting/notes.go summarise, drop the AnswerTimeoutError branch so the deadline is an
// ordinary failure again -> RED (SkippedChunks = [0] and no decisions).
func TestComposeSplitsAChunkWhoseAnswerRanOutOfTime(t *testing.T) {
	chat := &overtimeChat{t: t, maxLines: 100}
	text := splitTranscript(150)
	if n := len(Chunk(text, ChunkChars)); n != 1 {
		t.Fatalf("fixture is %d chunks, want 1", n)
	}
	n, err := (Composer{Chat: chat}).Compose(context.Background(), text, Labels{Me: "Me"}, "en")
	if err != nil {
		t.Fatal(err)
	}
	if len(n.SkippedChunks) != 0 {
		t.Fatalf("SkippedChunks = %v, want none: both halves summarised fine", n.SkippedChunks)
	}
	if got, want := strings.Join(n.Decisions, "|"), "decision L000|decision L075"; got != want {
		t.Fatalf("decisions = %q, want %q (both halves' items, in order)", got, want)
	}
	if chat.calls != 3 {
		t.Fatalf("map calls = %d, want 3 (the whole, then each half; the whole is not retried as it is)", chat.calls)
	}
}

// A deadline error WITHOUT the daemon's engine-alive mark — a hung or unreachable server, where nothing could
// tell a slow answer from a dead one — is an ordinary failure: the piece is lost, and no halves each burn the
// whole deadline.
// Mutation: internal/meeting/notes.go summarise, treat a bare context.DeadlineExceeded as splittable -> RED
// (7 calls instead of 1, and no error).
// The typed engine-down arm of the same rule is TestComposeStopsAtTheFirstEngineDownError.
func TestComposeDoesNotSplitAnUnmarkedDeadline(t *testing.T) {
	chat := &scriptChat{errs: []error{context.DeadlineExceeded}}
	text := splitTranscript(150)
	_, err := (Composer{Chat: chat}).Compose(context.Background(), text, Labels{Me: "Me"}, "en")
	if !errors.Is(err, ErrNoNotes) {
		t.Fatalf("err = %v, want ErrNoNotes: the one chunk is lost, not split", err)
	}
	if chat.calls != 1 {
		t.Fatalf("map calls = %d, want 1 (no retry, no split)", chat.calls)
	}
}

// cancelChat cancels the run's own context inside the call, then fails: whatever the call error says, a
// cancelled run must end, not split and not retry. (The daemon checks ctx.Err() before it ever wraps a deadline
// in AnswerTimeoutError, so the mark never reaches Compose on a cancelled run either.)
type cancelChat struct {
	cancel context.CancelFunc
	calls  int
}

func (c *cancelChat) Complete(context.Context, Request) (string, error) {
	c.calls++
	c.cancel()
	return "", errors.New("the call's context ended")
}

// The run's context ending mid-call is a cancellation, never a split or a retry: Compose returns ctx.Err() and
// no further call is made.
// Mutation: internal/meeting/notes.go summarise, drop the ctx.Err() check -> RED (ErrNoNotes, not Canceled).
// Mutation: internal/meeting/notes.go chunk, drop its ctx.Err() check -> RED (a second, wasted call: calls = 2).
func TestACancelledRunIsNotSplit(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	chat := &cancelChat{cancel: cancel}
	_, err := (Composer{Chat: chat}).Compose(ctx, splitTranscript(150), Labels{Me: "Me"}, "en")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want the run's own cancellation, not a split or a lost chunk", err)
	}
	if chat.calls != 1 {
		t.Fatalf("map calls = %d, want 1: a cancelled run makes no further calls", chat.calls)
	}
}
