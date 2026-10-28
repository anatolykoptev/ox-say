package meeting

import (
	"context"
	"errors"
	"strings"
	"testing"
)

type downChat struct{ calls int }

func (c *downChat) Complete(context.Context, Request) (string, error) {
	c.calls++
	return "", &EngineDownError{Err: errors.New("the server runs open")}
}

// A notes engine that is down is not retried per chunk: the run stops at the
// first such error and returns it, so the meeting records why (not "no
// notes"), and a long transcript does not reload the model once per chunk.
// Mutation: notes.go Compose, delete the EngineDownError early return ->
// RED (every chunk calls the model and ErrNoNotes hides the cause).
// Mutation: notes.go chunk, delete the EngineDownError early return -> RED
// (the second attempt calls the model again).
func TestComposeStopsAtTheFirstEngineDownError(t *testing.T) {
	chat := &downChat{}
	text := strings.Repeat("word ", ChunkChars/5*2)
	if n := len(Chunk(text, ChunkChars)); n < 2 {
		t.Fatalf("test transcript has %d chunk(s), want at least 2", n)
	}
	_, err := Composer{Chat: chat}.Compose(context.Background(), text, Labels{}, "en")
	var down *EngineDownError
	if !errors.As(err, &down) || errors.Is(err, ErrNoNotes) {
		t.Fatalf("err = %v, want the engine-down error itself", err)
	}
	if !strings.Contains(err.Error(), "runs open") {
		t.Fatalf("err = %q hides the cause", err)
	}
	if chat.calls != 1 {
		t.Fatalf("model calls = %d, want exactly 1", chat.calls)
	}
}

type scriptChat struct {
	errs  []error // one per call; nil entry = answer
	calls int
}

func (c *scriptChat) Complete(context.Context, Request) (string, error) {
	i := c.calls
	c.calls++
	if i < len(c.errs) && c.errs[i] != nil {
		return "", c.errs[i]
	}
	return `{"summary":"A planning call.","decisions":["Ship Friday"],"action_items":[],"open_questions":[],"numbers":[]}`, nil
}

var startTimeout = &EngineDownError{Err: errors.New("engine did not become healthy"), Retryable: true}

// A start that timed out on health may succeed the second time: Compose
// allows exactly one more start per run, and the notes are written.
// Mutation: notes.go chunk, `!down.Retryable ||` made `true ||` -> RED (one
// call, no notes).
func TestComposeRestartsOnceAfterARetryableStartFailure(t *testing.T) {
	chat := &scriptChat{errs: []error{startTimeout}}
	n, err := Composer{Chat: chat}.Compose(context.Background(), "hello there", Labels{}, "en")
	if err != nil || n.Summary == "" {
		t.Fatalf("notes = %+v, err = %v, want the notes after one more start", n, err)
	}
	if chat.calls != 2 {
		t.Fatalf("model calls = %d, want 2", chat.calls)
	}
}

// Twice in a row stops the run with the cause, and the next chunk does not
// start the engine a third time.
// Mutation: notes.go Compose, disable the EngineDownError return -> RED (the
// second chunk calls the model: 3 calls).
func TestComposeStopsAfterTwoRetryableStartFailures(t *testing.T) {
	chat := &scriptChat{errs: []error{startTimeout, startTimeout, startTimeout}}
	text := strings.Repeat("word ", ChunkChars/5*2)
	_, err := Composer{Chat: chat}.Compose(context.Background(), text, Labels{}, "en")
	var down *EngineDownError
	if !errors.As(err, &down) || !strings.Contains(err.Error(), "healthy") {
		t.Fatalf("err = %v, want the engine-down error with its cause", err)
	}
	if chat.calls != 2 {
		t.Fatalf("model calls = %d, want 2", chat.calls)
	}
}
