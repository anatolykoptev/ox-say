package oneshot

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func sh(t *testing.T, ctx context.Context, script string, opt Options) ([]byte, error) {
	t.Helper()
	return Run(ctx, "/bin/sh", []string{"-c", script}, opt)
}

func TestRunReturnsStdout(t *testing.T) {
	out, err := sh(t, context.Background(), `printf '{"a":1}'`, Options{})
	if err != nil || string(out) != `{"a":1}` {
		t.Fatalf("out %q err %v", out, err)
	}
}

// A failing child is an *ExitError with its status and the end of its stderr, however much it printed.
// Mutation: internal/oneshot/oneshot.go tailBuffer.Write, delete the `if len(t.b) > t.max` block -> RED (the tail is not bounded).
func TestRunReportsAFailureWithTheTailOfStderr(t *testing.T) {
	_, err := sh(t, context.Background(), `i=0; while [ $i -lt 400 ]; do echo "line $i of noise" >&2; i=$((i+1)); done; echo last words >&2; exit 3`, Options{StderrTail: 64})
	var ee *ExitError
	if !errors.As(err, &ee) || ee.Code() != 3 {
		t.Fatalf("err = %v", err)
	}
	if !strings.HasSuffix(strings.TrimSpace(ee.Tail), "last words") || len(ee.Tail) > 64 {
		t.Errorf("tail %q (%d bytes)", ee.Tail, len(ee.Tail))
	}
	var plain *exec.ExitError
	if !errors.As(err, &plain) {
		t.Errorf("the *exec.ExitError is not reachable through Unwrap")
	}
}

// A context that ends kills the child and the error is the context's, not a failure of the child.
// Mutation: internal/oneshot/oneshot.go, change `exec.CommandContext(ctx, bin, args...)` to `exec.Command(bin, args...)`
// -> RED (the 30 s sleep runs out).
func TestRunKillsTheChildWhenTheContextEnds(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := sh(t, ctx, `sleep 30`, Options{WaitDelay: time.Second})
	if !errors.Is(err, context.DeadlineExceeded) || time.Since(start) > 10*time.Second {
		t.Fatalf("err %v after %v", err, time.Since(start))
	}
}

func TestRunReportsAChildThatCannotStart(t *testing.T) {
	_, err := Run(context.Background(), "/nonexistent/ox-diar", nil, Options{})
	var ee *ExitError
	if err == nil || errors.As(err, &ee) {
		t.Fatalf("err = %v", err)
	}
}
