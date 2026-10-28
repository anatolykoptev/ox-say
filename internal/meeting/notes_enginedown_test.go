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
	return "", &EngineDownError{Err: errors.New("gave up starting: server runs open")}
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
	if !strings.Contains(err.Error(), "gave up") {
		t.Fatalf("err = %q hides the cause", err)
	}
	if chat.calls != 1 {
		t.Fatalf("model calls = %d, want exactly 1", chat.calls)
	}
}
