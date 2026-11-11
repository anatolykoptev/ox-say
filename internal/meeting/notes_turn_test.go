package meeting

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
)

// heldChat records whether the notes turn was held at each call.
type heldChat struct {
	fakeChat
	held *turnProbe
	at   []bool
}

func (h *heldChat) Complete(ctx context.Context, r Request) (string, error) {
	h.mu.Lock()
	h.at = append(h.at, h.held.isHeld())
	h.mu.Unlock()
	return h.fakeChat.Complete(ctx, r)
}

type turnProbe struct {
	mu       sync.Mutex
	held     bool
	claims   int
	releases int
	err      error
}

func (p *turnProbe) isHeld() bool { p.mu.Lock(); defer p.mu.Unlock(); return p.held }

func (p *turnProbe) claim(context.Context) (func(), error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.err != nil {
		return nil, p.err
	}
	p.claims++
	p.held = true
	return func() { p.mu.Lock(); p.held = false; p.releases++; p.mu.Unlock() }, nil
}

func multiChunkText(t *testing.T) (string, int) {
	t.Helper()
	text := strings.Repeat("[0:01] Me: "+strings.Repeat("word ", 30)+"\n", 300)
	n := len(Chunk(text, ChunkChars))
	if n < 2 {
		t.Fatalf("fixture makes %d chunks", n)
	}
	return text, n
}

// One notes job claims the notes model's turn once and holds it across EVERY model call of the map-reduce, releasing it
// when the job ends: a voice request between two chunks must not evict the model.
// Mutation: runner.go compose, delete the `r.NotesTurn(ctx)` claim (and its defer) -> no call sees the turn held -> RED.
func TestComposeHoldsTheNotesTurnAcrossAllCalls(t *testing.T) {
	text, n := multiChunkText(t)
	probe := &turnProbe{}
	chat := &heldChat{held: probe}
	for i := 0; i < n; i++ {
		chat.replies = append(chat.replies, replyJSON(t, ChunkNotes{Summary: "part"}))
	}
	chat.replies = append(chat.replies, "The merged summary.")
	r := &Runner{Deps: Deps{Chat: chat, NotesTurn: probe.claim}}
	if _, err := r.compose(context.Background(), nil, text, Labels{}, "en"); err != nil {
		t.Fatal(err)
	}
	if len(chat.at) != n+1 {
		t.Fatalf("calls = %d, want %d", len(chat.at), n+1)
	}
	for i, h := range chat.at {
		if !h {
			t.Fatalf("call %d ran without the notes turn held", i)
		}
	}
	if probe.claims != 1 || probe.releases != 1 || probe.held {
		t.Fatalf("claims %d releases %d held %v, want one claim, released", probe.claims, probe.releases, probe.held)
	}
}

// The turn is released when the job fails or is cancelled, and a panic in a call does not keep it.
// Mutation: runner.go compose, change `defer release()` to a call after Compose returns -> the panic case never
// releases -> RED.
func TestComposeReleasesTheNotesTurnOnEveryExit(t *testing.T) {
	text, _ := multiChunkText(t)
	for name, tc := range map[string]struct {
		chat  Chat
		ctx   func() (context.Context, context.CancelFunc)
		panic bool
	}{
		"failure": {chat: &fakeChat{errs: []error{&EngineDownError{Err: errors.New("down")}}}},
		"cancelled": {chat: &fakeChat{}, ctx: func() (context.Context, context.CancelFunc) {
			c, f := context.WithCancel(context.Background())
			f()
			return c, f
		}},
		"panic": {chat: panicChat{}, panic: true},
	} {
		t.Run(name, func(t *testing.T) {
			probe := &turnProbe{}
			r := &Runner{Deps: Deps{Chat: tc.chat, NotesTurn: probe.claim}}
			ctx, cancel := context.WithCancel(context.Background())
			if tc.ctx != nil {
				ctx, cancel = tc.ctx()
			}
			defer cancel()
			func() {
				defer func() { _ = recover() }()
				_, _ = r.compose(ctx, nil, text, Labels{}, "en")
			}()
			if probe.held || probe.releases != probe.claims {
				t.Fatalf("claims %d releases %d held %v: the turn leaked", probe.claims, probe.releases, probe.held)
			}
		})
	}
}

type panicChat struct{}

func (panicChat) Complete(context.Context, Request) (string, error) { panic("boom") }

// A turn that cannot be taken is a retryable engine-down failure, not a silent skip of the chunks.
func TestComposeTurnRefusalIsAnEngineDownError(t *testing.T) {
	text, _ := multiChunkText(t)
	probe := &turnProbe{err: errors.New("busy")}
	r := &Runner{Deps: Deps{Chat: &fakeChat{}, NotesTurn: probe.claim}}
	_, err := r.compose(context.Background(), nil, text, Labels{}, "en")
	var down *EngineDownError
	if !errors.As(err, &down) || !down.Retryable || down.Reason != FailNotesEngineStart {
		t.Fatalf("err = %v, want a retryable engine-down failure", err)
	}
}
