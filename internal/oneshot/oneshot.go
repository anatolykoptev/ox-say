// Package oneshot runs a child process to its end: stdout is captured, the tail of stderr is kept to explain a
// failure, and a context that ends kills the child. ox-stt (internal/stt) and ox-diar (internal/daemon) are run
// this way; it is the one place that knows how.
package oneshot

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// Options tune one run.
type Options struct {
	// StderrTail is how many bytes of the child's stderr an ExitError carries; 0 means 4 KiB.
	StderrTail int
	// WaitDelay is how long the child gets to exit after the context ends before it is killed outright and its
	// pipes closed; 0 leaves exec's default (wait for the pipes without limit).
	WaitDelay time.Duration
}

// ExitError is a child that ran and did not succeed: it exited non-zero or was ended by a signal that was not
// ours. Tail is the last bytes of its stderr.
type ExitError struct {
	Err  error // the *exec.ExitError
	Tail string
}

func (e *ExitError) Error() string { return fmt.Sprintf("%v: %s", e.Err, strings.TrimSpace(e.Tail)) }
func (e *ExitError) Unwrap() error { return e.Err }

// Code is the child's exit status, or -1 when it was ended by a signal.
func (e *ExitError) Code() int {
	var ee *exec.ExitError
	if errors.As(e.Err, &ee) {
		return ee.ExitCode()
	}
	return -1
}

// Run starts bin with args, waits for it and returns its stdout. The error is ctx.Err() when the context ended
// (the child was killed), an *ExitError when the child ran and failed, and the start error as exec reports it
// when it could not be started at all.
func Run(ctx context.Context, bin string, args []string, opt Options) ([]byte, error) {
	keep := opt.StderrTail
	if keep <= 0 {
		keep = 4 << 10
	}
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.WaitDelay = opt.WaitDelay
	var out bytes.Buffer
	tail := &tailBuffer{max: keep}
	cmd.Stdout = &out
	cmd.Stderr = tail
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return nil, &ExitError{Err: err, Tail: tail.String()}
		}
		return nil, err
	}
	return out.Bytes(), nil
}

// tailBuffer keeps the last max bytes written to it: enough of a tool's stderr to explain a failure, bounded
// however much it prints.
type tailBuffer struct {
	max int
	b   []byte
}

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.b = append(t.b, p...)
	if len(t.b) > t.max {
		t.b = t.b[len(t.b)-t.max:]
	}
	return len(p), nil
}

func (t *tailBuffer) String() string { return string(t.b) }
