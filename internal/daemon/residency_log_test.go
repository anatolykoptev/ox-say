package daemon

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/engine"
)

// A use that stood behind another engine's turn says which engine held it
// and for how long — the wait a notes job or a voice request stalls on.
// Mutation: residency.go take, delete `held = r.active` -> RED (held stays
// nil and the wait line never comes).
func TestEngineTurnWaitNamesItsHolder(t *testing.T) {
	var buf bytes.Buffer
	supA, supB := new(engine.Supervisor), new(engine.Supervisor)
	r := &residency{
		change:  make(chan struct{}),
		engines: []*engine.Supervisor{supA, supB},
		log:     slog.New(slog.NewTextHandler(&buf, nil)),
		stop:    func(context.Context, *engine.Supervisor) error { return nil },
	}
	leave, err := r.enter(context.Background(), supA, 0)
	if err != nil {
		t.Fatal(err)
	}
	got := make(chan error, 1)
	go func() {
		l, err := r.enter(context.Background(), supB, 0)
		if err == nil {
			l()
		}
		got <- err
	}()
	time.Sleep(300 * time.Millisecond)
	leave()
	if err := <-got; err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	if !strings.Contains(out, "engine turn wait") || !strings.Contains(out, "held_by=") || !strings.Contains(out, "dur_ms=") {
		t.Fatalf("no wait line naming the engine that held the turn:\n%s", out)
	}
}
