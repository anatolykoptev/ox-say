package daemon

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/anatolykoptev/ox-say/internal/engine"
	"github.com/anatolykoptev/ox-say/internal/meeting"
)

// A notes server that keeps failing its key check is retried a few times and
// then given up on: /status reads "failed" with the cause and a plain reason,
// the runner's model call fails at once with the cause (the meeting reads
// "transcribed, notes failed" with that text), and no further model load
// happens.
// Mutation: internal/daemon/meetings.go notesStatus, delete the
// `out.State, out.LastErr = st.State, st.LastErr` line -> RED (/status says
// stopped with no error).
// Mutation: internal/daemon/meetings.go llmChat.Complete, wrap with
// errors.New("the notes model failed to start") (drop %w) -> RED (the
// runner's error hides the give-up).
func TestNotesGiveUpReachesStatusAndTheRunner(t *testing.T) {
	d, dir := startNotesFake(t)
	t.Setenv("OXSAY_FAKE_LLM_OPEN", "1")
	req := meeting.Request{System: "s", User: "u"}
	var err error
	for i := 0; i < 6; i++ {
		if _, err = (llmChat{d: d}).Complete(context.Background(), req); err != nil && strings.Contains(err.Error(), "gave up") {
			break
		}
	}
	if err == nil || !strings.Contains(err.Error(), "gave up") || !strings.Contains(err.Error(), "running open") {
		t.Fatalf("runner-visible error = %v, want the give-up and its cause", err)
	}
	n := d.Status().Notes
	if n.State != engine.StateFailed || n.LastErr == "" || !strings.Contains(n.Reason, "stopped retrying") {
		t.Fatalf("notes status = %+v, want state failed with last_error and a reason", n)
	}
	if !n.Available {
		t.Fatalf("notes status = %+v: a failed engine is not 'unsupported'", n)
	}
	before := len(spawnStamps(t, dir))
	t0 := time.Now()
	if _, err := (llmChat{d: d}).Complete(context.Background(), req); err == nil || time.Since(t0) > 2*time.Second {
		t.Fatalf("a call in the failed state = %v after %s, want an immediate error", err, time.Since(t0))
	}
	if after := len(spawnStamps(t, dir)); after != before || before != 3 {
		t.Fatalf("spawns: %d then %d, want 3 and no more", before, after)
	}
}
